import AppKit
import ApplicationServices
import CoreGraphics
import os

/// Codex 的语义导航。返回值表示动作名已识别；在途重复合并，不表示外部 App 已完成动作。
/// 不读取会话正文、推断 thread ID 或发送可能切换标签页的快捷键。
enum CodexNavigation {
    enum Action: String, CaseIterable, Sendable {
        case scrollUp = "codex_scroll_up"
        case scrollDown = "codex_scroll_down"
        case previousChat = "codex_previous_chat"
        case nextChat = "codex_next_chat"

        var isChatNavigation: Bool { self == .previousChat || self == .nextChat }
    }

    /// 主线程接线和调用。会话切换失败可打开 codex_sessions；滚动失败显示 message。
    /// 无接线时也显示非激活提示，不抢走 Codex 的输入焦点。
    @MainActor static var onUnavailable: ((_ actionName: String, _ message: String) -> Void)?
    @MainActor private static var noticePanel: NSPanel?
    @MainActor private static var noticeGeneration: UInt64 = 0

    /// 调度端即占用名额：主线程忙于 AX 时，重复事件不会继续创建 Task。
    /// cancel 不释放名额；旧 Task 退出并 finish 后才可再次申请，避免取消/重按也堆积任务。
    private struct Ticket: Equatable, Sendable {
        let id: UInt64
        let scrollEpoch: UInt64
        let isScrolling: Bool
    }

    private struct FlightGate: Sendable {
        private var serial: UInt64 = 0
        private var scrollEpoch: UInt64 = 0
        private var active: Ticket?

        mutating func begin(_ action: Action) -> Ticket? {
            guard active == nil else { return nil }
            serial &+= 1
            let ticket = Ticket(id: serial, scrollEpoch: scrollEpoch, isScrolling: !action.isChatNavigation)
            active = ticket
            return ticket
        }

        func accepts(_ ticket: Ticket) -> Bool {
            active == ticket && (!ticket.isScrolling || ticket.scrollEpoch == scrollEpoch)
        }

        mutating func cancelScrolling() { scrollEpoch &+= 1 }

        mutating func finish(_ ticket: Ticket) {
            if active == ticket { active = nil }
        }
    }

    private static let flightGate = OSAllocatedUnfairLock(initialState: FlightGate())

    /// 任意线程可调用。方向键松开、上下文/方案变化、打开面板时使旧滚动立即失效。
    /// 取消仅终止尚未发送的动作，不显示失败提示，也不会撤销已经投递的 OS 事件。
    static func cancelScrolling() { flightGate.withLock { $0.cancelScrolling() } }

    private static func isCurrent(_ ticket: Ticket) -> Bool {
        flightGate.withLock { $0.accepts(ticket) }
    }

    /// 取消与最终副作用在同一把锁内线性化，避免最后一次检查与投递之间的竞态。
    private static func ifCurrent(_ ticket: Ticket, _ body: () -> Bool) -> Bool {
        flightGate.withLock { state in state.accepts(ticket) && body() }
    }

    @discardableResult
    static func perform(_ name: String) -> Bool {
        guard let action = Action(rawValue: name) else { return false }
        guard let ticket = flightGate.withLock({ $0.begin(action) }) else { return true }
        Task { @MainActor in
            defer { flightGate.withLock { $0.finish(ticket) } }
            guard isCurrent(ticket) else { return }
            run(action, ticket: ticket)
        }
        return true
    }

    @MainActor private static func run(_ action: Action, ticket: Ticket) {
        guard isCurrent(ticket) else { return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              isAllowedBundle(app.bundleIdentifier) else {
            unavailable(action, "请先将 Codex 切到前台，再使用会话导航。", ticket: ticket)
            return
        }
        guard AXIsProcessTrusted() else {
            unavailable(action, "需要辅助功能权限，Codex 导航未执行。", ticket: ticket)
            return
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // 限制一次跨进程 AX 调用的等待；不重启 Codex 或更改其启动参数。
        AXUIElementSetMessagingTimeout(axApp, 0.05)
        if action.isChatNavigation {
            guard let menu = element(axApp, kAXMenuBarAttribute as CFString),
                  let item = findMenuItem(menu, action: action, ticket: ticket),
                  stillFrontmost(app.processIdentifier),
                  ifCurrent(ticket, { AXUIElementPerformAction(item, kAXPressAction as CFString) == .success }) else {
                unavailable(action, "Codex 未提供可用的上／下一个会话菜单，请从会话列表选择。", ticket: ticket)
                return
            }
            return
        }

        // Chromium 通常按需暴露 AX。只对已确认的前台 Codex 请求公开控件树。
        guard isCurrent(ticket) else { return }
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard isCurrent(ticket) else { return }
        AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        guard let window = element(axApp, kAXFocusedWindowAttribute as CFString),
              let windowFrame = frame(window),
              let target = findScrollTarget(window, windowFrame: windowFrame, ticket: ticket),
              stillFrontmost(app.processIdentifier) else {
            unavailable(action, "无法确认 Codex 回复滚动区域，本次未滚动。", ticket: ticket)
            return
        }
        // 有明确 AX 滚动动作时不移动鼠标。
        let scrollAction = action == .scrollUp ? "AXScrollUpByPage" : "AXScrollDownByPage"
        if actions(target.element).contains(scrollAction),
           ifCurrent(ticket, { AXUIElementPerformAction(target.element, scrollAction as CFString) == .success }) { return }

        guard let point = safeWheelPoint(target, app: axApp, ticket: ticket),
              stillFrontmost(app.processIdentifier),
              postWheel(at: point, up: action == .scrollUp, pid: app.processIdentifier, ticket: ticket) else {
            unavailable(action, "无法安全定位 Codex 回复滚动区域，本次未滚动。", ticket: ticket)
            return
        }
    }

    static func isAllowedBundle(_ bundleID: String?) -> Bool { bundleID == "com.openai.codex" }

    // MARK: - 精确匹配菜单语义

    /// 公开作者实现确认了 Previous Task / Next Task；其余是明确同义本地化，
    /// 不匹配 Next Tab、Next Window 或仅 Previous / Next。
    /// 参考：https://github.com/fanxeon/mi-ao/blob/main/Sources/MiAo/CodexSubmitter.swift
    static func menuTitleMatches(_ title: String, action: Action) -> Bool {
        let previous: Set<String> = [
            "previous task", "previous chat", "previous conversation", "previous thread",
            "上一个任务", "上一个会话", "上一个对话", "上一条会话", "上一個任務", "上一個會話", "上一個對話"
        ]
        let next: Set<String> = [
            "next task", "next chat", "next conversation", "next thread",
            "下一个任务", "下一个会话", "下一个对话", "下一条会话", "下一個任務", "下一個會話", "下一個對話"
        ]
        let normalized = title.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        switch action {
        case .previousChat: return previous.contains(normalized)
        case .nextChat: return next.contains(normalized)
        default: return false
        }
    }

    private static func findMenuItem(_ root: AXUIElement, action: Action, ticket: Ticket) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var head = 0
        var matches: [AXUIElement] = []
        var seen: [CFHashCode: [AXUIElement]] = [:]
        let deadline = ProcessInfo.processInfo.systemUptime + 0.7
        while head < queue.count, head < 900 {
            guard isCurrent(ticket), ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            let (current, depth) = queue[head]
            head += 1
            guard markVisited(current, in: &seen) else { continue }
            if string(current, kAXRoleAttribute as CFString) == "AXMenuItem",
               menuTitleMatches(string(current, kAXTitleAttribute as CFString) ?? "", action: action),
               bool(current, kAXEnabledAttribute as CFString) != false,
               actions(current).contains(kAXPressAction as String) {
                matches.append(current)
            }
            let descendants = children(current)
            guard depth < 6 || descendants.isEmpty else { return nil }
            queue.append(contentsOf: descendants.map { ($0, depth + 1) })
        }
        // 多个同名菜单项的目标不可证实时也不猜。
        return head == queue.count && matches.count == 1 ? matches[0] : nil
    }

    // MARK: - 只从可证明的回复列选择滚动区域

    struct ScrollFacts {
        var role: String
        var label: String
        var frame: CGRect
        var windowFrame: CGRect
        var editableFrames: [CGRect]
        var excludedContext: Bool
        var hasScrollMechanism: Bool
    }

    /// nil 表示证据不足。几何只采用窗口和 AX 元素相对位置，没有屏幕硬编码坐标。
    static func scrollScore(_ facts: ScrollFacts) -> Int? {
        let rect = facts.frame.intersection(facts.windowFrame)
        let window = facts.windowFrame
        guard ["AXScrollArea", "AXWebArea"].contains(facts.role), facts.hasScrollMechanism,
              !facts.excludedContext, !isExcludedLabel(facts.label),
              !rect.isNull, window.width > 0, window.height > 0,
              rect.width >= window.width * 0.35, rect.height >= window.height * 0.25,
              rect.width * rect.height < window.width * window.height * 0.94 else { return nil }
        // 内容区不能包含输入框；否则 wheel 可能落入整个网页或 composer。
        guard !facts.editableFrames.contains(where: { rect.intersects($0) }) else { return nil }
        let hasComposerBelow = facts.editableFrames.contains { input in
            input.minY >= rect.maxY - 4 && input.minY <= window.maxY &&
            abs(input.midX - rect.midX) <= max(rect.width, input.width) * 0.25 &&
            input.width >= rect.width * 0.45
        }
        let semantic = hasChatLabel(facts.label)
        guard semantic || hasComposerBelow else { return nil }
        return (semantic ? 500 : 0) + (hasComposerBelow ? 350 : 0)
            + Int(100 * rect.width * rect.height / (window.width * window.height))
    }

    private struct ScrollTarget {
        let element: AXUIElement
        let frame: CGRect
        let score: Int
    }

    private static func hasChatLabel(_ label: String) -> Bool {
        ["conversation", "transcript", "messages", "chat-content", "chat content", "thread-content",
         "thread content", "回复", "对话内容", "会话内容", "訊息", "對話內容"].contains { label.lowercased().contains($0) }
    }

    private static func isExcludedLabel(_ label: String) -> Bool {
        ["sidebar", "side bar", "navigation", "history", "composer", "prompt-input", "message-input",
         "search", "terminal", "diff", "侧栏", "侧边栏", "导航", "历史", "输入", "搜索", "終端", "側邊欄"]
            .contains { label.lowercased().contains($0) }
    }

    private static func findScrollTarget(_ root: AXUIElement, windowFrame: CGRect, ticket: Ticket) -> ScrollTarget? {
        var queue: [(AXUIElement, Int, Bool)] = [(root, 0, false)]
        var head = 0
        var seen: [CFHashCode: [AXUIElement]] = [:]
        var inputs: [CGRect] = []
        var candidates: [(AXUIElement, String, String, CGRect, Bool)] = []
        let deadline = ProcessInfo.processInfo.systemUptime + 0.7
        while head < queue.count, head < 2200 {
            guard isCurrent(ticket), ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            let (current, depth, inheritedExclusion) = queue[head]
            head += 1
            guard markVisited(current, in: &seen) else { continue }
            let role = string(current, kAXRoleAttribute as CFString) ?? ""
            // 仅控件元数据，绝不读取 AXValue / 正文文本。
            let labelRoles: Set<String> = ["AXScrollArea", "AXWebArea", "AXGroup", "AXSplitGroup", "AXOutline", "AXList"]
            let label = labelRoles.contains(role) ? metadata(current) : ""
            let editable = ["AXTextArea", "AXTextField", "AXSearchField", "AXComboBox"].contains(role)
                && bool(current, "AXEditable" as CFString) != false
            let excluded = inheritedExclusion || editable || isExcludedLabel(label)
            if let rect = frame(current), windowFrame.intersects(rect),
               bool(current, kAXEnabledAttribute as CFString) != false {
                if editable { inputs.append(rect) }
                if ["AXScrollArea", "AXWebArea"].contains(role) {
                    candidates.append((current, role, label, rect, excluded))
                }
            }
            let descendants = children(current)
            guard depth < 24 || descendants.isEmpty else { return nil }
            queue.append(contentsOf: descendants.map { ($0, depth + 1, excluded) })
        }
        // 树被截断时可能尚未发现输入框或侧栏，禁止靠不完整几何做 wheel。
        guard head == queue.count else { return nil }
        let scored = candidates.compactMap { candidate -> ScrollTarget? in
            guard isCurrent(ticket), ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            let (current, role, label, rect, excluded) = candidate
            let hasMechanism = role == "AXScrollArea"
                || actions(current).contains(where: { $0 == "AXScrollUpByPage" || $0 == "AXScrollDownByPage" })
                || element(current, kAXVerticalScrollBarAttribute as CFString) != nil
            guard let score = scrollScore(ScrollFacts(role: role, label: label, frame: rect,
                windowFrame: windowFrame, editableFrames: inputs, excludedContext: excluded,
                hasScrollMechanism: hasMechanism)) else { return nil }
            return ScrollTarget(element: current, frame: rect.intersection(windowFrame), score: score)
        }.sorted { $0.score > $1.score }
        guard isCurrent(ticket), ProcessInfo.processInfo.systemUptime < deadline,
              let best = scored.first else { return nil }
        // 两个不同区域证据相同则不冒险选中检查器等其它列。
        if scored.count > 1, best.score - scored[1].score < 40 { return nil }
        return best
    }

    private static func safeWheelPoint(_ target: ScrollTarget, app: AXUIElement, ticket: Ticket) -> CGPoint? {
        // 根据真实内容区域生成多个点；AX hit test 再排除内嵌编辑器/代码滚动区。
        for relative in [CGPoint(x: 0.65, y: 0.45), CGPoint(x: 0.45, y: 0.35), CGPoint(x: 0.75, y: 0.65)] {
            guard isCurrent(ticket) else { return nil }
            let point = CGPoint(x: target.frame.minX + target.frame.width * relative.x,
                                y: target.frame.minY + target.frame.height * relative.y)
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success,
                  var current = hit else { continue }
            var safe = false
            for _ in 0..<32 {
                guard isCurrent(ticket) else { return nil }
                if CFEqual(current, target.element) { safe = true; break }
                let role = string(current, kAXRoleAttribute as CFString) ?? ""
                if ["AXTextArea", "AXTextField", "AXSearchField", "AXComboBox", "AXScrollArea"].contains(role)
                    || isExcludedLabel(metadata(current)) { break }
                guard let parent = element(current, kAXParentAttribute as CFString) else { break }
                current = parent
            }
            if safe { return point }
        }
        return nil
    }

    @MainActor private static func postWheel(at point: CGPoint, up: Bool, pid: pid_t, ticket: Ticket) -> Bool {
        guard isCurrent(ticket), let original = CGEvent(source: nil)?.location,
              let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: up ? 300 : -300, wheel2: 0, wheel3: 0),
              stillFrontmost(pid) else { return false }
        wheel.location = point
        wheel.flags = []
        // 移动真实指针使 Chromium 命中正确 pane；每条路径均恢复原位置，不单击/聚焦。
        guard ifCurrent(ticket, { CGWarpMouseCursorPosition(point) == .success }) else { return false }
        defer { CGWarpMouseCursorPosition(original) }
        guard stillFrontmost(pid) else { return false }
        // 定向投递防止前台在最后一次检查后变化时影响其它应用。
        return ifCurrent(ticket) { wheel.postToPid(pid); return true }
    }

    @MainActor private static func stillFrontmost(_ pid: pid_t) -> Bool {
        let app = NSWorkspace.shared.frontmostApplication
        return app?.processIdentifier == pid && isAllowedBundle(app?.bundleIdentifier)
    }

    // MARK: - AX 访问（有界、无正文日志）

    private static func markVisited(_ element: AXUIElement, in seen: inout [CFHashCode: [AXUIElement]]) -> Bool {
        let hash = CFHash(element)
        guard !(seen[hash] ?? []).contains(where: { CFEqual($0, element) }) else { return false }
        seen[hash, default: []].append(element)
        return true
    }

    private static func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }

    private static func element(_ element: AXUIElement, _ name: CFString) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ name: CFString) -> String? {
        attribute(element, name) as? String
    }

    private static func bool(_ element: AXUIElement, _ name: CFString) -> Bool? {
        attribute(element, name) as? Bool
    }

    private static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    private static func metadata(_ element: AXUIElement) -> String {
        [kAXIdentifierAttribute as CFString, kAXTitleAttribute as CFString, kAXDescriptionAttribute as CFString]
            .compactMap { string(element, $0) }.joined(separator: " ")
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute as CFString),
              let size = attribute(element, kAXSizeAttribute as CFString),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              origin.x.isFinite, origin.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }

    @MainActor private static func unavailable(_ action: Action, _ message: String, ticket: Ticket) {
        guard isCurrent(ticket) else { return }
        if let onUnavailable { onUnavailable(action.rawValue, message); return }
        showNotice(message)
    }

    @MainActor static func showNotice(_ message: String) {
        let panel = noticePanel ?? NSPanel(contentRect: CGRect(x: 0, y: 0, width: 440, height: 88),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        noticePanel = panel
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.backgroundColor = .windowBackgroundColor
        panel.hasShadow = true
        let label = NSTextField(wrappingLabelWithString: message)
        label.frame = CGRect(x: 20, y: 16, width: 400, height: 56)
        label.font = .systemFont(ofSize: 14)
        panel.contentView?.subviews.forEach { $0.removeFromSuperview() }
        panel.contentView?.addSubview(label)
        panel.center()
        panel.orderFrontRegardless()
        noticeGeneration &+= 1
        let generation = noticeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard generation == noticeGeneration else { return }
            noticePanel?.orderOut(nil)
        }
    }

    /// 仅纯逻辑；不读取 UI、不发送键盘/鼠标、不显示提示。
    static func selfCheck() -> Bool {
        var gate = FlightGate()
        guard let first = gate.begin(.scrollDown), gate.accepts(first) else { return false }
        // 连续重复和相反方向都共用唯一的在途/排队名额。
        for index in 0..<1000 {
            guard gate.begin(index.isMultiple(of: 2) ? .scrollDown : .scrollUp) == nil else { return false }
        }
        gate.cancelScrolling()
        guard !gate.accepts(first), gate.begin(.scrollUp) == nil else { return false }
        gate.finish(first)
        guard let second = gate.begin(.scrollUp), gate.accepts(second), second != first else { return false }
        // 过期清理不能释放较新的任务，取消只影响滚动。
        gate.finish(first)
        guard gate.accepts(second), gate.begin(.nextChat) == nil else { return false }
        gate.finish(second)
        guard let chat = gate.begin(.nextChat) else { return false }
        gate.cancelScrolling()
        guard gate.accepts(chat), gate.begin(.previousChat) == nil else { return false }
        gate.finish(chat)
        guard let final = gate.begin(.scrollDown), gate.accepts(final) else { return false }
        gate.finish(final)
        guard Action.allCases.count == 4, Action(rawValue: "next_tab") == nil,
              isAllowedBundle("com.openai.codex"), !isAllowedBundle("com.openai.chat"), !isAllowedBundle(nil),
              menuTitleMatches("  Previous Task  ", action: .previousChat),
              menuTitleMatches("下一个会话", action: .nextChat),
              menuTitleMatches("Next Conversation", action: .nextChat),
              !menuTitleMatches("Next Tab", action: .nextChat),
              !menuTitleMatches("Next Window", action: .nextChat),
              !menuTitleMatches("Next Task", action: .previousChat),
              !menuTitleMatches("Next Task Settings", action: .nextChat),
              !menuTitleMatches("Next Chat", action: .scrollDown) else { return false }
        let window = CGRect(x: -1200, y: 80, width: 1200, height: 900)
        let input = CGRect(x: -880, y: 820, width: 820, height: 120)
        var facts = ScrollFacts(role: "AXScrollArea", label: "", frame: CGRect(x: -900, y: 150, width: 880, height: 660),
            windowFrame: window, editableFrames: [input], excludedContext: false, hasScrollMechanism: true)
        guard scrollScore(facts) != nil else { return false }
        facts.label = "sidebar chat history"
        guard scrollScore(facts) == nil else { return false }
        facts.label = "conversation"
        facts.frame = input
        guard scrollScore(facts) == nil else { return false }
        facts.frame = window
        guard scrollScore(facts) == nil else { return false }
        facts.frame = CGRect(x: -900, y: 150, width: 880, height: 660)
        facts.excludedContext = true
        guard scrollScore(facts) == nil else { return false }
        facts.excludedContext = false
        facts.hasScrollMechanism = false
        guard scrollScore(facts) == nil else { return false }
        facts.hasScrollMechanism = true
        facts.label = ""
        facts.editableFrames = []
        guard scrollScore(facts) == nil else { return false }
        facts.label = "conversation"
        return scrollScore(facts) != nil
    }
}
