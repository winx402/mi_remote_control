import AppKit
import CoreGraphics

/// Pure selection state, deliberately separate from workspace/AX/event APIs for self-test.
struct AppNavigationSelectionState {
    var selectedID: Int?
    var regionID: String?
    var windowID: UInt64?
    var editing = false

    mutating func receive(_ snapshot: AppNavigationAccessibility.Snapshot) {
        if windowID != snapshot.windowID {
            reset()
            windowID = snapshot.windowID
        }
        if let selectedID, !snapshot.nodes.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
    }

    mutating func reset() { self = Self() }

    static func selfCheck() -> Bool {
        var state = Self()
        let node = AppNavigationNode(id: 7, label: "按钮", role: "AXButton",
                                     frame: CGRect(x: 10, y: 10, width: 30, height: 30), kind: .button)
        state.receive(.init(windowID: 1, frame: node.frame, nodes: [node], limited: false))
        state.selectedID = 7
        state.regionID = "content"
        state.editing = true
        state.receive(.init(windowID: 1, frame: node.frame, nodes: [], limited: false))
        guard state.selectedID == nil, state.regionID == "content" else { return false }
        state.receive(.init(windowID: 2, frame: node.frame, nodes: [node], limited: false))
        guard !state.editing, state.regionID == nil, state.windowID == 2 else { return false }
        state.selectedID = 7
        state.reset()
        return state.selectedID == nil && state.windowID == nil && !state.editing
    }
}

/// Owns an application navigation session, but never installs an engine capture itself.
/// The caller retains priority for menus, Dock, global gestures, and suspension.
@MainActor
final class ApplicationNavigationController {
    var onCaptureChanged: ((Bool) -> Void)?
    var onStatusChanged: ((String) -> Void)?
    private(set) var isEnabled = false
    var navigationMode: AppNavigationMode { context?.profile.mode ?? .native }
    var isEditing: Bool { selection.editing }

    private struct Context: Equatable {
        let pid: pid_t
        let bundleID: String
        let profile: AppNavigationProfile
        let windowNumber: Int?
    }

    private let accessibility = AppNavigationAccessibility()
    private let overlay = NavigationFocusOverlay()
    private var profiles: [String: AppNavigationProfile] = [:]
    private var context: Context?
    private var session: AppNavigationAccessibility.Session?
    private var selection = AppNavigationSelectionState()
    private var snapshot: AppNavigationAccessibility.Snapshot?
    private var snapshotAt: TimeInterval = 0
    private var suspended = false
    private var stopped = false
    private var lastActivity: TimeInterval = 0
    private var status = ""
    private var heldDirection: RemoteKey?
    private var repeatTimer: Timer?
    private var lifecycleTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var retryTask: Task<Void, Never>?
    private static let idleSeconds: TimeInterval = 20

    func configure(_ profiles: [String: AppNavigationProfile]) {
        stopped = false
        installLifecycleObservers()
        if self.profiles != profiles {
            self.profiles = profiles
            resetSession()
            context = nil
        }
        refresh()
    }

    /// This reads only application/window metadata. It does not enumerate an AX tree.
    func refresh() {
        guard !stopped, !suspended,
              let app = NSWorkspace.shared.frontmostApplication, app.activationPolicy == .regular,
              !app.isTerminated, let bundleID = app.bundleIdentifier,
              let profile = profiles[bundleID], profile.mode != .native else {
            disable()
            return
        }
        let next = Context(pid: app.processIdentifier, bundleID: bundleID, profile: profile,
                           windowNumber: Self.frontWindowNumber(pid: app.processIdentifier))
        if context != next || session == nil {
            resetSession()
            context = next
            session = accessibility.start(pid: next.pid, bundleID: next.bundleID,
                                            screens: NavigationFocusOverlay.axScreenFrames)
            lastActivity = ProcessInfo.processInfo.systemUptime
            setStatus(profile.mode == .buttons ? "按钮导航 · 方向选择 · OK 确认" : "区域导航 · 左右切换区域")
        }
        setEnabled(true)
        if lastActivity > 0, heldDirection == nil,
           ProcessInfo.processInfo.systemUptime - lastActivity >= Self.idleSeconds {
            // Invisible old selections must never be activated by a later OK.
            selection.selectedID = nil
            selection.regionID = nil
            snapshot = nil
            snapshotAt = 0
            overlay.hide()
            lastActivity = 0
        }
    }

    func setSuspended(_ suspended: Bool) {
        guard self.suspended != suspended else { return }
        self.suspended = suspended
        if suspended { disable() } else { refresh() }
    }

    /// Only the caller's resolved directional, OK and short-Back events should arrive here.
    /// Direction key-down selects immediately; repeat is bounded and key-up cancels its timer.
    func handle(_ key: RemoteKey, isDown: Bool) {
        if !isDown {
            if heldDirection == key { stopRepeat() }
            return
        }
        refresh()
        guard isEnabled, [.up, .down, .left, .right, .ok, .back].contains(key) else { return }
        lastActivity = ProcessInfo.processInfo.systemUptime
        if key == .back {
            stopRepeat()
            invalidateSelection()
            setStatus("应用导航 · 方向选择 · OK 确认")
            submit(.native(.back, .escape, windowID: nil), retryWhenBusy: true) { [weak self] reply in
                self?.handleEffectReply(reply, originalKey: .back)
            }
            return
        }
        if Self.isDirection(key) {
            guard heldDirection != key else { return }
            stopRepeat()
            heldDirection = key
            process(key)
            startRepeat(key)
        } else {
            stopRepeat()
            process(key)
        }
    }

    /// Called only after the app's real FocusInput action succeeds, or successful AXFocused here.
    /// Native editing requests independently revalidate the actual focused, nonsecure text input.
    func enterEditing() {
        refresh()
        guard isEnabled else { return }
        // A scan begun before the focus action must not restore virtual selection
        // over the newly entered text-editing state.
        invalidateSelection()
        selection.editing = true
        snapshotAt = 0
        stopRepeat()
        lastActivity = ProcessInfo.processInfo.systemUptime
        setStatus("编辑中 · 方向移动光标 · OK 回车 · 返回退出")
        updateHighlight()
    }

    /// Global double gestures, modal overlays and external focus changes may invalidate selection.
    /// Cancellation does not emit Escape or any other key into the newly focused application.
    func invalidateSelection() {
        resetSession()
        if let context, isEnabled, !suspended, !stopped {
            session = accessibility.start(pid: context.pid, bundleID: context.bundleID,
                                            screens: NavigationFocusOverlay.axScreenFrames)
        }
    }

    func stop() {
        stopped = true
        disable()
        lifecycleTimer?.invalidate()
        lifecycleTimer = nil
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
        workspaceObservers.removeAll()
        overlay.stop()
    }

    private func process(_ key: RemoteKey) {
        guard isEnabled, context != nil else { return }
        if selection.editing {
            submit(.native(key, .editing, windowID: selection.windowID)) { [weak self] reply in
                self?.handleEffectReply(reply, editing: true, originalKey: key)
            }
            return
        }
        if key == .ok, let selectedID = selection.selectedID, let windowID = selection.windowID {
            snapshotAt = 0
            submit(.activate(nodeID: selectedID, windowID: windowID)) { [weak self] reply in
                guard let self else { return }
                switch reply {
                case .editing: enterEditing()
                case .performed:
                    invalidateSelection()
                    setStatus("已激活控件 · 方向键重新选择")
                case .cancelled:
                    selection.selectedID = nil
                    snapshot = nil
                    overlay.hide()
                    setStatus("控件或窗口已变化，请重新选择。")
                case .unavailable(let message): setStatus(message)
                case .menu: routeMenu(.ok)
                case .menuPerformed: clearForNativeMenu()
                case .staleSelection: clearStaleSelection()
                case .snapshot: break
                }
            }
            return
        }
        // The worker's short-lived snapshot cache avoids DOM rescans. Its lightweight focus
        // check still runs for every key so opening a native menu cannot leave arrows trapped.
        submit(.scan) { [weak self] reply in
            guard let self, let context = self.context else { return }
            switch reply {
            case .snapshot(let snapshot):
                self.snapshot = snapshot
                snapshotAt = ProcessInfo.processInfo.systemUptime
                selection.receive(snapshot)
                navigate(key, snapshot: snapshot, profile: context.profile)
            case .unavailable(let message):
                selection.selectedID = nil
                selection.regionID = nil
                self.snapshot = nil
                overlay.hide()
                setStatus(message)
                if Self.isDirection(key) { nativeFallback(key, windowID: nil) }
            case .cancelled:
                // Transient menu, focus and window changes are intentionally quiet.
                snapshotAt = 0
            case .menu: routeMenu(key)
            case .menuPerformed: clearForNativeMenu()
            case .staleSelection: clearStaleSelection()
            case .performed, .editing: break
            }
        }
    }

    private func navigate(_ key: RemoteKey, snapshot: AppNavigationAccessibility.Snapshot,
                          profile: AppNavigationProfile) {
        selection.receive(snapshot)
        switch profile.mode {
        case .native: return
        case .buttons:
            let controls = snapshot.nodes.filter { $0.kind == .button || $0.kind == .input }
            guard !controls.isEmpty else {
                selection.selectedID = nil
                overlay.hide()
                setStatus("当前界面没有暴露可操作控件，方向键使用原生行为。")
                if Self.isDirection(key) { nativeFallback(key, windowID: snapshot.windowID) }
                return
            }
            let direction = key == .ok ? RemoteKey.down : key
            selection.selectedID = AppNavigationGeometry.target(currentID: selection.selectedID,
                                                                  direction: direction, nodes: controls)
            selection.regionID = nil
            updateHighlight()
            setStatus(snapshot.limited ? "按钮导航 · 已显示可用控件，部分界面未暴露或超出查询预算" : "按钮导航 · OK 激活 · 返回取消")
        case .regions:
            let regions = AppNavigationGeometry.regions(nodes: snapshot.nodes, window: snapshot.frame,
                                                        layout: profile.layout)
            guard !regions.isEmpty else {
                overlay.hide()
                if Self.isDirection(key) { nativeFallback(key, windowID: snapshot.windowID) }
                return
            }
            if !regions.contains(where: { $0.id == selection.regionID }) {
                selection.regionID = regions.first?.id
                selection.selectedID = nil
            }
            if key == .left || key == .right {
                selection.regionID = AppNavigationGeometry.movedRegion(currentID: selection.regionID,
                    direction: key == .left ? -1 : 1, regions: regions)
                selection.selectedID = nil
                updateHighlight()
                return
            }
            guard let region = regions.first(where: { $0.id == selection.regionID }) else { return }
            let controls = snapshot.nodes.filter {
                region.nodeIDs.contains($0.id) && ($0.kind == .button || $0.kind == .input)
            }
            if key == .ok {
                // Enter is never a blind fallback: the first OK only selects an actual control.
                selection.selectedID = AppNavigationGeometry.target(currentID: nil, direction: .down, nodes: controls)
                updateHighlight()
                if selection.selectedID == nil { setStatus("此区域没有可激活控件 · 左右切换区域") }
                return
            }
            guard key == .up || key == .down else { return }
            switch region.vertical {
            case .buttons:
                selection.selectedID = AppNavigationGeometry.target(currentID: selection.selectedID,
                                                                      direction: key, nodes: controls)
                updateHighlight()
            case .scroll:
                selection.selectedID = nil
                updateHighlight()
                guard let scrollID = region.scrollNodeID else {
                    setStatus("此区域未提供辅助功能滚动操作。")
                    return
                }
                snapshotAt = 0
                submit(.scroll(nodeID: scrollID, windowID: snapshot.windowID, up: key == .up)) { [weak self] reply in
                    self?.handleEffectReply(reply, originalKey: key)
                }
            case .native:
                selection.selectedID = nil
                updateHighlight()
                snapshotAt = 0
                submit(.native(key, .videoRegion(region.id, profile.layout), windowID: snapshot.windowID)) { [weak self] reply in
                    self?.handleEffectReply(reply, originalKey: key)
                }
            }
        }
    }

    private func nativeFallback(_ key: RemoteKey, windowID: UInt64?) {
        submit(.native(key, .navigation, windowID: windowID)) { [weak self] reply in
            self?.handleEffectReply(reply, originalKey: key)
        }
    }

    private func routeMenu(_ key: RemoteKey) {
        clearForNativeMenu()
        submit(.native(key, .menu, windowID: nil)) { [weak self] reply in
            self?.handleEffectReply(reply)
        }
    }

    private func clearForNativeMenu() {
        selection.reset()
        snapshot = nil
        snapshotAt = 0
        overlay.hide()
        setStatus("原生菜单 · 方向选择 · OK 确认 · 返回关闭")
    }

    private func clearStaleSelection() {
        invalidateSelection()
        setStatus("窗口或控件位置已变化，请重新选择。")
    }

    private func handleEffectReply(_ reply: AppNavigationAccessibility.Reply, editing: Bool = false,
                                   originalKey: RemoteKey? = nil) {
        switch reply {
        case .unavailable(let message): setStatus(message)
        case .menu:
            if let originalKey { routeMenu(originalKey) }
        case .menuPerformed: clearForNativeMenu()
        case .staleSelection: clearStaleSelection()
        case .cancelled:
            if editing {
                selection.editing = false
                selection.selectedID = nil
                snapshot = nil
                overlay.hide()
                setStatus("输入焦点已离开 · 方向键重新选择")
            }
        case .editing: enterEditing()
        case .performed, .snapshot: break
        }
    }

    private func submit(_ request: AppNavigationAccessibility.Request, retryWhenBusy: Bool = false,
                        completion: @escaping @MainActor @Sendable (AppNavigationAccessibility.Reply) -> Void) {
        guard let session, isEnabled else { return }
        let receive: @MainActor @Sendable (AppNavigationAccessibility.Reply) -> Void = { [weak self] reply in
            guard let self, isEnabled, self.session == session else { return }
            // A workspace switch may precede delivery of its notification. Recheck metadata first.
            refresh()
            guard self.session == session else { return }
            completion(reply)
        }
        if accessibility.request(request, session: session, completion: receive) { return }
        guard retryWhenBusy else { return }
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled, let self, self.isEnabled, self.session == session else { return }
                if self.accessibility.request(request, session: session, completion: receive) { return }
            }
        }
    }

    private func updateHighlight() {
        guard let snapshot else { overlay.hide(); return }
        let node = snapshot.nodes.first { $0.id == selection.selectedID }
        let region: AppNavigationRegion?
        if let context, context.profile.mode == .regions {
            region = AppNavigationGeometry.regions(nodes: snapshot.nodes, window: snapshot.frame,
                layout: context.profile.layout).first { $0.id == selection.regionID }
        } else { region = nil }
        overlay.show(node: node, region: region, editing: selection.editing)
    }

    private func startRepeat(_ key: RemoteKey) {
        guard heldDirection == key else { return }
        let timer = Timer(timeInterval: 0.14, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.heldDirection == key else { return }
                self.refresh()
                guard self.isEnabled, self.heldDirection == key else { return }
                self.lastActivity = ProcessInfo.processInfo.systemUptime
                self.process(key)
            }
        }
        timer.fireDate = Date(timeIntervalSinceNow: 0.36)
        repeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        heldDirection = nil
    }

    private func resetSession() {
        accessibility.cancel()
        session = nil
        retryTask?.cancel()
        retryTask = nil
        stopRepeat()
        selection.reset()
        snapshot = nil
        snapshotAt = 0
        overlay.hide()
    }

    private func disable() {
        if context != nil || session != nil { resetSession() }
        context = nil
        setEnabled(false)
        setStatus("")
    }

    private func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        onCaptureChanged?(enabled)
    }

    private func setStatus(_ value: String) {
        guard status != value else { return }
        status = value
        onStatusChanged?(value)
    }

    private func installLifecycleObservers() {
        guard lifecycleTimer == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    // Even switching away and immediately back invalidates the old session.
                    self.resetSession()
                    self.context = nil
                    self.refresh()
                }
            })
        }
        let timer = Timer(timeInterval: 0.65, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        lifecycleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func frontWindowNumber(pid: pid_t) -> Int? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                      kCGNullWindowID) as? [[String: Any]] else { return nil }
        // Do not inspect window names or contents. Order is the window server's front-to-back order.
        return windows.first(where: {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
                && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
                && (($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0) > 0
        }).flatMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue }
    }

    private static func isDirection(_ key: RemoteKey) -> Bool {
        [.up, .down, .left, .right].contains(key)
    }

    /// Safe for --self-test: no controller instance, timer, workspace, AX query or event is created.
    nonisolated static func selfCheck() -> Bool {
        AppNavigationAccessibility.selfCheck() && AppNavigationSelectionState.selfCheck()
            && NavigationFocusOverlay.selfCheck()
    }
}
