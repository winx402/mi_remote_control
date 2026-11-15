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
    }
    private struct Snapshot {
        var pid: pid_t
        var app: AXUIElement
        var elements: [AXUIElement]
        var nodes: [Node]
        var window: CGRect
        var complete: Bool
    }

    @MainActor private static var lastOption: AXUIElement?
    @MainActor private static var lastFormRoot: AXUIElement?
    @MainActor private static var accessibilityPID: pid_t?

    private static let inputRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]
    private static let formMarkers = ["request-user-input", "request_user_input", "requestuserinput", "user-input-form",
                                      "question-form", "questionnaire", "ask-user-question", "askuserquestion",
                                      "回答问题", "回答問題", "用户提问", "使用者提問"]
    private static let answerSubmits: Set<String> = ["submit answers", "submit answer", "send answers", "confirm answers",
        "提交答案", "提交回答", "确认答案", "確認答案", "送出答案", "提交所有答案", "提交全部答案"]
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
        for _ in 0..<32 {
            guard let value = current else { return false }
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

    /// The current question card has no dedicated AX identifier in some Codex builds.
    /// Its fixed UI anchors, numbered choices and local footer provide the boundary.
    /// Disabled Send is part of the structure but is never an actionable submission.
    private static func questionCards(_ nodes: [Node]) -> [Form] {
        var roots = Set<Int>()
        for title in nodes.indices where matches(nodes[title], questionTitles.union(customReplyTitles).union(skipTitles)) {
            var parent: Int? = title
            for _ in 0..<32 {
                guard let value = parent else { break }
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
            let options = numberedOptions(members, root: root, nodes: nodes)
            guard !options.isEmpty else { continue }
            let submits = members.filter { nodes[$0].role == "AXButton" && matches(nodes[$0], formSubmits) }
            let fields = members.filter { nodes[$0].enabled && nodes[$0].editable && inputRoles.contains(nodes[$0].role) }
            func uniqueEnabled(_ titles: Set<String>) -> Int? {
                let controls = members.filter { nodes[$0].role == "AXButton" && nodes[$0].enabled
                    && nodes[$0].pressable && matches(nodes[$0], titles) }
                return controls.count == 1 ? controls[0] : nil
            }
            cards.append(Form(root: root, options: options, fields: fields,
                              previous: uniqueEnabled(previousTitles), next: uniqueEnabled(nextTitles),
                              submit: submits.count == 1 ? uniqueEnabled(formSubmits) : nil))
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

    private static func composer(_ nodes: [Node], window: CGRect) -> Int? {
        guard !blocksChat(nodes), window.height > 0 else { return nil }
        let candidates = nodes.indices.filter { index in
            let n = nodes[index]
            guard inputRoles.contains(n.role), n.editable, n.enabled, !historicallyInactive(index, in: nodes),
                  n.rect.width >= window.width * 0.25, n.rect.midY >= window.minY + window.height * 0.50,
                  !contains(n.label, ["search", "find", "filter", "terminal", "搜索", "查找", "过滤", "终端"]) else { return false }
            return contains(n.label, ["composer", "message", "prompt", "chat input", "消息", "输入", "輸入", "回复", "回覆"])
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

    @MainActor @discardableResult static func perform(_ name: String, isCurrent: () -> Bool = { true }) -> Bool {
        guard let action = Action(rawValue: name) else { return false }
        trace.notice("remote action=\(name, privacy: .public)")
        guard isCurrent() else { return true }
        let scrolling = action == .up || action == .down
        guard let snapshot = snapshot(budget: scrolling ? 0.16 : 0.65) else {
            // A large Chromium tree must not make normal wheel input unusable.
            if scrolling && isCurrent() { fallbackScroll(action == .up, isCurrent: isCurrent) }
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
            if scrolling && !blocksChat(snapshot.nodes) { fallbackScroll(action == .up, snapshot: snapshot, isCurrent: isCurrent) }
            else if !scrolling { unavailable("当前控件信息不完整，本次未执行确认或输入。") }
            return true
        }
        if let form = recognized {
            switch action {
            case .up, .down:
                let choices = form.options
                guard !choices.isEmpty else { return true }
                let current = choices.firstIndex { snapshot.nodes[$0].focused }
                    ?? choices.firstIndex { snapshot.nodes[$0].selected }
                    ?? choices.firstIndex {
                        guard let lastFormRoot, let lastOption,
                              CFEqual(lastFormRoot, snapshot.elements[form.root]) else { return false }
                        return CFEqual(lastOption, snapshot.elements[$0])
                    }
                let next = current.map { min(choices.count - 1, max(0, $0 + (action == .up ? -1 : 1))) }
                    ?? (action == .up ? choices.count - 1 : 0)
                let applied = select(choices[next], in: snapshot, isCurrent: isCurrent)
                trace.notice("selected ordinal=\(next + 1) dispatched=\(applied)")
                if applied {
                    lastFormRoot = snapshot.elements[form.root]
                    lastOption = snapshot.elements[choices[next]]
                }
            case .left: press(form.previous, in: snapshot, isCurrent: isCurrent)
            case .right: press(form.next, in: snapshot, isCurrent: isCurrent)
            case .ok:
                let choice = form.options.first { index in
                    if snapshot.nodes[index].focused || snapshot.nodes[index].selected { return true }
                    guard let lastFormRoot, let lastOption, CFEqual(lastFormRoot, snapshot.elements[form.root]) else { return false }
                    return CFEqual(lastOption, snapshot.elements[index])
                }
                if let choice {
                    select(choice, in: snapshot, isCurrent: isCurrent)
                } else if let field = preferredField(form, nodes: snapshot.nodes) {
                    _ = focus(field, in: snapshot)
                } else if let first = form.options.first { select(first, in: snapshot, isCurrent: isCurrent) }
            case .submit:
                // Never synthesize Return: no confirmed button means no submission.
                if let submit = form.submit { press(submit, in: snapshot, isCurrent: isCurrent) }
                else { unavailable("未找到当前提问的明确提交按钮，本次未提交。") }
            }
        } else if blocksChat(snapshot.nodes) {
            unavailable("当前弹层或提问控件尚未确认，请在 Codex 中检查。")
        } else {
            switch action {
            case .up, .down: scroll(action == .up, snapshot: snapshot, isCurrent: isCurrent)
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

    private static func preferredField(_ form: Form, nodes: [Node]) -> Int? {
        let focused = form.fields.filter { nodes[$0].focused }
        if focused.count == 1 { return focused[0] }
        return form.fields.count == 1 ? form.fields[0] : nil
    }

    @MainActor static func focusForDictation() -> Bool {
        guard let snapshot = snapshot(), snapshot.complete else { return false }
        if let form = activeForm(snapshot.nodes) {
            if let field = preferredField(form, nodes: snapshot.nodes) { return focus(field, in: snapshot) }
            let otherTitles: Set<String> = ["other", "something else", "type your own answer", "custom answer", "其他", "其它", "其他答案", "自定义答案", "自訂答案"]
            let other = form.options.filter { matches(snapshot.nodes[$0], otherTitles) }
            guard other.count == 1 else { return false }
            select(other[0], in: snapshot)
            // Selecting Other can reveal an editable field. A fresh AX projection is required;
            // never dictate into the old chat composer while a question is active.
            guard let updated = self.snapshot(), updated.complete, let currentForm = activeForm(updated.nodes),
                  let field = preferredField(currentForm, nodes: updated.nodes) else { return false }
            return focus(field, in: updated)
        }
        guard let field = composer(snapshot.nodes, window: snapshot.window) else { return false }
        return focus(field, in: snapshot)
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
                                                             isCurrent: () -> Bool = { true }) -> Bool {
        guard isCurrent(), sameWindow(snapshot), snapshot.nodes[index].enabled else { return false }
        let target = snapshot.elements[index]
        if !snapshot.nodes[index].selected {
            if actions(target).contains(kAXPressAction as String),
               AXUIElementPerformAction(target, kAXPressAction as CFString) == .success {
                _ = focus(index, in: snapshot)
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
    @MainActor private static func focus(_ index: Int, in snapshot: Snapshot) -> Bool {
        guard sameWindow(snapshot), snapshot.nodes[index].enabled else { return false }
        let target = snapshot.elements[index]
        guard AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else { return false }
        return stillFrontmost(snapshot.pid) && bool(target, kAXFocusedAttribute as CFString) == true
    }

    // MARK: - Ordinary pixel wheel, never keyboard arrows or AX page scrolling

    @MainActor private static func scroll(_ up: Bool, snapshot: Snapshot, isCurrent: () -> Bool) {
        let inputRects = snapshot.nodes.filter { $0.editable }.map(\.rect)
        let scored = snapshot.nodes.indices.compactMap { index -> (Int, Int)? in
            let n = snapshot.nodes[index]
            guard ["AXScrollArea", "AXWebArea"].contains(n.role) else { return nil }
            guard let score = CodexNavigation.scrollScore(.init(role: n.role, label: n.label, frame: n.rect,
                windowFrame: snapshot.window, editableFrames: inputRects,
                excludedContext: historicallyInactive(index, in: snapshot.nodes) || excludedScroll(index, nodes: snapshot.nodes),
                hasScrollMechanism: n.role == "AXScrollArea" || actions(snapshot.elements[index]).contains("AXScrollDownByPage"))) else { return nil }
            return (index, score)
        }.sorted { $0.1 > $1.1 }
        guard let target = scored.first, scored.count == 1 || target.1 - scored[1].1 >= 40 else {
            fallbackScroll(up, snapshot: snapshot, isCurrent: isCurrent) ; return
        }
        let rect = snapshot.nodes[target.0].rect.intersection(snapshot.window)
        for relative in [CGPoint(x: 0.65, y: 0.45), CGPoint(x: 0.45, y: 0.35), CGPoint(x: 0.75, y: 0.65)] {
            let point = CGPoint(x: rect.minX + rect.width * relative.x, y: rect.minY + rect.height * relative.y)
            guard sameWindow(snapshot), isCurrent() else { return }
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(snapshot.app, Float(point.x), Float(point.y), &hit) == .success,
                  var current = hit else { continue }
            var safe = false
            for _ in 0..<32 {
                if CFEqual(current, snapshot.elements[target.0]) { safe = true ; break }
                let role = string(current, kAXRoleAttribute as CFString) ?? ""
                if inputRoles.contains(role) || ["AXSearchField", "AXScrollArea", "AXButton", "AXLink"].contains(role) { break }
                guard let parent = element(current, kAXParentAttribute as CFString) else { break }
                current = parent
            }
            guard safe, let original = CGEvent(source: nil)?.location,
                  let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                      wheel1: up ? 90 : -90, wheel2: 0, wheel3: 0), stillFrontmost(snapshot.pid) else { continue }
            wheel.flags = []
            wheel.location = point
            guard CGWarpMouseCursorPosition(point) == .success else { return }
            defer { CGWarpMouseCursorPosition(original) }
            if sameWindow(snapshot), isCurrent() { wheel.postToPid(snapshot.pid) }
            return
        }
        fallbackScroll(up, snapshot: snapshot, isCurrent: isCurrent)
    }

    /// No full-tree dependency: validate an unobstructed content hit and its ancestors.
    /// Ambiguous editor/dialog hits quietly do nothing instead of producing repeated notices.
    @MainActor private static func fallbackScroll(_ up: Bool, snapshot supplied: Snapshot? = nil, isCurrent: () -> Bool = { true }) {
        let context: Snapshot
        if let supplied { context = supplied }
        else {
            guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.openai.codex",
                  AXIsProcessTrusted() else { return }
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(ax, 0.025)
            guard let win = element(ax, kAXFocusedWindowAttribute as CFString), let rect = frame(win) else { return }
            context = Snapshot(pid: app.processIdentifier, app: ax, elements: [win],
                               nodes: [Node(parent: nil, role: "AXWindow", rect: rect)], window: rect, complete: false)
        }
        guard sameWindow(context), isCurrent(), !blocksChat(context.nodes) else { return }
        // Sheets and a focused modal block scrolling even if absent from a truncated walk.
        if let win = context.elements.first,
           let sheets = attribute(win, "AXSheets" as CFString) as? [AXUIElement], !sheets.isEmpty { return }
        if let focused = element(context.app, kAXFocusedUIElementAttribute as CFString),
           hitPathUnsafe(focused, pid: context.pid, allowInputAtLeaf: true) { return }
        let rect = context.window
        guard rect.width >= 350, rect.height >= 250 else { return }
        for relative in [CGPoint(x: 0.70, y: 0.42), CGPoint(x: 0.62, y: 0.52)] {
            let point = CGPoint(x: rect.minX + rect.width * relative.x, y: rect.minY + rect.height * relative.y)
            var hit: AXUIElement?
            guard stillFrontmost(context.pid),
                  AXUIElementCopyElementAtPosition(context.app, Float(point.x), Float(point.y), &hit) == .success,
                  let hit, !hitPathUnsafe(hit, pid: context.pid, allowInputAtLeaf: false),
                  let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                      wheel1: up ? 90 : -90, wheel2: 0, wheel3: 0),
                  let original = CGEvent(source: nil)?.location, stillFrontmost(context.pid) else { continue }
            wheel.flags = []
            wheel.location = point
            guard CGWarpMouseCursorPosition(point) == .success else { return }
            defer { CGWarpMouseCursorPosition(original) }
            if sameWindow(context), isCurrent() { wheel.postToPid(context.pid) }
            return
        }
    }

    private static func hitPathUnsafe(_ leaf: AXUIElement, pid: pid_t, allowInputAtLeaf: Bool) -> Bool {
        var current = leaf
        var content = false
        let deadline = ProcessInfo.processInfo.systemUptime + 0.12
        for depth in 0..<24 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return true }
            var actualPID: pid_t = 0
            guard AXUIElementGetPid(current, &actualPID) == .success, actualPID == pid else { return true }
            let role = string(current, kAXRoleAttribute as CFString) ?? ""
            let label = ["AXStaticText", "AXHeading"].contains(role) ? "" : metadata(current)
            if ["AXDialog", "AXSheet", "AXMenu", "AXRadioGroup", "AXRadioButton", "AXCheckBox", "AXListBox"].contains(role)
                || contains(label, formMarkers)
                || (!allowInputAtLeaf && contains(label, ["sidebar", "side bar", "navigation", "history", "search", "terminal", "diff", "code editor", "侧栏", "侧边栏", "导航", "历史", "搜索", "终端", "差异", "編輯器"]))
                || (!allowInputAtLeaf && (inputRoles.contains(role) || role == "AXSearchField"))
                || (depth == 0 && !allowInputAtLeaf && ["AXButton", "AXLink"].contains(role)) { return true }
            if ["AXWebArea", "AXScrollArea"].contains(role) { content = true }
            if role == "AXWindow" { return !content && !allowInputAtLeaf }
            guard let parent = element(current, kAXParentAttribute as CFString) else { return true }
            current = parent
        }
        return true
    }
    private static func excludedScroll(_ index: Int, nodes: [Node]) -> Bool {
        var current: Int? = index
        while let value = current {
            if contains(nodes[value].label, ["sidebar", "side bar", "navigation", "history", "composer", "search", "terminal", "diff", "侧栏", "侧边栏", "导航", "历史", "搜索", "输入", "終端"]) { return true }
            current = nodes[value].parent
        }
        return false
    }

    // MARK: - Bounded AX snapshot, with no text values

    @MainActor private static func snapshot(budget: TimeInterval = 0.65) -> Snapshot? {
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
        let deadline = ProcessInfo.processInfo.systemUptime + 0.32
        var visited = Set<AXUIElement>()
        for fraction in [0.76, 0.63, 0.84] {
            let point = CGPoint(x: windowRect.minX + windowRect.width * 0.61,
                                y: windowRect.minY + windowRect.height * fraction)
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(ax, Float(point.x), Float(point.y), &hit) == .success,
                  var candidate = hit else { continue }
            for _ in 0..<14 {
                guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                if visited.insert(candidate).inserted, let bounds = frame(candidate),
                   bounds.width >= windowRect.width * 0.25, bounds.height >= 100,
                   bounds.height <= windowRect.height * 0.70,
                   let local = project(ax, window: window, rect: windowRect, root: candidate,
                                       pid: app.processIdentifier, budget: 0.22),
                   local.complete, activeForm(local.nodes) != nil { return local }
                guard let parent = element(candidate, kAXParentAttribute as CFString), !CFEqual(parent, window) else { break }
                candidate = parent
            }
        }
        return project(ax, window: window, rect: windowRect, root: window, pid: app.processIdentifier, budget: budget)
    }

    @MainActor private static func project(_ ax: AXUIElement, window: AXUIElement, rect windowRect: CGRect,
                                           root: AXUIElement, pid: pid_t, budget: TimeInterval) -> Snapshot? {
        let local = !CFEqual(window, root)
        var queue: [(AXUIElement, Int?, Int)] = [(root, local ? 0 : nil, 0)]
        var head = 0
        var nodes: [Node] = local ? [Node(parent: nil, role: "AXWindow", rect: windowRect)] : []
        var elements: [AXUIElement] = local ? [window] : []
        var seen: [CFHashCode: [AXUIElement]] = [:]
        let deadline = ProcessInfo.processInfo.systemUptime + budget
        var complete = true
        while head < queue.count, head < 1800 {
            guard stillFrontmost(pid) else { return nil }
            if ProcessInfo.processInfo.systemUptime >= deadline { complete = false ; break }
            let (current, parent, depth) = queue[head]
            head += 1
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
            let actionable = ["AXButton", "AXRadioButton", "AXCheckBox"].contains(role)
            let readMetadata = actionable || editable || ["AXGroup", "AXForm", "AXRadioGroup", "AXDialog", "AXSheet", "AXScrollArea", "AXWebArea", "AXListBox"].contains(role)
            var label = readMetadata ? metadata(current) : ""
            if role == "AXStaticText" || role == "AXHeading" {
                // Chromium may expose a badge or footer label through title/description.
                let attributes = multipleAttributes(current, [kAXValueAttribute as CFString, kAXTitleAttribute as CFString, kAXDescriptionAttribute as CFString])
                let fixed = questionTitles.union(customReplyTitles).union(skipTitles).union(formSubmits)
                label = attributes.compactMap { $0 as? String }.map(normalized).first {
                    fixed.contains($0) || Int($0).map { (1...12).contains($0) } == true
                } ?? ""
                // Promote a fixed label to its enclosing button if AX omitted its name.
                if !label.isEmpty, let parent, nodes[parent].role == "AXButton", nodes[parent].label.isEmpty {
                    nodes[parent].label = label
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
            if depth >= 25 && !kids.isEmpty { complete = false ; continue }
            queue.append(contentsOf: kids.map { ($0, index, depth + 1) })
        }
        guard stillFrontmost(pid) else { return nil }
        return Snapshot(pid: pid, app: ax, elements: elements, nodes: nodes, window: windowRect,
                        complete: complete && head == queue.count)
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
        var missingPlaceholder = card
        missingPlaceholder[11].label = ""
        guard activeForm(missingPlaceholder)?.options == [6, 9] else { return false }
        missingPlaceholder[11].label = "或自行撰写回复"
        missingPlaceholder[3].label = ""
        guard activeForm(missingPlaceholder)?.options == [6, 9] else { return false }
        guard let screenshot = activeForm(card), screenshot.root == 2, screenshot.options == [6, 9],
              screenshot.fields == [11], screenshot.submit == nil, blocksChat(card),
              composer(card, window: window) == nil else { return false }
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
