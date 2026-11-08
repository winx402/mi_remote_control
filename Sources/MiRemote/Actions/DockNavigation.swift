import AppKit
import ApplicationServices
import CoreGraphics

/// 四方向都沿真实 Dock 的 App 序列移动，避免向 Dock 的内侧方向键打开上下文菜单。
/// 不绘制替代 Dock，不移动鼠标，不改变 Dock 的位置、自动隐藏或固定 App 设置。
@MainActor
final class DockNavigationController {
    /// 其他全局键盘监听可排除本控制器定向发送给 Dock 的事件。
    nonisolated static let syntheticEventTag: Int64 = 0x4D6952446F636B
    weak var engine: MappingEngine?
    var onActiveChanged: ((Bool) -> Void)?
    var onUnavailable: ((String) -> Void)?
    var onSelectionChanged: ((String) -> Void)?
    var isActive: Bool { lease.isActive }

    private var lease = DockNavigationLogic.Lease()
    private var pendingOpenCleanup = DockNavigationLogic.PendingOpenCleanup()
    private var focusWatch = DockNavigationLogic.FocusWatch()
    private var dock: AXUIElement?
    private var dockPID: pid_t = 0
    private var selection: AXUIElement? {
        didSet {
            if let selection, let name = DockAX.title(selection) { onSelectionChanged?(name) }
        }
    }
    private var ready = false
    private var focusRequested = false
    private var moving = false
    private var openedAt: TimeInterval = 0
    private var lastActivity: TimeInterval = 0
    private var initialFrontPID: pid_t?
    private var initialFrontURL: URL?
    private var repeatKey: RemoteKey?
    private var repeatTimer: Timer?
    private var lifecycleTimer: Timer?
    private var escMonitor: Any?
    private var localEscMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []

    func toggle() { isActive ? close() : open() }

    func open() {
        guard !isActive else { return }
        guard let engine, !engine.isSuspended else {
            unavailableBeforeOpening("遥控器当前不可用，未打开程序坞选择。")
            return
        }
        guard AXIsProcessTrusted() else {
            unavailableBeforeOpening("需要辅助功能权限才能选择程序坞中的应用。")
            return
        }
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first(where: { !$0.isTerminated }) else {
            unavailableBeforeOpening("系统程序坞当前不可用。")
            return
        }
        // 旧会话取消后迟到的 Ctrl+F3 清理不能关闭这次新进入的 Dock 选择。
        pendingOpenCleanup.cancel()
        focusWatch.reset()
        dockPID = running.processIdentifier
        let dock = AXUIElementCreateApplication(dockPID)
        AXUIElementSetMessagingTimeout(dock, 0.04)
        self.dock = dock
        initialFrontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        initialFrontURL = NSWorkspace.shared.frontmostApplication?.bundleURL
        openedAt = ProcessInfo.processInfo.systemUptime
        lastActivity = openedAt
        ready = false
        focusRequested = false
        moving = false
        selection = nil
        let ticket = lease.begin()
        engine.setOverlayCapture({ [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.lease.accepts(ticket) else { return }
                self.handle(event)
            }
        }, immediateDirections: true)
        installLifecycleObservers(ticket: ticket)
        onActiveChanged?(true)
        guard lease.accepts(ticket) else { return }
        // 公开系统快捷键会唤出自动隐藏的真实 Dock，并进入其原生键盘选择状态。
        focusRequested = true
        WorkspaceActions.perform(.focusDock)
        later(0.10, ticket: ticket) { $0.finishOpening(attempt: 0, ticket: ticket) }
    }

    /// 取消时只向已确认聚焦的 Dock 进程发送 Escape，绝不把 Escape 送进新激活的 App。
    /// 选中 App 并执行 AXPress/Return 后必须使用 restoreFocus=false。
    func close(restoreFocus: Bool = true) {
        guard isActive else { return }
        let closingDock = dock
        let wasOpening = !ready && focusRequested
        let cancelDock = restoreFocus && dock.map { root in
            DockAX.hasKeyboardFocus(in: root, pid: dockPID, selection: selection)
        } == true
        let closingPID = dockPID
        lease.cancel()
        ready = false
        focusRequested = false
        moving = false
        focusWatch.reset()
        stopRepeat()
        lifecycleTimer?.invalidate()
        lifecycleTimer = nil
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        if let localEscMonitor { NSEvent.removeMonitor(localEscMonitor) }
        escMonitor = nil
        localEscMonitor = nil
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
        workspaceObservers.removeAll()
        engine?.setOverlayCapture(nil)
        dock = nil
        selection = nil
        initialFrontPID = nil
        initialFrontURL = nil
        if cancelDock { _ = DockAX.postKey(53, to: closingPID) }
        if restoreFocus, wasOpening, !cancelDock, let closingDock {
            // 系统快捷键的焦点切换可能晚于 Back/全局取消。短期内仅清理原 Dock PID；
            // 不重新占用遥控捕获，且新会话开始会使这个独立清理代次立即失效。
            let cleanupTicket = pendingOpenCleanup.begin(now: ProcessInfo.processInfo.systemUptime)
            schedulePendingOpenCleanup(dock: closingDock, pid: closingPID, ticket: cleanupTicket)
        }
        onActiveChanged?(false)
    }

    /// 设备移除、暂停、逃生和外部模式切换均可调用；后续异步选择会因代次变化失效。
    func cancel() { close() }

    /// 无 AX/CG 副作用，可由 App 的 self-test 在任意线程调用。
    nonisolated static func selfCheck() -> Bool { DockNavigationLogic.selfCheck() }

    private func handle(_ event: ButtonEvent) {
        guard isActive else { return }
        lastActivity = ProcessInfo.processInfo.systemUptime
        if !event.isDown {
            if repeatKey == event.key { stopRepeat() }
            return
        }
        switch event.key {
        case .back, .menu: close()
        case .ok: confirm()
        case .up, .down, .left, .right:
            guard repeatKey != event.key else { return }
            move(event.key)
            startRepeat(event.key)
        default: break // 全局保留手势已经由 MappingEngine 在捕获之前决断。
        }
    }

    private func finishOpening(attempt: Int, ticket: UInt64) {
        guard let dock, let snapshot = DockAX.snapshot(in: dock) else {
            retryOpening(attempt: attempt, ticket: ticket)
            return
        }
        if let selected = DockAX.selectedApplication(in: dock, pid: dockPID, snapshot: snapshot) {
            selection = selected
            ready = true
            return
        }
        guard DockAX.hasKeyboardFocus(in: dock, pid: dockPID, selection: nil, lists: snapshot.lists) else {
            retryOpening(attempt: attempt, ticket: ticket)
            return
        }
        let initial = snapshot.applications.first { item in
            guard let initialFrontURL, let url = DockAX.url(item) else { return false }
            return url.standardizedFileURL == initialFrontURL.standardizedFileURL
        } ?? snapshot.applications[0]
        if DockAX.select(initial, in: dock, pid: dockPID, snapshot: snapshot) {
            // Dock 的 AXList 持有焦点，图标通过 AXSelected 表示选中；两者分别确认。
            later(0.04, ticket: ticket) { controller in
                guard let dock = controller.dock else { return }
                if DockAX.isSelected(initial, in: dock, pid: controller.dockPID) {
                    controller.selection = initial
                    controller.ready = true
                } else {
                    controller.retryOpening(attempt: attempt, ticket: ticket)
                }
            }
        } else {
            // 初始焦点可能落在垃圾桶/文件夹；沿原生轴移动，只停在 App 图标。
            moving = true
            seek(initial, direction: 1, snapshot: snapshot,
                 remaining: snapshot.itemCount + 1, ticket: ticket, opening: true)
        }
    }

    private func retryOpening(attempt: Int, ticket: UInt64) {
        guard attempt < 8 else {
            fail("未能进入系统程序坞选择，请检查“将焦点移到程序坞”的键盘快捷键。")
            return
        }
        later(0.08, ticket: ticket) { $0.finishOpening(attempt: attempt + 1, ticket: ticket) }
    }

    private func move(_ key: RemoteKey) {
        guard ready, !moving, let dock,
              let snapshot = DockAX.snapshot(in: dock),
              let current = DockAX.selectedApplication(in: dock, pid: dockPID, snapshot: snapshot),
              let index = snapshot.applications.firstIndex(where: { CFEqual($0, current) }) else {
            if ready && !moving { fail("系统程序坞中的可选应用已改变，请重新打开选择。") }
            return
        }
        let direction = DockNavigationLogic.direction(for: key)
        guard direction != 0 else { return }
        let next = DockNavigationLogic.nextIndex(index, direction: direction, count: snapshot.applications.count)
        let target = snapshot.applications[next]
        guard !CFEqual(target, current) else { return }
        let ticket = lease.generation
        moving = true
        if DockAX.select(target, in: dock, pid: dockPID, snapshot: snapshot) {
            later(0.035, ticket: ticket) { controller in
                guard let dock = controller.dock else { return }
                if DockAX.isSelected(target, in: dock, pid: controller.dockPID) {
                    controller.selection = target
                    controller.moving = false
                } else {
                    controller.seek(target, direction: direction, snapshot: snapshot,
                                    remaining: snapshot.itemCount + 1, ticket: ticket)
                }
            }
        } else {
            seek(target, direction: direction, snapshot: snapshot,
                 remaining: snapshot.itemCount + 1, ticket: ticket)
        }
    }

    /// AXSelected 不可写时，向 Dock 进程投递沿其布局轴的箭头，并逐步读取真实选中态。
    /// 非 App 图标会被跳过；有界扫描失败立即释放捕获，不猜测已选中的 App。
    private func seek(_ target: AXUIElement, direction: Int, snapshot: DockAX.Snapshot,
                      remaining: Int, ticket: UInt64, opening: Bool = false) {
        guard lease.accepts(ticket), let dock else { return }
        if DockAX.isSelected(target, in: dock, pid: dockPID) {
            selection = target
            moving = false
            if opening { ready = true }
            return
        }
        guard remaining > 0,
              DockAX.hasKeyboardFocus(in: dock, pid: dockPID, selection: nil, lists: snapshot.lists),
              DockAX.postKey(DockNavigationLogic.nativeArrow(direction: direction,
                                                         orientation: snapshot.orientation), to: dockPID) else {
            fail("系统程序坞未能移动到所选应用，已退出选择。")
            return
        }
        later(0.06, ticket: ticket) {
            $0.seek(target, direction: direction, snapshot: snapshot,
                    remaining: remaining - 1, ticket: ticket, opening: opening)
        }
    }

    private func confirm() {
        guard ready, !moving, let dock,
              let snapshot = DockAX.snapshot(in: dock),
              let target = DockAX.selectedApplication(in: dock, pid: dockPID, snapshot: snapshot) else {
            return
        }
        // AXPress 是单击语义；不发送 Space、向内箭头或 AXShowMenu，避免打开上下文菜单。
        if DockAX.actions(target).contains(kAXPressAction as String),
           AXUIElementPerformAction(target, kAXPressAction as CFString) == .success {
            close(restoreFocus: false)
        } else if DockAX.isSelected(target, in: dock, pid: dockPID), DockAX.postKey(36, to: dockPID) {
            close(restoreFocus: false)
        } else {
            fail("系统程序坞未能打开所选应用，已退出选择。")
        }
    }

    private func startRepeat(_ key: RemoteKey) {
        stopRepeat()
        repeatKey = key
        let timer = Timer(timeInterval: 0.13, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive, self.repeatKey == key else { return }
                self.move(key)
            }
        }
        timer.fireDate = Date().addingTimeInterval(0.4)
        repeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        repeatKey = nil
    }

    private func installLifecycleObservers(ticket: UInt64) {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification,
                                                      object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.lease.accepts(ticket) else { return }
                self.close(restoreFocus: false)
            }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                      object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.lease.accepts(ticket), self.ready,
                      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier != self.dockPID else { return }
                self.close(restoreFocus: false)
            }
        })
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53,
                  event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Self.syntheticEventTag,
                  event.cgEvent?.getIntegerValueField(.eventSourceUserData) != AppNavigationAccessibility.syntheticEventTag else { return }
            // 真键盘 Escape 已由系统收到；只清理捕获，避免再投递一份。
            MainActor.assumeIsolated {
                guard let self, self.lease.accepts(ticket) else { return }
                self.close(restoreFocus: false)
            }
        }
        localEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53,
               event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Self.syntheticEventTag,
               event.cgEvent?.getIntegerValueField(.eventSourceUserData) != AppNavigationAccessibility.syntheticEventTag {
                MainActor.assumeIsolated {
                    guard let self, self.lease.accepts(ticket) else { return }
                    self.close(restoreFocus: false)
                }
            }
            return event
        }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkLifecycle() }
        }
        lifecycleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func checkLifecycle() {
        guard isActive else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard let engine, !engine.isSuspended else { close(); return }
        // setOverlayCapture 在引擎队列异步生效，打开的最初 0.5s 不把旧快照当作捕获丢失。
        if now - openedAt > 0.5, !engine.tapRoute.uiCapture { close(); return }
        if now - lastActivity >= DockNavigationLogic.idleSeconds { close(); return }
        guard let app = NSRunningApplication(processIdentifier: dockPID), !app.isTerminated else {
            close(restoreFocus: false)
            return
        }
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           front != dockPID, front != initialFrontPID {
            close(restoreFocus: false)
            return
        }
        if ready, let dock,
           focusWatch.shouldClose(hasFocus: DockAX.hasKeyboardFocus(in: dock, pid: dockPID,
                                                                   selection: selection), now: now) {
            // 点击原 App 或原生 Return 选回原 App 时前台 PID 不变，也可能没有激活通知。
            // 焦点连续消失超过一个短暂容错窗口就释放捕获，不再等待 15s 闲置期限。
            close(restoreFocus: false)
        }
    }

    private func schedulePendingOpenCleanup(dock: AXUIElement, pid: pid_t, ticket: UInt64) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, !self.isActive,
                  self.pendingOpenCleanup.accepts(ticket, now: ProcessInfo.processInfo.systemUptime),
                  let app = NSRunningApplication(processIdentifier: pid),
                  !app.isTerminated, app.bundleIdentifier == "com.apple.dock" else { return }
            if DockAX.hasKeyboardFocus(in: dock, pid: pid, selection: nil) {
                guard self.pendingOpenCleanup.accepts(ticket, now: ProcessInfo.processInfo.systemUptime) else {
                    return
                }
                self.pendingOpenCleanup.cancel()
                _ = DockAX.postKey(53, to: pid)
            } else {
                self.schedulePendingOpenCleanup(dock: dock, pid: pid, ticket: ticket)
            }
        }
    }

    private func later(_ delay: TimeInterval, ticket: UInt64,
                       _ work: @escaping @MainActor (DockNavigationController) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.lease.accepts(ticket) else { return }
            work(self)
        }
    }

    private func fail(_ message: String) {
        close()
        reportUnavailable(message)
    }

    private func unavailableBeforeOpening(_ message: String) {
        // MappingEngine 的全局 overlay 路由会先装一个吞键占位 handler，失败也必须释放它。
        engine?.setOverlayCapture(nil)
        reportUnavailable(message)
    }

    private func reportUnavailable(_ message: String) {
        if let onUnavailable { onUnavailable(message) } else { log(message) }
    }
}

/// 不依赖系统 UI 的键向、边界与取消代次逻辑。
enum DockNavigationLogic {
    enum Orientation: String { case bottom, left, right }
    static let idleSeconds: TimeInterval = 15

    struct Lease {
        private(set) var isActive = false
        private(set) var generation: UInt64 = 0
        mutating func begin() -> UInt64 {
            generation &+= 1
            isActive = true
            return generation
        }
        mutating func cancel() { isActive = false; generation &+= 1 }
        func accepts(_ ticket: UInt64) -> Bool { isActive && generation == ticket }
    }

    /// 不延长已取消会话的捕获，仅允许在取消后的短窗口内清理由其发起的迟到焦点。
    struct PendingOpenCleanup {
        static let lifetime: TimeInterval = 0.8
        private var lease = Lease()
        private var deadline: TimeInterval = 0
        mutating func begin(now: TimeInterval) -> UInt64 {
            deadline = now + Self.lifetime
            return lease.begin()
        }
        mutating func cancel() { lease.cancel() }
        func accepts(_ ticket: UInt64, now: TimeInterval) -> Bool {
            lease.accepts(ticket) && now <= deadline
        }
    }

    struct FocusWatch {
        private var missingSince: TimeInterval?
        mutating func reset() { missingSince = nil }
        mutating func shouldClose(hasFocus: Bool, now: TimeInterval) -> Bool {
            if hasFocus { reset(); return false }
            guard let missingSince else { self.missingSince = now; return false }
            return now - missingSince >= 0.2
        }
    }

    static func direction(for key: RemoteKey) -> Int {
        switch key {
        case .left, .up: -1
        case .right, .down: 1
        default: 0
        }
    }

    static func nextIndex(_ index: Int, direction: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let bounded = min(max(index, 0), count - 1)
        if direction < 0 { return bounded == 0 ? count - 1 : bounded - 1 }
        if direction > 0 { return bounded == count - 1 ? 0 : bounded + 1 }
        return bounded
    }

    static func nativeArrow(direction: Int, orientation: Orientation) -> CGKeyCode {
        orientation == .bottom ? (direction < 0 ? 123 : 124) : (direction < 0 ? 126 : 125)
    }

    /// App 图标的 AXSelected 为主，列表选中子项补充；两个非空来源冲突时不猜测。
    static func selectedIndex(itemSelected: [Bool?], selectedChildren: [Int]?) -> Int? {
        let selected = itemSelected.indices.filter { itemSelected[$0] == true }
        let children = Array(Set((selectedChildren ?? []).filter { itemSelected.indices.contains($0) }))
        guard selected.count <= 1, children.count <= 1 else { return nil }
        if let item = selected.first {
            return children.isEmpty || children[0] == item ? item : nil
        }
        return children.first
    }

    static func selfCheck() -> Bool {
        let expectations: [(Orientation, CGKeyCode, CGKeyCode)] = [
            (.bottom, 123, 124), (.left, 126, 125), (.right, 126, 125)
        ]
        for (orientation, previousKey, nextKey) in expectations {
            for key in [RemoteKey.left, .right, .up, .down] {
                let delta = direction(for: key)
                guard delta != 0,
                      nextIndex(1, direction: delta, count: 3) == (delta < 0 ? 0 : 2),
                      nativeArrow(direction: delta, orientation: orientation)
                        == (delta < 0 ? previousKey : nextKey) else {
                    return false
                }
            }
        }
        guard nextIndex(0, direction: -1, count: 3) == 2,
              nextIndex(2, direction: 1, count: 3) == 0,
              nextIndex(0, direction: -1, count: 1) == 0,
              nextIndex(4, direction: 1, count: 0) == 0,
              nextIndex(Int.max - 1, direction: 1, count: Int.max) == 0,
              nextIndex(-1, direction: -1, count: 3) == 2,
              direction(for: .ok) == 0,
              selectedIndex(itemSelected: [nil, nil, nil], selectedChildren: [1]) == 1,
              selectedIndex(itemSelected: [true, false], selectedChildren: []) == 0,
              selectedIndex(itemSelected: [true, false], selectedChildren: [1]) == nil,
              selectedIndex(itemSelected: [false, true], selectedChildren: nil) == 1,
              selectedIndex(itemSelected: [true, true], selectedChildren: nil) == nil,
              selectedIndex(itemSelected: [nil, nil], selectedChildren: [0, 1]) == nil,
              idleSeconds >= 10 && idleSeconds <= 20 else { return false }
        var lease = Lease()
        let first = lease.begin()
        guard lease.accepts(first) else { return false }
        lease.cancel()
        guard !lease.isActive, !lease.accepts(first) else { return false }
        let second = lease.begin()
        guard lease.accepts(second), !lease.accepts(first) else { return false }
        lease.cancel()
        guard !lease.accepts(second) else { return false }

        var cleanup = PendingOpenCleanup()
        let oldCleanup = cleanup.begin(now: 10)
        guard cleanup.accepts(oldCleanup, now: 10.4),
              !cleanup.accepts(oldCleanup, now: 10.9) else { return false }
        cleanup.cancel() // 新 Dock 会话开始，旧清理即使尚未超时也不能发送 Escape。
        guard !cleanup.accepts(oldCleanup, now: 10.5) else { return false }
        let newCleanup = cleanup.begin(now: 10.5)
        guard cleanup.accepts(newCleanup, now: 10.6),
              !cleanup.accepts(oldCleanup, now: 10.6) else { return false }

        var focus = FocusWatch()
        guard !focus.shouldClose(hasFocus: false, now: 0),
              !focus.shouldClose(hasFocus: false, now: 0.1),
              !focus.shouldClose(hasFocus: true, now: 0.15),
              !focus.shouldClose(hasFocus: false, now: 0.3),
              focus.shouldClose(hasFocus: false, now: 0.55) else { return false }
        focus.reset()
        return !focus.shouldClose(hasFocus: false, now: 1)
    }
}

/// 只查询 com.apple.dock 的公开 AX 属性；不遍历其他 App 的控件树。
@MainActor
private enum DockAX {
    struct Snapshot {
        let items: [AXUIElement]
        let applications: [AXUIElement]
        let lists: [AXUIElement]
        let itemCount: Int
        let orientation: DockNavigationLogic.Orientation
    }

    static func snapshot(in root: AXUIElement) -> Snapshot? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var head = 0
        var visited: [AXUIElement] = []
        var items: [AXUIElement] = []
        var applications: [AXUIElement] = []
        var lists: [AXUIElement] = []
        var itemCount = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 0.35
        while head < queue.count, head < 256, ProcessInfo.processInfo.systemUptime < deadline {
            let (current, depth) = queue[head]
            head += 1
            guard !visited.contains(where: { CFEqual($0, current) }) else { continue }
            visited.append(current)
            let role = string(current, kAXRoleAttribute)
            if role == kAXListRole as String { lists.append(current) }
            if role == kAXDockItemRole as String {
                items.append(current)
                itemCount += 1
                if string(current, kAXSubroleAttribute) == kAXApplicationDockItemSubrole as String,
                   bool(current, kAXEnabledAttribute) != false {
                    applications.append(current)
                }
            } else if depth < 4 {
                queue.append(contentsOf: children(current).prefix(128).map { ($0, depth + 1) })
            }
        }
        guard head == queue.count, !applications.isEmpty else { return nil }
        let preference = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom"
        let orientation = DockNavigationLogic.Orientation(rawValue: preference) ?? .bottom
        // AXPosition 使用屏幕左上角坐标；左/右 Dock 均从上往下，底部从左往右。
        // 某些自动隐藏状态暂不提供坐标，此时保留 AXChildren 的原生顺序。
        let positioned = applications.compactMap { element -> (AXUIElement, CGPoint)? in
            guard let point = position(element) else { return nil }
            return (element, point)
        }
        if positioned.count == applications.count {
            applications = positioned.sorted {
                orientation == .bottom ? $0.1.x < $1.1.x : $0.1.y < $1.1.y
            }.map(\.0)
        }
        return Snapshot(items: items, applications: applications, lists: lists,
                        itemCount: max(itemCount, applications.count),
                        orientation: orientation)
    }

    static func hasKeyboardFocus(in root: AXUIElement, pid: pid_t, selection: AXUIElement?,
                                 lists knownLists: [AXUIElement]? = nil) -> Bool {
        if focusedElement(in: root, pid: pid) != nil { return true }
        if let selection, let list = owningList(of: selection, pid: pid),
           bool(list, kAXFocusedAttribute) == true { return true }
        let lists = knownLists ?? snapshot(in: root)?.lists ?? []
        // AXSelected 可能在退出键盘导航后保留，因此绝不用它证明 Dock 仍持有键盘焦点。
        return lists.contains { bool($0, kAXFocusedAttribute) == true }
    }

    static func selectedApplication(in root: AXUIElement, pid: pid_t,
                                    snapshot: Snapshot) -> AXUIElement? {
        let focusedLists = snapshot.lists.filter { bool($0, kAXFocusedAttribute) == true }
        guard !focusedLists.isEmpty || focusedElement(in: root, pid: pid) != nil else { return nil }
        let lists = focusedLists.isEmpty ? snapshot.lists : focusedLists
        let selections = lists.compactMap { selectedChildren(of: $0) }
        let childIndices: [Int]? = selections.isEmpty ? nil : selections.flatMap { children in
            children.compactMap { child in
                snapshot.applications.firstIndex { CFEqual($0, child) }
            }
        }
        let flags: [Bool?] = snapshot.applications.map { item in
            let selected = bool(item, kAXSelectedAttribute)
            if selected == true, !focusedLists.isEmpty {
                guard let list = owningList(of: item, pid: pid),
                      focusedLists.contains(where: { CFEqual($0, list) }) else { return false }
            }
            return selected
        }
        guard let index = DockNavigationLogic.selectedIndex(itemSelected: flags,
                                                           selectedChildren: childIndices) else { return nil }
        return snapshot.applications[index]
    }

    static func focusedElement(in root: AXUIElement, pid: pid_t) -> AXUIElement? {
        if let value = attribute(root, kAXFocusedUIElementAttribute),
           CFGetTypeID(value) == AXUIElementGetTypeID() {
            let focused = unsafeBitCast(value, to: AXUIElement.self)
            var owner: pid_t = 0
            if AXUIElementGetPid(focused, &owner) == .success, owner == pid,
               bool(focused, kAXFocusedAttribute) == true { return focused }
        }
        return bool(root, kAXFocusedAttribute) == true ? root : nil
    }

    static func isSelected(_ item: AXUIElement, in root: AXUIElement, pid: pid_t) -> Bool {
        guard hasKeyboardFocus(in: root, pid: pid, selection: item) else { return false }
        if let list = owningList(of: item, pid: pid), let selected = selectedChildren(of: list), !selected.isEmpty {
            return selected.count == 1 && CFEqual(selected[0], item)
        }
        return bool(item, kAXSelectedAttribute) == true
    }

    static func select(_ item: AXUIElement, in root: AXUIElement, pid: pid_t, snapshot: Snapshot) -> Bool {
        guard hasKeyboardFocus(in: root, pid: pid, selection: item, lists: snapshot.lists) else { return false }
        if settable(item, kAXSelectedAttribute),
           AXUIElementSetAttributeValue(item, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success {
            return true
        }
        guard let list = owningList(of: item, pid: pid), settable(list, kAXSelectedChildrenAttribute) else {
            return false
        }
        return AXUIElementSetAttributeValue(list, kAXSelectedChildrenAttribute as CFString,
                                           [item] as CFArray) == .success
    }

    private static func settable(_ item: AXUIElement, _ name: String) -> Bool {
        AXUIElementSetMessagingTimeout(item, 0.04)
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(item, name as CFString, &settable) == .success && settable.boolValue
    }

    private static func selectedChildren(of list: AXUIElement) -> [AXUIElement]? {
        attribute(list, kAXSelectedChildrenAttribute) as? [AXUIElement]
    }

    private static func owningList(of item: AXUIElement, pid: pid_t) -> AXUIElement? {
        var ancestor = item
        for _ in 0..<5 {
            guard let value = attribute(ancestor, kAXParentAttribute),
                  CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            let parent = unsafeBitCast(value, to: AXUIElement.self)
            var owner: pid_t = 0
            guard AXUIElementGetPid(parent, &owner) == .success, owner == pid else { return nil }
            if string(parent, kAXRoleAttribute) == kAXListRole as String { return parent }
            ancestor = parent
        }
        return nil
    }

    static func actions(_ item: AXUIElement) -> [String] {
        var value: CFArray?
        guard AXUIElementCopyActionNames(item, &value) == .success else { return [] }
        return value as? [String] ?? []
    }

    static func title(_ item: AXUIElement) -> String? { string(item, kAXTitleAttribute) }

    static func url(_ item: AXUIElement) -> URL? {
        if let value = attribute(item, kAXURLAttribute) as? URL { return value }
        if let value = attribute(item, kAXURLAttribute) as? String { return URL(string: value) }
        return nil
    }

    /// 目标 PID 固定为打开时找到的 Dock；取消/确认都不会向前台新 App 投递按键。
    static func postKey(_ code: CGKeyCode, to pid: pid_t) -> Bool {
        guard pid > 0, let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return false }
        for event in [down, up] {
            event.flags = event.flags.intersection([.maskSecondaryFn, .maskNumericPad])
            event.setIntegerValueField(.eventSourceUserData, value: DockNavigationController.syntheticEventTag)
            event.postToPid(pid)
        }
        return true
    }

    private static func attribute(_ item: AXUIElement, _ name: String) -> CFTypeRef? {
        // 超时是逐 AX 元素设置的；子元素不继承根对象的消息等待上限。
        AXUIElementSetMessagingTimeout(item, 0.04)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func string(_ item: AXUIElement, _ name: String) -> String? {
        attribute(item, name) as? String
    }

    private static func bool(_ item: AXUIElement, _ name: String) -> Bool? {
        attribute(item, name) as? Bool
    }

    private static func children(_ item: AXUIElement) -> [AXUIElement] {
        attribute(item, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func position(_ item: AXUIElement) -> CGPoint? {
        guard let value = attribute(item, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let ax = unsafeBitCast(value, to: AXValue.self)
        var point = CGPoint.zero
        return AXValueGetValue(ax, .cgPoint, &point) ? point : nil
    }
}
