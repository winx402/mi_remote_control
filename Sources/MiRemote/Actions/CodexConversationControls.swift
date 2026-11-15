import AppKit
import ApplicationServices
import CoreGraphics

/// 前台 Codex 的上下文控件。只读取控件元数据；不读取输入值、消息正文或会话文件。
/// OK 从不发送；只有独立的 submit 动作能压下经确认的发送/提交按钮。
enum CodexConversationControls {
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

    /// 只接受专用提问组件，或同时具备单选组和明确 Submit answers 语义的有界组件。
    /// 普通消息、Markdown 列表及只有 OK/Confirm 的通用对话框均不构成表单。
    private static func activeForm(_ nodes: [Node]) -> Form? {
        var forms: [Form] = []
        let containers: Set<String> = ["AXGroup", "AXForm", "AXRadioGroup", "AXDialog"]
        var roots = Set(nodes.indices.filter { containers.contains(nodes[$0].role) && contains(nodes[$0].label, formMarkers) })
        // Ordinary transcript groups need no descendant scans. Only walk ancestors of an
        // actual answer-submit control when the dedicated widget marker is absent.
        for index in nodes.indices where nodes[index].enabled && nodes[index].role == "AXButton" && matches(nodes[index], answerSubmits) {
            var parent = nodes[index].parent
            while let value = parent {
                if containers.contains(nodes[value].role) { roots.insert(value) }
                parent = nodes[value].parent
            }
        }
        for root in roots.sorted() {
            guard !historicallyInactive(root, in: nodes) else { continue }
            let members = nodes.indices.filter { descendant($0, of: root, in: nodes) }
            guard members.count <= 160 else { continue }
            let buttons = members.filter { nodes[$0].enabled && nodes[$0].pressable && nodes[$0].role == "AXButton" }
            let marked = contains(nodes[root].label, formMarkers)
            let radios = members.filter { nodes[$0].enabled && nodes[$0].pressable && ["AXRadioButton", "AXCheckBox"].contains(nodes[$0].role) }
            let hasRadioGroup = members.contains { nodes[$0].role == "AXRadioGroup" }
            let explicitSubmit = buttons.filter { matches(nodes[$0], answerSubmits) }
            guard marked || (hasRadioGroup && radios.count >= 2 && explicitSubmit.count == 1) else { continue }
            let fields = members.filter { nodes[$0].enabled && nodes[$0].editable && inputRoles.contains(nodes[$0].role) }
            let options = members.filter { index in
                if radios.contains(index) { return true }
                guard marked, nodes[index].role == "AXButton", nodes[index].enabled, nodes[index].pressable,
                      !matches(nodes[index], formSubmits.union(previousTitles).union(nextTitles)) else { return false }
                // Generic buttons are options only inside an actual radio/listbox option group.
                return members.contains { ["AXRadioGroup", "AXListBox"].contains(nodes[$0].role) && descendant(index, of: $0, in: nodes) }
            }
            guard !options.isEmpty || !fields.isEmpty else { continue }
            func unique(_ titles: Set<String>) -> Int? {
                let result = buttons.filter { matches(nodes[$0], titles) }
                return result.count == 1 ? result[0] : nil
            }
            forms.append(Form(root: root, options: options, fields: fields,
                              previous: unique(previousTitles), next: unique(nextTitles), submit: unique(formSubmits)))
        }
        // An outer question panel may contain the actual form. Prefer its deepest unique child;
        // two unrelated visible forms are ambiguous and must never cause submission.
        let deepest = forms.filter { outer in !forms.contains { $0.root != outer.root && descendant($0.root, of: outer.root, in: nodes) } }
        return deepest.count == 1 ? deepest[0] : nil
    }

    private static func blocksChat(_ nodes: [Node]) -> Bool {
        nodes.contains { ["AXDialog", "AXSheet"].contains($0.role) }
            || nodes.contains { contains($0.label, formMarkers) && $0.enabled }
            || nodes.contains { $0.role == "AXButton" && $0.enabled && matches($0, answerSubmits) }
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
        guard isCurrent() else { return true }
        let scrolling = action == .up || action == .down
        guard let snapshot = snapshot(budget: scrolling ? 0.16 : 0.65) else {
            // A large Chromium tree must not make normal wheel input unusable.
            if scrolling && isCurrent() { fallbackScroll(action == .up, isCurrent: isCurrent) }
            else { unavailable("无法确认前台 Codex 的可用控件，本次未执行。") }
            return true
        }
        guard isCurrent(), sameWindow(snapshot) else { return true }
        guard snapshot.complete else {
            if scrolling && !blocksChat(snapshot.nodes) { fallbackScroll(action == .up, snapshot: snapshot, isCurrent: isCurrent) }
            else if !scrolling { unavailable("当前控件信息不完整，本次未执行确认或输入。") }
            return true
        }
        if let form = activeForm(snapshot.nodes) {
            switch action {
            case .up, .down:
                let choices = form.options
                guard !choices.isEmpty else { return true }
                let current = choices.firstIndex { snapshot.nodes[$0].focused }
                    ?? choices.firstIndex { snapshot.nodes[$0].selected }
                let next = current.map { min(choices.count - 1, max(0, $0 + (action == .up ? -1 : 1))) }
                    ?? (action == .up ? choices.count - 1 : 0)
                select(choices[next], in: snapshot, isCurrent: isCurrent)
            case .left: press(form.previous, in: snapshot, isCurrent: isCurrent)
            case .right: press(form.next, in: snapshot, isCurrent: isCurrent)
            case .ok:
                if let field = preferredField(form, nodes: snapshot.nodes) { _ = focus(field, in: snapshot) }
                else if let choice = form.options.first(where: { snapshot.nodes[$0].focused || snapshot.nodes[$0].selected }) ?? form.options.first {
                    select(choice, in: snapshot, isCurrent: isCurrent)
                }
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
    @MainActor private static func select(_ index: Int, in snapshot: Snapshot, isCurrent: () -> Bool = { true }) {
        // Avoid unchecking an already selected multi-select answer.
        if !snapshot.nodes[index].selected { press(index, in: snapshot, isCurrent: isCurrent) }
        if isCurrent() { _ = focus(index, in: snapshot) }
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
        var queue: [(AXUIElement, Int?, Int)] = [(window, nil, 0)]
        var head = 0
        var nodes: [Node] = []
        var elements: [AXUIElement] = []
        var seen: [CFHashCode: [AXUIElement]] = [:]
        let deadline = ProcessInfo.processInfo.systemUptime + budget
        var complete = true
        while head < queue.count, head < 1800 {
            guard stillFrontmost(app.processIdentifier) else { return nil }
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
            let label = readMetadata ? metadata(current) : ""
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
        guard stillFrontmost(app.processIdentifier) else { return nil }
        return Snapshot(pid: app.processIdentifier, app: ax, elements: elements, nodes: nodes, window: windowRect,
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
        return activeForm(chat) == nil && composer(chat, window: window) == 2 && composerSend(2, nodes: chat) == 3
            && Action.allCases.count == 6 && Action(rawValue: "codex_scroll_up") == nil
    }
}
