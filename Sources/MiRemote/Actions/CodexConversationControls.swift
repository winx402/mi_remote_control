import AppKit
import ApplicationServices
import CoreGraphics
import os

/// 前台 Codex 的上下文控件。只读取控件元数据；不读取输入值、消息正文或会话文件。
/// OK 从不发送；只有独立的 submit 动作能压下经确认的发送/提交按钮。
enum CodexConversationControls {
    private static let trace = Logger(subsystem: "com.miremote.controller", category: "CodexQuestion")

    enum Action: String, CaseIterable {
        case up = "codex_context_up", down = "codex_context_down"
        case left = "codex_context_left", right = "codex_context_right"
        case ok = "codex_context_ok", submit = "codex_context_submit"
    }

    @MainActor static var onUnavailable: ((String) -> Void)?

    /// AX 的纯数据投影，也用于假表单测试。label 仅来自 title/description/identifier/placeholder。
    private struct Node {
        var parent: Int?
        var role: String
        var label: String = ""
        var rect: CGRect = .zero
        var enabled = true
        var focused = false
        var selected = false
        var editable = false
        var pressable = false
    }
    private struct Form {
        var root: Int
        var options: [Int]
        var fields: [Int]
        var previous: Int?
        var next: Int?
        var submit: Int?
        var immediateQuestion = false
    }
    private struct Snapshot {
        var pid: pid_t
        var app: AXUIElement
        var elements: [AXUIElement]
        var nodes: [Node]
        var window: CGRect
        var complete: Bool
    }

    @MainActor private static let answerHighlight = NavigationFocusOverlay()
    @MainActor private static var highlightMonitor: Timer?
    @MainActor private static func previewAnswer(_ index: Int, ordinal: Int, form: Form, in snapshot: Snapshot) {
        let target = snapshot.elements[index]
        lastFormRoot = snapshot.elements[form.root]
        lastOption = target
        // Focus moves without AXPress. Clicking a mid-turn option would send it.
        var candidate: Int? = index
        while let item = candidate, descendant(item, of: form.root, in: snapshot.nodes) {
            let element = snapshot.elements[item]
            if AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
               focusedEditor(for: element, app: snapshot.app).map({ CFEqual($0, element) }) == true { break }
            candidate = snapshot.nodes[item].parent
        }
        answerHighlight.showAnswer(snapshot.nodes[index].rect, ordinal: ordinal)
        highlightMonitor?.invalidate()
        highlightMonitor = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let lastOption, CFEqual(lastOption, target) else { return }
                guard sameWindow(snapshot), let bounds = frame(target), bounds.intersects(snapshot.window) else {
                    resetInputTarget()
                    return
                }
                if bounds != snapshot.nodes[index].rect {
                    answerHighlight.showAnswer(bounds, ordinal: ordinal)
                }
            }
        }
    }

    @MainActor static func clearAnswer() {
        highlightMonitor?.invalidate()
        highlightMonitor = nil
        lastOption = nil
        lastFormRoot = nil
        answerHighlight.hide()
    }

    @MainActor private static var questionRoot: AXUIElement?
    @MainActor private static var composerTarget: AXUIElement?
    @MainActor private static var targetWindow: AXUIElement?
    @MainActor private static var verifiedDictationField: AXUIElement?

    @MainActor static func resolvedDictationField() -> AXUIElement? { verifiedDictationField }

    @MainActor static func resetInputTarget() {
        questionTransition?.cancel()
        transitioningFrom = nil
        questionRoot = nil
        composerTarget = nil
        targetWindow = nil
        verifiedDictationField = nil
        clearAnswer()
    }

    @MainActor private static var lastOption: AXUIElement?
    @MainActor private static var lastFormRoot: AXUIElement?
    @MainActor private static var accessibilityPID: pid_t?

    private static let inputRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]
    private static let formMarkers = ["request-user-input", "request_user_input", "requestuserinput", "user-input-form",
                                      "question-form", "questionnaire", "ask-user-question", "askuserquestion",
                                      "回答问题", "回答問題", "用户提问", "使用者提問"]
    private static let answerSubmits: Set<String> = ["submit answers", "submit answer", "send answers", "confirm answers",
        "提交答案", "提交回答", "确认答案", "確認答案", "送出答案", "send update", "发送更新", "傳送更新", "提交所有答案", "提交全部答案"]
    private static let formSubmits = answerSubmits.union(["submit", "confirm", "send", "提交", "确认", "確認", "发送", "傳送", "送出"])
    private static let previousTitles: Set<String> = ["previous", "previous question", "back", "上一题", "上一題", "上一个问题", "上一個問題", "返回"]
    private static let nextTitles: Set<String> = ["next", "next question", "continue", "下一题", "下一題", "下一个问题", "下一個問題", "继续", "繼續"]
    private static let sendTitles: Set<String> = ["send", "send message", "send prompt", "submit message", "发送", "发送消息", "发送提示", "傳送", "傳送訊息", "送出訊息"]

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
    private static func matches(_ node: Node, _ labels: Set<String>) -> Bool {
        node.label.components(separatedBy: "\n").contains { labels.contains(normalized($0)) }
    }
    private static func contains(_ label: String, _ words: [String]) -> Bool {
        words.contains { label.lowercased().contains($0) }
    }
    private static func descendant(_ index: Int, of root: Int, in nodes: [Node]) -> Bool {
        var current: Int? = index
        while let value = current {
            guard nodes.indices.contains(value) else { return false }
            if value == root { return true }
            current = nodes[value].parent
        }
        return false
    }
    private static func historicallyInactive(_ index: Int, in nodes: [Node]) -> Bool {
        var current: Int? = index
        while let value = current {
            if !nodes[value].enabled || contains(nodes[value].label,
                ["completed-request", "completed request", "answered-questions", "answered questions", "conversation history", "历史记录", "已回答", "已完成提问"]) { return true }
            current = nodes[value].parent
        }
        return false
    }

    private static let questionTitles: Set<String> = ["question", "questions", "问题", "問題"]
    private static let customReplyTitles: Set<String> = [
        "or write your own reply", "or write your own response", "or write your own answer",
        "write your own reply", "write your own response", "type your own answer",
        "或自行撰写回复", "或自行撰寫回覆", "或自行撰写回答", "或自行撰寫回答"]
    private static let standaloneReplyTitles: Set<String> = ["reply…", "reply...", "回复…", "回复...", "回覆…", "回覆..."]
    private static let skipTitles: Set<String> = ["skip", "skip question", "跳过", "跳過"]
    private static let formContainers: Set<String> = ["AXGroup", "AXForm", "AXRadioGroup", "AXDialog"]

    /// Static text is numeric only when its whole label is an integer. An AXButton
    /// may combine the ordinal and answer into one title ("1 Answer", "2. Answer").
    private static func optionNumber(_ node: Node) -> Int? {
        let label = node.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = label.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits), (1...12).contains(number),
              String(number) == digits else { return nil }
        let suffix = label.dropFirst(digits.count)
        if suffix.isEmpty { return number }
        guard node.role == "AXButton", let separator = suffix.first,
              separator.isWhitespace || ".)、:：".contains(separator) else { return nil }
        if separator == ".", suffix.dropFirst().first?.isNumber == true { return nil }
        guard !suffix.drop(while: { $0.isWhitespace || ".)、:：".contains($0) }).isEmpty else { return nil }
        return number
    }

    private static func numberedOptions(_ members: [Int], root: Int, nodes: [Node]) -> [Int] {
        var choices: [Int: Int] = [:]
        for index in members where nodes[index].enabled && !historicallyInactive(index, in: nodes) {
            guard let number = optionNumber(nodes[index]) else { continue }
            // Chromium may expose the number inside a button, or just as static text
            // in a clickable row. Prefer the real button whenever AXPress is available.
            var target = index
            var parent = nodes[index].parent
            while let value = parent, value != root {
                if nodes[value].enabled && nodes[value].pressable && nodes[value].role == "AXButton" {
                    target = value
                    break
                }
                parent = nodes[value].parent
            }
            if let existing = choices[number], existing != target { return [] }
            choices[number] = target
        }
        let numbers = choices.keys.sorted()
        guard numbers.count >= 2, numbers == Array(1...numbers.count), Set(choices.values).count == numbers.count else { return [] }
        return numbers.compactMap { choices[$0] }
    }

    /// Some builds draw the numeric badges without exposing their numbers to AX.
    /// Bound the answer rows by the card's heading and footer in screen coordinates.
    private static func answerRows(_ members: [Int], nodes: [Node]) -> [Int] {
        // The placeholder may disappear as soon as the user dictates. Chromium's
        // radio group still identifies the options without relying on its text.
        let groups = members.filter { nodes[$0].role == "AXRadioGroup" }
        if groups.count == 1, let group = groups.first {
            let radios = members.filter { nodes[$0].enabled && nodes[$0].role == "AXRadioButton"
                && descendant($0, of: group, in: nodes) }
            if !radios.isEmpty { return radios.sorted { nodes[$0].rect.midY < nodes[$1].rect.midY } }
        }
        guard let heading = members.first(where: { matches(nodes[$0], questionTitles) && nodes[$0].rect.height > 0 }),
              let skip = members.first(where: { matches(nodes[$0], skipTitles) && nodes[$0].rect.height > 0 }),
              members.contains(where: { matches(nodes[$0], customReplyTitles) }) else { return [] }
        let top = nodes[heading].rect.maxY
        let footer = nodes[skip].rect
        let left = nodes[heading].rect.minX
        let excluded = formSubmits.union(skipTitles).union(previousTitles).union(nextTitles).union(customReplyTitles)
        let candidates = members.filter { index in
            let n = nodes[index], r = n.rect
            return n.enabled && r.height >= 10 && r.minY >= top && r.maxY <= footer.minY + 2
                && r.midX >= left - 35 && r.minX <= footer.maxX && !matches(n, excluded)
        }
        // Start with actual controls. Include focusable rows and Chromium's generic
        // AXPress groups, whose labels can contain only the answer itself.
        let controls = candidates.filter {
            let n = nodes[$0]
            return n.pressable || ["AXButton", "AXRadioButton", "AXCheckBox", "AXRow"].contains(n.role)
        }.sorted { nodes[$0].rect.midY < nodes[$1].rect.midY }
        var rows: [Int] = []
        for index in controls {
            if let last = rows.last, abs(nodes[index].rect.midY - nodes[last].rect.midY) < 5 { continue }
            rows.append(index)
        }
        if (2...12).contains(rows.count) { return rows }

        // An unlabelled badge and its answer can also be plain siblings. The body
        // copy starts at the heading margin; answer text is indented past the badge.
        let text = candidates.filter {
            let n = nodes[$0]
            return n.role == "AXStaticText" && n.rect.minX >= left + 2
                && n.rect.minX <= left + 75 && n.rect.width > 20
        }
        let aligned = text.filter { i in text.contains { j in
            i != j && abs(nodes[i].rect.minX - nodes[j].rect.minX) < 4
                && abs(nodes[i].rect.midY - nodes[j].rect.midY) > 12
        } }.sorted { nodes[$0].rect.midY < nodes[$1].rect.midY }
        return (2...12).contains(aligned.count) ? aligned : []
    }

    /// The current question card has no dedicated AX identifier in some Codex builds.
    /// Its fixed UI anchors, numbered choices and local footer provide the boundary.
    /// Disabled Send is part of the structure but is never an actionable submission.
    private static func questionCards(_ nodes: [Node]) -> [Form] {
        var roots = Set<Int>()
        for title in nodes.indices where matches(nodes[title], questionTitles.union(customReplyTitles).union(skipTitles)) {
            var parent: Int? = title
            while let value = parent {
                if formContainers.contains(nodes[value].role) { roots.insert(value) }
                parent = nodes[value].parent
            }
        }
        var cards: [Form] = []
        for root in roots.sorted() {
            guard !historicallyInactive(root, in: nodes) else { continue }
            let members = nodes.indices.filter { descendant($0, of: root, in: nodes) }
            guard members.count <= 160,
                  members.contains(where: { matches(nodes[$0], customReplyTitles.union(questionTitles)) }),
                  members.contains(where: { nodes[$0].role == "AXButton" && matches(nodes[$0], skipTitles) }) else { continue }
            // An ancestor spanning the ordinary composer is not a local card. This
            // also stops a missing card footer from borrowing the chat's Send.
            guard !members.contains(where: { index in
                let node = nodes[index]
                return contains(node.label, ["composer", "chat input"])
                    || (node.editable && inputRoles.contains(node.role)
                        && matches(node, ["message", "prompt", "消息", "输入消息", "輸入訊息"]))
            }) else { continue }
            let numbered = numberedOptions(members, root: root, nodes: nodes)
            let options = numbered.isEmpty ? answerRows(members, nodes: nodes) : numbered
            let submits = members.filter { nodes[$0].role == "AXButton" && matches(nodes[$0], formSubmits) }
            let fields = members.filter { nodes[$0].enabled && nodes[$0].editable && inputRoles.contains(nodes[$0].role) }
            let hasHeading = members.contains { matches(nodes[$0], questionTitles) }
            let replyField = members.contains { matches(nodes[$0], standaloneReplyTitles) }
            let hasFooterAction = members.contains { nodes[$0].role == "AXButton"
                && matches(nodes[$0], formSubmits.union(["next", "下一步"])) }
            let questionPager = members.contains {
                nodes[$0].role == "AXButton" && matches(nodes[$0], ["previous question", "next question", "上一个问题", "下一个问题", "上一個問題", "下一個問題"])
            }
            let standalone = hasHeading && fields.count == 1 && hasFooterAction && (replyField || questionPager)
            guard !options.isEmpty || standalone else { continue }
            func uniqueEnabled(_ titles: Set<String>) -> Int? {
                let controls = members.filter { nodes[$0].role == "AXButton" && nodes[$0].enabled
                    && nodes[$0].pressable && matches(nodes[$0], titles) }
                return controls.count == 1 ? controls[0] : nil
            }
            cards.append(Form(root: root, options: options, fields: fields,
                              previous: uniqueEnabled(previousTitles), next: uniqueEnabled(nextTitles),
                              submit: submits.count == 1 ? uniqueEnabled(formSubmits) : uniqueEnabled(["next", "下一步"]),
                              immediateQuestion: hasHeading && (standalone || members.contains { matches(nodes[$0], customReplyTitles) || nodes[$0].role == "AXRadioGroup" })))
        }
        return cards.filter { outer in !cards.contains { $0.root != outer.root && descendant($0.root, of: outer.root, in: nodes) } }
    }

    /// Accept dedicated forms, bounded radio forms, or the fixed question-card structure.
    /// Plain transcript lists and generic confirmation dialogs do not qualify.
    private static func activeForm(_ nodes: [Node]) -> Form? {
        var forms = questionCards(nodes)
        var roots = Set(nodes.indices.filter { formContainers.contains(nodes[$0].role) && contains(nodes[$0].label, formMarkers) })
        for index in nodes.indices where nodes[index].role == "AXButton" && matches(nodes[index], answerSubmits) {
            var parent = nodes[index].parent
            while let value = parent {
                if formContainers.contains(nodes[value].role) { roots.insert(value) }
                parent = nodes[value].parent
            }
        }
        for root in roots.sorted() {
            guard !historicallyInactive(root, in: nodes) else { continue }
            let members = nodes.indices.filter { descendant($0, of: root, in: nodes) }
            guard members.count <= 160 else { continue }
            let allButtons = members.filter { nodes[$0].role == "AXButton" }
            let buttons = allButtons.filter { nodes[$0].enabled && nodes[$0].pressable }
            let marked = contains(nodes[root].label, formMarkers)
            let radios = members.filter { nodes[$0].enabled && nodes[$0].pressable && ["AXRadioButton", "AXCheckBox"].contains(nodes[$0].role) }
            let hasRadioGroup = members.contains { nodes[$0].role == "AXRadioGroup" }
            let explicitSubmit = allButtons.filter { matches(nodes[$0], answerSubmits) }
            guard marked || (hasRadioGroup && radios.count >= 2 && explicitSubmit.count == 1) else { continue }
            let fields = members.filter { nodes[$0].enabled && nodes[$0].editable && inputRoles.contains(nodes[$0].role) }
            let options = members.filter { index in
                if radios.contains(index) { return true }
                guard marked, nodes[index].role == "AXButton", nodes[index].enabled, nodes[index].pressable,
                      !matches(nodes[index], formSubmits.union(previousTitles).union(nextTitles)) else { return false }
                return members.contains { ["AXRadioGroup", "AXListBox"].contains(nodes[$0].role) && descendant(index, of: $0, in: nodes) }
            }
            guard !options.isEmpty || !fields.isEmpty else { continue }
            func unique(_ titles: Set<String>) -> Int? {
                let result = buttons.filter { matches(nodes[$0], titles) }
                return result.count == 1 ? result[0] : nil
            }
            if !forms.contains(where: { $0.root == root }) {
                forms.append(Form(root: root, options: options, fields: fields,
                                  previous: unique(previousTitles), next: unique(nextTitles), submit: unique(formSubmits)))
            }
        }
        let deepest = forms.filter { outer in !forms.contains { $0.root != outer.root && descendant($0.root, of: outer.root, in: nodes) } }
        return deepest.count == 1 ? deepest[0] : nil
    }

    private static func blocksChat(_ nodes: [Node]) -> Bool {
        let live = nodes.indices.filter { !historicallyInactive($0, in: nodes) }
        return nodes.contains { ["AXDialog", "AXSheet"].contains($0.role) }
            || live.contains { contains(nodes[$0].label, formMarkers) }
            || live.contains { nodes[$0].role == "AXButton" && matches(nodes[$0], answerSubmits) }
            || live.contains { matches(nodes[$0], customReplyTitles) }
            || (live.contains { matches(nodes[$0], questionTitles) }
                && live.contains { nodes[$0].role == "AXButton" && matches(nodes[$0], skipTitles) })
    }

    private static func isQuestionInputLabel(_ label: String) -> Bool {
        if matches(Node(parent: nil, role: "AXTextArea", label: label), customReplyTitles) { return true }
        let replyLabels: Set<String> = ["reply", "reply…", "回复", "回复…", "回覆", "回覆…"]
        return label.components(separatedBy: "\n").contains {
            replyLabels.contains(normalized($0).replacingOccurrences(of: "...", with: "…"))
        }
    }

    private static func hasComposerInputLabel(_ label: String) -> Bool {
        let placeholders: Set<String> = ["work with codex", "和 codex 一起工作", "work with chatgpt",
                                         "使用 chatgpt work", "working…", "处理中…"]
        return label.components(separatedBy: "\n").contains {
            placeholders.contains(normalized($0).replacingOccurrences(of: "...", with: "…"))
        } || contains(label, ["composer", "chat-input", "chat_input", "chat input", "prompt-textarea"])
    }

    private static func composer(_ nodes: [Node], window: CGRect, outside form: Form? = nil) -> Int? {
        guard window.height > 0, form != nil || !blocksChat(nodes) else { return nil }
        let footerY = form.flatMap { card in
            nodes.indices.filter { descendant($0, of: card.root, in: nodes) && matches(nodes[$0], skipTitles) }
                .map { nodes[$0].rect.midY }.max()
        }
        let candidates = nodes.indices.filter { index in
            let n = nodes[index]
            if isQuestionInputLabel(n.label) { return false }
            if let form, descendant(index, of: form.root, in: nodes) || n.rect.midY < (footerY ?? nodes[form.root].rect.maxY) { return false }
            guard inputRoles.contains(n.role), n.editable, n.enabled, !historicallyInactive(index, in: nodes),
                  n.rect.width >= window.width * 0.25, n.rect.midY >= window.minY + window.height * 0.50,
                  !contains(n.label, ["search", "find", "filter", "terminal", "搜索", "查找", "过滤", "终端"]) else { return false }
            return hasComposerInputLabel(n.label)
                || contains(n.label, ["message", "prompt", "消息", "输入", "輸入"])
                || n.role == "AXTextArea"
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private static func composerSend(_ field: Int, nodes: [Node]) -> Int? {
        let input = nodes[field]
        var parent = input.parent
        // Require a local composer container, not an arbitrary Send elsewhere in the window.
        for _ in 0..<3 {
            guard let root = parent, !["AXWindow", "AXWebArea", "AXScrollArea"].contains(nodes[root].role) else { break }
            let result = nodes.indices.filter { index in
                let n = nodes[index]
                return n.enabled && n.pressable && n.role == "AXButton" && matches(n, sendTitles)
                    && descendant(index, of: root, in: nodes)
                    && n.rect.midY >= input.rect.minY - 50 && n.rect.midY <= input.rect.maxY + 80
            }
            if result.count == 1 { return result[0] }
            if result.count > 1 { return nil }
            parent = nodes[root].parent
        }
        return nil
    }

    @MainActor @discardableResult static func perform(_ name: String, isCurrent: @escaping () -> Bool = { true }) -> Bool {
        guard let action = Action(rawValue: name) else { return false }
        trace.notice("remote action=\(name, privacy: .public)")
        guard isCurrent() else { return true }
        let scrolling = action == .up || action == .down
        if scrolling && questionRoot == nil {
            CodexConversationScroll.scroll(up: action == .up, isCurrent: isCurrent)
            return true
        }
        guard let snapshot = snapshot(budget: 0.65, preferForm: composerTarget == nil) else {
            // A large Chromium tree must not make normal wheel input unusable.
            if scrolling && isCurrent() { resetInputTarget(); CodexConversationScroll.scroll(up: action == .up, isCurrent: isCurrent) }
            else { unavailable("无法确认前台 Codex 的可用控件，本次未执行。") }
            return true
        }
        guard isCurrent(), sameWindow(snapshot) else { return true }
        let recognized = activeForm(snapshot.nodes)
        let heading = snapshot.nodes.contains { matches($0, questionTitles) }
        let skip = snapshot.nodes.contains { matches($0, skipTitles) }
        let custom = snapshot.nodes.contains { matches($0, customReplyTitles) }
        let numbers = snapshot.nodes.filter { optionNumber($0) != nil }.count
        trace.notice("nodes=\(snapshot.nodes.count) complete=\(snapshot.complete) heading=\(heading) skip=\(skip) custom=\(custom) numbers=\(numbers) options=\(recognized?.options.count ?? 0)")
        guard snapshot.complete else {
            if scrolling { unavailable("未能读取当前问题框，请短按语音键切换输入位置。") }
            else if !scrolling { unavailable("当前控件信息不完整，本次未执行确认或输入。") }
            return true
        }
        if let from = transitioningFrom, let questionRoot, CFEqual(from, questionRoot),
           let form = recognized, let targetWindow, CFEqual(targetWindow, snapshot.elements[0]),
           !CFEqual(from, snapshot.elements[form.root]) {
            self.questionRoot = snapshot.elements[form.root]
            transitioningFrom = nil
        }
        if let target = questionRoot, recognized.map({ CFEqual(target, snapshot.elements[$0.root]) }) != true {
            resetInputTarget()
            if scrolling { CodexConversationScroll.scroll(up: action == .up, isCurrent: isCurrent) }
            return true
        }
        if let form = recognized, questionRoot != nil {
            switch action {
            case .up, .down:
                let choices = form.options
                guard !choices.isEmpty else { return true }
                let current = choices.firstIndex {
                    guard let lastFormRoot, let lastOption, CFEqual(lastFormRoot, snapshot.elements[form.root]) else { return false }
                    return CFEqual(lastOption, snapshot.elements[$0])
                } ?? choices.firstIndex { snapshot.nodes[$0].selected || snapshot.nodes[$0].focused }
                let next = current.map { min(choices.count - 1, max(0, $0 + (action == .up ? -1 : 1))) }
                    ?? (action == .up ? choices.count - 1 : 0)
                let index = choices[next]
                previewAnswer(index, ordinal: next + 1, form: form, in: snapshot)
                trace.notice("preview ordinal=\(next + 1)")
            case .left, .right:
                guard let arrow = action == .left ? form.previous : form.next else { return true }
                clearAnswer()
                press(arrow, in: snapshot, isCurrent: isCurrent)
                followQuestionChange(from: snapshot, form: form, isCurrent: isCurrent)
            case .ok:
                if lastOption == nil, let field = preferredField(form, nodes: snapshot.nodes) {
                    _ = focus(field, in: snapshot)
                }
            case .submit:
                if let pending = lastOption {
                    let root = lastFormRoot
                    guard let root, CFEqual(root, snapshot.elements[form.root]),
                          let index = form.options.first(where: { CFEqual(snapshot.elements[$0], pending) }) else { return true }
                    if form.immediateQuestion {
                        if select(index, in: snapshot, activateEvenIfSelected: true, isCurrent: isCurrent) {
                            clearAnswer()
                            followQuestionChange(from: snapshot, form: form, isCurrent: isCurrent)
                        } else { unavailable("未能点击当前选项，请重新选择。") }
                        return true
                    }
                    commitOption(index, form: form, snapshot: snapshot, isCurrent: isCurrent)
                    return true
                }
                press(form.submit, in: snapshot, isCurrent: isCurrent)
                if form.submit != nil { followQuestionChange(from: snapshot, form: form, isCurrent: isCurrent) }
            }
        } else if lastOption != nil && action == .submit {
            clearAnswer()
            return true
        } else if let target = composerTarget, let field = composer(snapshot.nodes, window: snapshot.window, outside: recognized),
                  CFEqual(target, snapshot.elements[field]) {
            if action == .submit { press(composerSend(field, nodes: snapshot.nodes), in: snapshot, isCurrent: isCurrent) }
            if action == .ok { _ = focus(field, in: snapshot) }
        } else if blocksChat(snapshot.nodes) {
            clearAnswer()
            unavailable("当前弹层或提问控件尚未确认，请在 Codex 中检查。")
        } else {
            switch action {
            case .up, .down: CodexConversationScroll.scroll(up: action == .up, isCurrent: isCurrent)
            case .ok:
                if let field = composer(snapshot.nodes, window: snapshot.window) { _ = focus(field, in: snapshot) }
            case .submit:
                guard let field = composer(snapshot.nodes, window: snapshot.window),
                      let button = composerSend(field, nodes: snapshot.nodes) else {
                    unavailable("未找到输入框关联的可用发送按钮，本次未发送。") ; return true
                }
                press(button, in: snapshot, isCurrent: isCurrent)
            case .left, .right: break
            }
        }
        return true
    }

    /// Question navigation remounts the editor. Track only the transition initiated
    /// here, within the original window, and never replay a press on the next card.
    @MainActor private static var transitioningFrom: AXUIElement?
    @MainActor private static var questionTransition: Task<Void, Never>?
    @MainActor private static func followQuestionChange(from source: Snapshot, form: Form, isCurrent: @escaping () -> Bool) {
        questionTransition?.cancel()
        let root = source.elements[form.root]
        transitioningFrom = root
        questionTransition = Task { @MainActor in
            defer { if !Task.isCancelled { transitioningFrom = nil } }
            for delay in [180, 180, 300] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, isCurrent(), sameWindow(source),
                      let current = questionRoot, CFEqual(root, current), lastOption == nil else { return }
                if let live = snapshot(), live.complete, let card = activeForm(live.nodes),
                   !CFEqual(root, live.elements[card.root]) {
                    questionRoot = live.elements[card.root]
                    return
                }
            }
        }
    }

    /// Codex can give free text precedence over a button selection. Clear it through
    /// the editor's normal editing path only once the user commits an enumerated answer.
    @MainActor private static var committingOption = false

    private static func postEditingKey(_ code: CGKeyCode, flags: CGEventFlags) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func draftLength(_ field: AXUIElement) -> Int? {
        if let length = attribute(field, kAXNumberOfCharactersAttribute as CFString) as? NSNumber {
            return length.intValue
        }
        return string(field, kAXValueAttribute as CFString)?.utf16.count
    }

    @MainActor private static func commitOption(_ index: Int, form: Form, snapshot original: Snapshot,
                                                isCurrent: @escaping () -> Bool) {
        guard !committingOption, isCurrent(), sameWindow(original) else { return }
        let root = original.elements[form.root]
        let option = original.elements[index]
        @MainActor func eligible() -> Bool {
            guard isCurrent(), sameWindow(original), let lastOption, let lastFormRoot else { return false }
            return CFEqual(option, lastOption) && CFEqual(root, lastFormRoot)
        }
        @MainActor func checkedForm() -> (Snapshot, Form, Int)? {
            guard eligible(), let live = self.snapshot(), live.complete, eligible(),
                  let card = activeForm(live.nodes), CFEqual(root, live.elements[card.root]),
                  let target = card.options.first(where: { CFEqual(option, live.elements[$0]) }) else { return nil }
            return (live, card, target)
        }
        committingOption = true
        Task { @MainActor in
            defer { committingOption = false }
            guard eligible(), form.fields.count <= 1 else { return }
            if let field = form.fields.first {
                let editor = original.elements[field]
                guard let count = draftLength(editor), count >= 0 else {
                    unavailable("无法确认自定义回复是否为空，已保留草稿。")
                    return
                }
                if count > 0 {
                    guard focus(field, in: original), eligible() else { return }
                    var all = CFRange(location: 0, length: count)
                    @MainActor func editorIsCurrent() -> Bool {
                        guard eligible(), let focused = element(original.app, kAXFocusedUIElementAttribute as CFString) else { return false }
                        return CFEqual(focused, editor)
                    }
                    @MainActor func allSelected() -> Bool {
                        var selection = CFRange()
                        guard let value = attribute(editor, kAXSelectedTextRangeAttribute as CFString),
                              CFGetTypeID(value) == AXValueGetTypeID(),
                              AXValueGetValue(value as! AXValue, .cfRange, &selection) else { return false }
                        return selection.location == 0 && selection.length == count
                    }
                    if let range = AXValueCreate(.cfRange, &all), editorIsCurrent() {
                        _ = AXUIElementSetAttributeValue(editor, kAXSelectedTextRangeAttribute as CFString, range)
                    }
                    if !allSelected(), editorIsCurrent() {
                        postEditingKey(0, flags: .maskCommand) // Command-A, scoped to the focused custom answer
                        for _ in 0..<5 {
                            try? await Task.sleep(for: .milliseconds(30))
                            guard editorIsCurrent() else { return }
                            if allSelected() { break }
                        }
                    }
                    guard allSelected(), draftLength(editor) == count, editorIsCurrent() else {
                        unavailable("无法安全清除本题的自定义回复，请手动清空后再提交选项。")
                        return
                    }
                    postEditingKey(51, flags: [])
                    for _ in 0..<8 {
                        try? await Task.sleep(for: .milliseconds(40))
                        guard eligible() else { return }
                        if draftLength(editor) == 0 { break }
                    }
                }
            }
            guard let (live, card, target) = checkedForm() else { return }
            @MainActor func empty(_ card: Form, _ snap: Snapshot) -> Bool {
                card.fields.allSatisfy { draftLength(snap.elements[$0]) == 0 }
            }
            guard empty(card, live) else {
                unavailable("自定义回复尚未清空，本次没有提交。")
                return
            }
            if !live.nodes[target].selected {
                guard select(target, in: live, isCurrent: eligible) else { return }
                try? await Task.sleep(for: .milliseconds(120))
            }
            // A click may already have completed this card. Never chase a new one.
            guard let (after, sameCard, _) = checkedForm(), empty(sameCard, after),
                  let send = sameCard.submit else { return }
            press(send, in: after, isCurrent: eligible)
            clearAnswer()
        }
    }

    private static func preferredField(_ form: Form, nodes: [Node]) -> Int? {
        let focused = form.fields.filter { nodes[$0].focused }
        if focused.count == 1 { return focused[0] }
        return form.fields.count == 1 ? form.fields[0] : nil
    }

    /// The microphone tap cycles actual editor focus. Question options remain
    /// previews only when the user explicitly navigates them with up/down.
    @MainActor static func cycleInputTarget(isCurrent: () -> Bool) {
        guard isCurrent() else { return }
        let switchingToComposer = questionRoot != nil
        // Drop the old answer preview and dictation destination before lookup.
        // A partial scan must never leave the previous question armed for input.
        resetInputTarget()
        guard let first = snapshot(preferForm: !switchingToComposer), first.complete,
              sameWindow(first), isCurrent(), let window = first.elements.first else {
            if isCurrent() { _ = focusBottomComposer(isCurrent: isCurrent) }
            return
        }
        let form = activeForm(first.nodes)
        if let form, !switchingToComposer {
            guard let field = preferredField(form, nodes: first.nodes), isCurrent(),
                  focus(field, in: first), sameWindow(first), isCurrent(),
                  let focused = focusedEditor(for: first.elements[field], app: first.app) else {
                unavailable("未能聚焦本题的回复输入框，请在 Codex 中检查。")
                return
            }
            targetWindow = window
            questionRoot = first.elements[form.root]
            verifiedDictationField = focused
            trace.notice("input selected=question")
            return
        }
        guard let field = composer(first.nodes, window: first.window, outside: form),
              isCurrent(), focus(field, in: first), sameWindow(first), isCurrent(),
              let focused = focusedEditor(for: first.elements[field], app: first.app) else {
            if isCurrent() { _ = focusBottomComposer(isCurrent: isCurrent) }
            return
        }
        targetWindow = window
        composerTarget = first.elements[field]
        verifiedDictationField = focused
        trace.notice("input selected=composer")
    }

    @MainActor static func focusForDictation() -> Bool {
        verifiedDictationField = nil
        let savedComposer = composerTarget
        let savedQuestion = questionRoot
        if let savedComposer, let targetWindow, let app = NSWorkspace.shared.frontmostApplication,
           app.bundleIdentifier == "com.openai.codex", AXIsProcessTrusted() {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(ax, 0.025)
            if let win = element(ax, kAXFocusedWindowAttribute as CFString), CFEqual(win, targetWindow),
               let focused = focusedEditor(for: savedComposer, app: ax),
               inputRoles.contains(string(focused, kAXRoleAttribute as CFString) ?? ""),
               bool(focused, kAXEnabledAttribute as CFString) != false,
               !isQuestionInputLabel(metadata(focused)) {
                verifiedDictationField = focused
                trace.notice("dictation target=pinned composer")
                return true
            }
        }
        guard let snap = snapshot(preferForm: savedQuestion != nil && savedComposer == nil),
              snap.complete, let window = snap.elements.first, sameWindow(snap) else {
            // An explicitly selected question cannot silently become chat input.
            return savedQuestion == nil && focusBottomComposer()
        }
        if let targetWindow, !CFEqual(targetWindow, window) { resetInputTarget(); return false }
        let form = activeForm(snap.nodes)
        let field: Int
        if savedComposer != nil {
            // The React editor may have been replaced since the previous tap.
            guard let candidate = composer(snap.nodes, window: snap.window, outside: form) else { return focusBottomComposer() }
            field = candidate
        } else if let savedQuestion {
            guard let form, CFEqual(savedQuestion, snap.elements[form.root]),
                  let candidate = preferredField(form, nodes: snap.nodes) else { return false }
            field = candidate
            clearAnswer()
        } else {
            guard let candidate = composer(snap.nodes, window: snap.window, outside: form) else { return focusBottomComposer() }
            field = candidate
        }
        guard focus(field, in: snap), sameWindow(snap),
              let focused = focusedEditor(for: snap.elements[field], app: snap.app) else { return false }
        verifiedDictationField = focused
        if savedQuestion == nil { targetWindow = window; composerTarget = snap.elements[field] }
        trace.notice("dictation target=\(savedQuestion == nil ? "composer" : "question", privacy: .public)")
        return true
    }

    @MainActor private static func unavailable(_ message: String) {
        if let onUnavailable { onUnavailable(message) } else { log(message) }
    }
    @MainActor private static func stillFrontmost(_ pid: pid_t) -> Bool {
        let app = NSWorkspace.shared.frontmostApplication
        return app?.processIdentifier == pid && app?.bundleIdentifier == "com.openai.codex"
    }
    @MainActor private static func sameWindow(_ snapshot: Snapshot) -> Bool {
        guard stillFrontmost(snapshot.pid), let original = snapshot.elements.first,
              let current = element(snapshot.app, kAXFocusedWindowAttribute as CFString) else { return false }
        return CFEqual(original, current)
    }
    @MainActor private static func press(_ index: Int?, in snapshot: Snapshot, isCurrent: () -> Bool = { true }) {
        guard let index, stillFrontmost(snapshot.pid), snapshot.nodes[index].enabled,
              actions(snapshot.elements[index]).contains(kAXPressAction as String),
              bool(snapshot.elements[index], kAXEnabledAttribute as CFString) != false,
              sameWindow(snapshot), isCurrent() else { return }
        AXUIElementPerformAction(snapshot.elements[index], kAXPressAction as CFString)
    }
    @MainActor @discardableResult private static func select(_ index: Int, in snapshot: Snapshot,
                                                             activateEvenIfSelected: Bool = false, isCurrent: () -> Bool = { true }) -> Bool {
        guard isCurrent(), sameWindow(snapshot), snapshot.nodes[index].enabled else { return false }
        let target = snapshot.elements[index]
        if activateEvenIfSelected || !snapshot.nodes[index].selected {
            if actions(target).contains(kAXPressAction as String),
               AXUIElementPerformAction(target, kAXPressAction as CFString) == .success {
                if !activateEvenIfSelected { _ = focus(index, in: snapshot) }
                return true
            }
            // Chromium can expose a numbered badge as static text inside a clickable row.
            // Only click the freshly resolved option itself (or one of its descendants).
            guard let bounds = frame(target), bounds.width > 0, bounds.height > 0 else { return false }
            let point = CGPoint(x: bounds.midX, y: bounds.midY)
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
                  var current = hit else { return false }
            var matched = false
            for _ in 0..<12 {
                if CFEqual(current, target) { matched = true; break }
                guard let parent = element(current, kAXParentAttribute as CFString) else { break }
                current = parent
            }
            guard matched, sameWindow(snapshot), isCurrent(),
                  let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
                  let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { return false }
            down.postToPid(snapshot.pid)
            up.postToPid(snapshot.pid)
        } else { _ = focus(index, in: snapshot) }
        return true
    }
    private static func focusedEditor(for target: AXUIElement, app: AXUIElement) -> AXUIElement? {
        guard let focused = element(app, kAXFocusedUIElementAttribute as CFString) else { return nil }
        if CFEqual(target, focused) { return focused }
        guard inputRoles.contains(string(focused, kAXRoleAttribute as CFString) ?? "") else { return nil }
        var node = focused
        for _ in 0..<8 {
            guard let parent = element(node, kAXParentAttribute as CFString) else { break }
            if CFEqual(target, parent) { return focused }
            node = parent
        }
        return nil
    }

    @MainActor private static func focus(_ index: Int, in snapshot: Snapshot) -> Bool {
        guard sameWindow(snapshot), snapshot.nodes[index].enabled else { return false }
        let target = snapshot.elements[index]
        func confirmed() -> Bool {
            focusedEditor(for: target, app: snapshot.app) != nil && sameWindow(snapshot)
        }
        if confirmed() { return true }
        _ = AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        for _ in 0..<4 {
            if confirmed() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard inputRoles.contains(snapshot.nodes[index].role), let bounds = frame(target) else { return false }
        let point = CGPoint(x: bounds.minX + min(20, bounds.width / 2), y: bounds.midY)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              var node = hit else { return false }
        for _ in 0..<12 {
            if CFEqual(node, target) {
                if confirmed() { return true }
                guard sameWindow(snapshot),
                      let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
                      let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { return false }
                down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
                break
            }
            guard let parent = element(node, kAXParentAttribute as CFString) else { break }
            node = parent
        }
        for _ in 0..<8 {
            if confirmed() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return confirmed()
    }

    /// Recover the composer when a long thread exceeds the full-tree scan budget.
    /// Only a verified editable hit below the card is eligible, never a toolbar button.
    @MainActor private static func focusBottomComposer(isCurrent: () -> Bool = { true }) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.openai.codex",
              AXIsProcessTrusted(), isCurrent() else { return false }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.025)
        guard let win = element(ax, kAXFocusedWindowAttribute as CFString), let rect = frame(win) else { return false }
        let system = AXUIElementCreateSystemWide()
        for y in [0.91, 0.89, 0.93, 0.87] {
            let point = CGPoint(x: rect.minX + rect.width * 0.59, y: rect.minY + rect.height * y)
            var hit: AXUIElement?
            guard isCurrent(), AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
                  var node = hit else { continue }
            var owner: pid_t = 0
            guard AXUIElementGetPid(node, &owner) == .success, owner == app.processIdentifier else { continue }
            for _ in 0..<10 {
                let role = string(node, kAXRoleAttribute as CFString) ?? ""
                if inputRoles.contains(role), let bounds = frame(node) {
                    let label = metadata(node)
                    guard bounds.minY > rect.minY + rect.height * 0.78, bounds.width >= rect.width * 0.25,
                          bool(node, kAXEnabledAttribute as CFString) != false,
                          bool(node, "AXEditable" as CFString) != false,
                          !isQuestionInputLabel(label), hasComposerInputLabel(label),
                          !contains(label, ["search", "terminal", "自定义", "自行", "搜索", "终端"]),
                          let window = element(node, kAXWindowAttribute as CFString), CFEqual(window, win) else { break }
                    let snap = Snapshot(pid: owner, app: ax, elements: [win, node], nodes: [
                        Node(parent: nil, role: "AXWindow", rect: rect), Node(parent: 0, role: role, label: label, rect: bounds, editable: true)
                    ], window: rect, complete: false)
                    guard isCurrent(), focus(1, in: snap), isCurrent(),
                          let focused = focusedEditor(for: node, app: ax) else { break }
                    resetInputTarget()
                    verifiedDictationField = focused; composerTarget = node; targetWindow = win
                    return true
                }
                guard !["AXWindow", "AXButton", "AXToolbar"].contains(role),
                      let parent = element(node, kAXParentAttribute as CFString) else { break }
                node = parent
            }
        }
        return false
    }

    // MARK: - Bounded AX snapshot, with no text values

    @MainActor private static func snapshot(budget: TimeInterval = 0.65, preferForm: Bool = true) -> Snapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.openai.codex",
              AXIsProcessTrusted() else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.025)
        if accessibilityPID != app.processIdentifier {
            AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(ax, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            accessibilityPID = app.processIdentifier
        }
        guard let window = element(ax, kAXFocusedWindowAttribute as CFString), let windowRect = frame(window) else { return nil }
        // Locate the live card independently of the size of the conversation history.
        // Sample points only discover candidate ancestors. No action uses these points.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.35
        var visited = Set<AXUIElement>()
        let system = AXUIElementCreateSystemWide()
        for (x, y) in [(0.40, 0.76), (0.55, 0.70), (0.68, 0.82)] where preferForm {
            let point = CGPoint(x: windowRect.minX + windowRect.width * x,
                                y: windowRect.minY + windowRect.height * y)
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
                  var candidate = hit else { continue }
            var owner: pid_t = 0
            guard AXUIElementGetPid(candidate, &owner) == .success, owner == app.processIdentifier else { continue }
            for _ in 0..<64 {
                guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                if visited.insert(candidate).inserted, let bounds = frame(candidate),
                   bounds.width >= windowRect.width * 0.22, bounds.height >= 85,
                   bounds.height <= windowRect.height * 0.78,
                   let local = project(ax, window: window, rect: windowRect, root: candidate,
                                       pid: owner, budget: 0.18),
                   local.complete, activeForm(local.nodes) != nil { return local }
                guard let parent = element(candidate, kAXParentAttribute as CFString), !CFEqual(parent, window) else { break }
                candidate = parent
            }
        }
        guard let whole = project(ax, window: window, rect: windowRect, root: window,
                                  pid: app.processIdentifier, budget: budget) else { return nil }
        if preferForm, !whole.complete, let form = activeForm(whole.nodes),
           let isolated = project(ax, window: window, rect: windowRect, root: whole.elements[form.root],
                                  pid: whole.pid, budget: 0.25),
           isolated.complete, activeForm(isolated.nodes) != nil { return isolated }
        return whole
    }

    @MainActor private static func project(_ ax: AXUIElement, window: AXUIElement, rect windowRect: CGRect,
                                           root: AXUIElement, pid: pid_t, budget: TimeInterval) -> Snapshot? {
        let local = !CFEqual(window, root)
        var queue: [(AXUIElement, Int?, Int)] = [(root, local ? 0 : nil, 0)]
        var examined = 0
        var nodes: [Node] = local ? [Node(parent: nil, role: "AXWindow", rect: windowRect)] : []
        var elements: [AXUIElement] = local ? [window] : []
        var seen: [CFHashCode: [AXUIElement]] = [:]
        let deadline = ProcessInfo.processInfo.systemUptime + budget
        var complete = true
        while !queue.isEmpty, examined < 2200 {
            guard stillFrontmost(pid) else { return nil }
            if ProcessInfo.processInfo.systemUptime >= deadline { complete = false ; break }
            let (current, parent, depth) = queue.removeLast()
            examined += 1
            let hash = CFHash(current)
            if (seen[hash] ?? []).contains(where: { CFEqual($0, current) }) { continue }
            seen[hash, default: []].append(current)
            let values = multipleAttributes(current, [kAXRoleAttribute as CFString, kAXPositionAttribute as CFString,
                kAXSizeAttribute as CFString, kAXEnabledAttribute as CFString, "AXHidden" as CFString,
                "AXEditable" as CFString, kAXFocusedAttribute as CFString, kAXSelectedAttribute as CFString])
            let role = values[0] as? String ?? ""
            let rect = frame(position: values[1], size: values[2]) ?? .zero
            // Invisible descendants cannot be the active question or composer.
            if rect.width > 0, rect.height > 0, !windowRect.intersects(rect) { continue }
            if values[4] as? Bool == true { continue }
            let editable = inputRoles.contains(role) && values[5] as? Bool != false
            let actionable = ["AXButton", "AXRadioButton", "AXCheckBox", "AXRow"].contains(role) || (local && role == "AXGroup" && (12...75).contains(rect.height))
            let readMetadata = actionable || editable || ["AXGroup", "AXForm", "AXRadioGroup", "AXDialog", "AXSheet", "AXScrollArea", "AXWebArea", "AXListBox"].contains(role)
            var label = readMetadata ? metadata(current) : ""
            if role == "AXStaticText" || role == "AXHeading" {
                // Chromium may expose a badge or footer label through title/description.
                let attributes = multipleAttributes(current, [kAXValueAttribute as CFString, kAXTitleAttribute as CFString, kAXDescriptionAttribute as CFString])
                let fixed = questionTitles.union(customReplyTitles).union(standaloneReplyTitles).union(skipTitles).union(formSubmits).union(nextTitles).union(["下一步"])
                label = attributes.compactMap { $0 as? String }.map(normalized).first {
                    fixed.contains($0) || Int($0).map { (1...12).contains($0) } == true
                } ?? ""
                // Promote a fixed label to its enclosing button if AX omitted its name.
                if !label.isEmpty, let parent, nodes[parent].role == "AXButton" {
                    nodes[parent].label = [label, nodes[parent].label].filter { !$0.isEmpty }.joined(separator: "\n")
                }
            }
            let enabled = values[3] as? Bool != false
                && (!(actionable || editable) || (rect.width > 0 && rect.height > 0 && windowRect.intersects(rect)))
            let selected = role == "AXRadioButton" || role == "AXCheckBox"
                ? (values[7] as? Bool == true || numericSelection(current)) : false
            let index = nodes.count
            nodes.append(Node(parent: parent, role: role, label: label, rect: rect, enabled: enabled,
                focused: actionable || editable ? values[6] as? Bool == true : false,
                selected: selected, editable: editable, pressable: actionable && actions(current).contains(kAXPressAction as String)))
            elements.append(current)
            let kids = attribute(current, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
            if depth >= 96 && !kids.isEmpty { complete = false ; continue }
            queue.append(contentsOf: kids.map { ($0, index, depth + 1) })
        }
        guard stillFrontmost(pid) else { return nil }
        return Snapshot(pid: pid, app: ax, elements: elements, nodes: nodes, window: windowRect,
                        complete: complete && queue.isEmpty)
    }
    private static func attribute(_ node: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(node, name, &value) == .success ? value : nil
    }
    private static func string(_ node: AXUIElement, _ name: CFString) -> String? { attribute(node, name) as? String }
    private static func bool(_ node: AXUIElement, _ name: CFString) -> Bool? { attribute(node, name) as? Bool }
    private static func numericSelection(_ node: AXUIElement) -> Bool {
        // AXValue is read only for radio/checkbox state, never text controls/static text.
        guard let value = attribute(node, kAXValueAttribute as CFString), CFGetTypeID(value) == CFBooleanGetTypeID() || CFGetTypeID(value) == CFNumberGetTypeID() else { return false }
        return (value as? NSNumber)?.intValue == 1
    }
    private static func element(_ node: AXUIElement, _ name: CFString) -> AXUIElement? {
        guard let value = attribute(node, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private static func actions(_ node: AXUIElement) -> [String] {
        var result: CFArray?
        guard AXUIElementCopyActionNames(node, &result) == .success else { return [] }
        return result as? [String] ?? []
    }
    private static func metadata(_ node: AXUIElement) -> String {
        multipleAttributes(node, [kAXTitleAttribute as CFString, kAXDescriptionAttribute as CFString, kAXIdentifierAttribute as CFString,
         "AXPlaceholderValue" as CFString]).compactMap { $0 as? String }.joined(separator: "\n")
    }
    private static func multipleAttributes(_ node: AXUIElement, _ names: [CFString]) -> [CFTypeRef?] {
        var result: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(node, names as CFArray, [], &result) == .success,
              let values = result as? [CFTypeRef], values.count == names.count else { return names.map { _ in nil } }
        return values.map { $0 }
    }
    private static func frame(_ node: AXUIElement) -> CGRect? {
        let values = multipleAttributes(node, [kAXPositionAttribute as CFString, kAXSizeAttribute as CFString])
        return frame(position: values[0], size: values[1])
    }
    private static func frame(position: CFTypeRef?, size: CFTypeRef?) -> CGRect? {
        guard let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              origin.x.isFinite, origin.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }

    /// Pure fixture checks: no AX, keyboard, mouse, network, or actual Codex UI access.
    static func selfCheck() -> Bool {
        let window = CGRect(x: 0, y: 0, width: 1000, height: 800)
        var form = [
            Node(parent: nil, role: "AXWindow", rect: window),
            Node(parent: 0, role: "AXGroup", label: "request-user-input"),
            Node(parent: 1, role: "AXRadioGroup"),
            Node(parent: 2, role: "AXRadioButton", label: "First", selected: true, pressable: true),
            Node(parent: 2, role: "AXRadioButton", label: "Second", pressable: true),
            Node(parent: 1, role: "AXButton", label: "Previous question", pressable: true),
            Node(parent: 1, role: "AXButton", label: "Next question", pressable: true),
            Node(parent: 1, role: "AXButton", label: "Submit answers", pressable: true),
            Node(parent: 1, role: "AXTextArea", label: "Other", editable: true)
        ]
        guard let detected = activeForm(form), detected.options == [3, 4], detected.previous == 5,
              detected.next == 6, detected.submit == 7, preferredField(detected, nodes: form) == 8 else { return false }
        form[7].label = "提交答案"
        guard activeForm(form)?.submit == 7 else { return false }
        form[1].label = "answered-questions"
        guard activeForm(form) == nil else { return false }
        form[1].label = "普通消息"
        form[2].role = "AXGroup"
        guard activeForm(form) == nil else { return false }
        let dialog = [Node(parent: nil, role: "AXWindow", rect: window), Node(parent: 0, role: "AXDialog", label: "Delete chat?"),
                      Node(parent: 1, role: "AXButton", label: "Confirm", pressable: true)]
        guard activeForm(dialog) == nil, blocksChat(dialog) else { return false }
        let chat = [Node(parent: nil, role: "AXWindow", rect: window), Node(parent: 0, role: "AXGroup", label: "composer"),
                    Node(parent: 1, role: "AXTextArea", label: "Message", rect: CGRect(x: 350, y: 650, width: 600, height: 80), editable: true),
                    Node(parent: 1, role: "AXButton", label: "Send message", rect: CGRect(x: 900, y: 700, width: 40, height: 40), pressable: true),
                    Node(parent: 0, role: "AXButton", label: "Send message", pressable: true)]
        // Screenshot layout: a question card above the independent chat composer.
        // Question / answer prose is intentionally absent from the metadata projection.
        var card = [
            Node(parent: nil, role: "AXWindow", rect: window),                         // 0
            Node(parent: 0, role: "AXGroup"),                                        // 1
            Node(parent: 1, role: "AXGroup", rect: CGRect(x: 330, y: 240, width: 620, height: 330)), // 2
            Node(parent: 2, role: "AXStaticText", label: "问题"),                     // 3
            Node(parent: 2, role: "AXStaticText"),                                    // 4 question prose
            Node(parent: 2, role: "AXGroup", rect: CGRect(x: 350, y: 300, width: 570, height: 45)), // 5 row
            Node(parent: 5, role: "AXStaticText", label: "1", rect: CGRect(x: 360, y: 310, width: 20, height: 20)), // 6
            Node(parent: 5, role: "AXStaticText"),                                    // 7 answer prose
            Node(parent: 2, role: "AXGroup", rect: CGRect(x: 350, y: 350, width: 570, height: 45)), // 8 row
            Node(parent: 8, role: "AXStaticText", label: "2", rect: CGRect(x: 360, y: 360, width: 20, height: 20)), // 9
            Node(parent: 8, role: "AXStaticText"),                                    // 10 answer prose
            Node(parent: 2, role: "AXTextArea", label: "或自行撰写回复", rect: CGRect(x: 350, y: 420, width: 570, height: 65), editable: true), // 11
            Node(parent: 2, role: "AXGroup"),                                        // 12 footer
            Node(parent: 12, role: "AXButton", label: "跳过", pressable: true),        // 13
            Node(parent: 12, role: "AXButton", label: "发送", enabled: false, pressable: true), // 14
            Node(parent: 1, role: "AXGroup", label: "composer"),                     // 15
            Node(parent: 15, role: "AXTextArea", label: "Message", rect: CGRect(x: 350, y: 650, width: 600, height: 80), editable: true), // 16
            Node(parent: 15, role: "AXButton", label: "Send", pressable: true)         // 17
        ]
        var unnumbered = card
        unnumbered[3].rect = CGRect(x: 350, y: 247, width: 32, height: 18)
        unnumbered[13].rect = CGRect(x: 850, y: 426, width: 40, height: 21)
        unnumbered[6].label = ""; unnumbered[9].label = ""
        unnumbered[5].role = "AXButton"; unnumbered[8].role = "AXButton"
        guard activeForm(unnumbered)?.options == [5, 8], activeForm(unnumbered)?.submit == nil else { return false }
        unnumbered[5].role = "AXGroup"; unnumbered[8].role = "AXGroup"
        unnumbered[7].rect = CGRect(x: 386, y: 310, width: 83, height: 18)
        unnumbered[10].rect = CGRect(x: 386, y: 360, width: 42, height: 18)
        guard activeForm(unnumbered)?.options == [7, 10] else { return false }
        var missingPlaceholder = card
        missingPlaceholder[11].label = ""
        guard activeForm(missingPlaceholder)?.options == [6, 9] else { return false }
        missingPlaceholder[11].label = "或自行撰写回复"
        missingPlaceholder[3].label = ""
        guard activeForm(missingPlaceholder)?.options == [6, 9] else { return false }
        guard let screenshot = activeForm(card), screenshot.root == 2, screenshot.options == [6, 9],
              screenshot.fields == [11], screenshot.submit == nil, blocksChat(card),
              composer(card, window: window) == nil, composer(card, window: window, outside: screenshot) == 16 else { return false }
        var freeform = card
        freeform[6].label = ""; freeform[9].label = ""
        freeform[11].label = "回复…"
        freeform.append(Node(parent: 2, role: "AXButton", label: "上一个问题", pressable: true))
        guard let second = activeForm(freeform), second.fields == [11], second.options.isEmpty,
              second.previous == 18, second.immediateQuestion else { return false }
        freeform[14].label = "下一步"; freeform[14].enabled = true
        guard activeForm(freeform)?.submit == 14 else { return false }
        var running = freeform
        running[16].role = "AXTextField"; running[16].label = "处理中…"
        guard let runningForm = activeForm(running),
              composer(running, window: window, outside: runningForm) == 16 else { return false }
        running[16].label = "Reply…"
        guard composer(running, window: window, outside: runningForm) == nil else { return false }
        // A re-render can expose the custom field outside its old AX group.
        // Even with no usable composer, it must never be selected as chat input.
        var detached = card
        detached[11].parent = 1
        detached[11].rect = detached[16].rect
        detached[16].enabled = false
        guard composer(detached, window: window, outside: screenshot) == nil else { return false }
        // Ordinary option buttons must win over their number text descendants.
        card[5].role = "AXButton"; card[5].pressable = true
        card[8].role = "AXButton"; card[8].pressable = true
        card[14].enabled = true
        guard activeForm(card)?.options == [5, 8], activeForm(card)?.submit == 14 else { return false }
        card[5].label = "1 已完成第二次测试"; card[6].label = ""
        card[8].label = "2. 稍后再测"; card[9].label = ""
        guard activeForm(card)?.options == [5, 8],
              optionNumber(Node(parent: nil, role: "AXStaticText", label: "1 text")) == nil,
              optionNumber(Node(parent: nil, role: "AXButton", label: "1.2 version")) == nil,
              optionNumber(Node(parent: nil, role: "AXButton", label: "1 2026 plan")) == 1 else { return false }
        // English and per-question navigation share the same card boundary.
        card[3].label = "Question"; card[11].label = "Or write your own reply"
        card[13].label = "Skip"; card[14].label = "Send"
        card.append(Node(parent: 12, role: "AXButton", label: "Previous question", pressable: true)) // 18
        card.append(Node(parent: 12, role: "AXButton", label: "Next question", pressable: true))     // 19
        guard activeForm(card)?.previous == 18, activeForm(card)?.next == 19,
              activeForm(card)?.submit == 14 else { return false }
        // Missing card Send cannot borrow the chat Send, even without a composer label.
        card[14].label = ""; card[15].label = ""; card[16].label = ""
        guard activeForm(card)?.root == 2, activeForm(card)?.submit == nil, blocksChat(card) else { return false }
        card[5].label = ""; card[8].label = ""
        guard activeForm(card) == nil, blocksChat(card), composer(card, window: window) == nil else { return false }
        card[3].label = "" // A partial card with its unique placeholder still blocks chat.
        guard activeForm(card) == nil, blocksChat(card) else { return false }
        card[11].label = ""
        guard !blocksChat(card) else { return false }
        return activeForm(chat) == nil && composer(chat, window: window) == 2 && composerSend(2, nodes: chat) == 3
            && Action.allCases.count == 6 && Action(rawValue: "codex_scroll_up") == nil
    }
}
