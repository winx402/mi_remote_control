import AppKit
import ApplicationServices

/// Uses only the installed application's own Sparkle UI. Installation and relaunch
/// always require an explicit remote OK on the currently highlighted native control.
@MainActor enum CodexAppUpdate {
    private static let bundleID = "com.openai.codex"
    private static var running = false
    static var onDialogActiveChanged: ((Bool) -> Void)?
    private static var dialogActive = false
    private static var monitor: Timer?
    private static let highlight = NavigationFocusOverlay()
    private static var selectedWindow: AXUIElement?
    private static var shownFrame: CGRect?
    private static var selectedControl: AXUIElement?
    private static var cachedLabels: (URL, Labels)?

    static func run() async -> String? {
        guard !running else { return "Codex 正在检查更新，请等待原生窗口。" }
        guard AXIsProcessTrusted() else { return "需要辅助功能权限，才能操作 Codex 原生更新。" }
        guard let app = installedApplication() else {
            return "请先打开已安装的 Codex；未找到它的原生 Sparkle 更新器。"
        }
        running = true
        defer { running = false }
        app.activate()
        for _ in 0..<15 {
            if isFrontmost(app.processIdentifier) { break }
            try? await Task.sleep(for: .milliseconds(40))
        }
        guard !Task.isCancelled, isFrontmost(app.processIdentifier) else {
            return "无法将 Codex 切到前台，请重试。"
        }
        if refreshRemoteSelection() { return nil }
        let initial = focusedSnapshot(in: app)
        guard !initial.blocked else { return "Codex 有其他原生对话框，请先处理后重试更新。" }
        guard !initial.incomplete else { return "无法完整读取 Codex 原生更新窗口，请在 Codex 内检查更新。" }
        // A download/status window may have no enabled buttons for a short time.
        if !initial.updater {
            guard let menu = resolveMenu(in: app), press(menu) else {
                return "未找到可用的 Codex「检查更新」菜单，请在应用内检查更新。"
            }
        }
        let started = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - started < 45 {
            guard !Task.isCancelled else { return "已停止等待；Codex 原生更新窗口可能仍然打开。" }
            guard !app.isTerminated, isFrontmost(app.processIdentifier) else {
                clearRemoteSelection()
                return "Codex 已离开前台，已停止等待更新窗口。"
            }
            if refreshRemoteSelection() { return nil }
            let state = focusedSnapshot(in: app)
            if state.blocked { return "Codex 有其他原生确认窗口，请先处理后重试更新。" }
            if state.incomplete { return "无法完整读取更新窗口，请在 Codex 内继续更新。" }
            try? await Task.sleep(for: .milliseconds(350))
        }
        return "Codex 尚未显示可操作的原生更新窗口，请在应用内查看。"
    }

    /// Called before ordinary Codex key mappings. No dialog means no capture.
    /// Only the focused native dialog/status window is scanned; chat/web content is never traversed.
    static func handleRemote(_ key: RemoteKey) -> Bool {
        guard [.up, .down, .left, .right, .ok, .back].contains(key) else { return false }
        let previous = selectedControl
        guard let app = installedApplication(), isFrontmost(app.processIdentifier) else {
            clearRemoteSelection()
            return false
        }
        let state = focusedSnapshot(in: app)
        guard let dialog = state.dialog, !state.blocked, !state.incomplete else {
            clearRemoteSelection()
            return false
        }
        receive(dialog)
        startMonitor()
        if key == .back {
            // Back never guesses a cancel/skip action. Keep the native dialog captured.
            return true
        }
        if key == .ok {
            // If a formerly selected control disappeared, the replacement is previewed
            // first. A fresh dialog's native default (or sole button) needs only one OK.
            if let previous, let selectedControl, !CFEqual(previous, selectedControl),
               !(state.analysis.current && dialog.controls.count == 1) { return true }
            guard let selectedControl,
                  let target = dialog.controls.first(where: { CFEqual($0.element, selectedControl) }),
                  isFrontmost(app.processIdentifier),
                  let window = interactionWindow(AXUIElementCreateApplication(app.processIdentifier)),
                  CFEqual(dialog.window, window), enabled(target.element) else { return true }
            guard press(target.element) else {
                CodexNavigation.showNotice("Codex 未接受按钮操作，请重新选择后再按 OK。")
                return true
            }
            // AXPress can synchronously dismiss or replace the window. Refresh on the
            // next run-loop turn and keep watching until it closes or loses focus.
            Task { @MainActor in _ = refreshRemoteSelection() }
            return true
        }
        let current = dialog.controls.firstIndex { control in selectedControl.map { CFEqual($0, control.element) } ?? false }
        let index = movedIndex(current: current, direction: key, controls: dialog.controls)
        if let index { selectedControl = dialog.controls[index].element; show(dialog.controls[index]) }
        return true
    }

    @discardableResult static func refreshRemoteSelection() -> Bool {
        guard let app = installedApplication(), isFrontmost(app.processIdentifier) else {
            clearRemoteSelection()
            return false
        }
        let state = focusedSnapshot(in: app)
        guard let dialog = state.dialog, !state.blocked, !state.incomplete else {
            clearRemoteSelection()
            return false
        }
        receive(dialog)
        startMonitor()
        return true
    }

    static func clearRemoteSelection() {
        selectedWindow = nil
        selectedControl = nil
        highlight.hide()
        shownFrame = nil
        monitor?.invalidate()
        monitor = nil
        setActive(false)
    }

    private static func setActive(_ value: Bool) {
        guard dialogActive != value else { return }
        dialogActive = value
        onDialogActiveChanged?(value)
    }

    private static func startMonitor() {
        guard monitor == nil else { return }
        monitor = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
            MainActor.assumeIsolated { _ = refreshRemoteSelection() }
        }
    }

    private static func receive(_ dialog: Dialog) {
        let sameWindow = selectedWindow.map { CFEqual($0, dialog.window) } ?? false
        let existing = sameWindow ? dialog.controls.firstIndex { control in
            selectedControl.map { CFEqual($0, control.element) } ?? false
        } : nil
        let index = existing ?? initialIndex(dialog.controls)
        selectedWindow = dialog.window
        selectedControl = index.map { dialog.controls[$0].element }
        if let index { show(dialog.controls[index]) } else { shownFrame = nil; highlight.hide() }
        setActive(true)
    }

    private static func show(_ control: Control) {
        guard shownFrame != control.frame else { return }
        shownFrame = control.frame
        highlight.showTarget(control.frame)
    }

    private static func installedApplication() -> NSRunningApplication? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              let url = app.bundleURL, Bundle(url: url)?.bundleIdentifier == bundleID,
              Bundle(url: url.appendingPathComponent("Contents/Frameworks/Sparkle.framework"))?.bundleIdentifier
                == "org.sparkle-project.Sparkle" else { return nil }
        return app
    }

    private static func labels(in app: NSRunningApplication) -> Labels {
        guard let url = app.bundleURL else { return Labels() }
        if let cachedLabels, cachedLabels.0 == url { return cachedLabels.1 }
        let labels = Labels(sparkle: Bundle(url: url.appendingPathComponent("Contents/Frameworks/Sparkle.framework")))
        cachedLabels = (url, labels)
        return labels
    }

    /// Read-only: resolves only the application menu, never Apple/File/other menus.
    static func resolveMenu(in app: NSRunningApplication) -> AXUIElement? {
        guard app.bundleIdentifier == bundleID else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.05)
        guard let bar = element(root, kAXMenuBarAttribute) else { return nil }
        let items = children(bar)
        guard items.count > 1 else { return nil }
        let appMenu = items[1]
        guard ["ChatGPT", "Codex"].contains(string(appMenu, kAXTitleAttribute)) else { return nil }
        let candidates = children(appMenu).flatMap(children).filter {
            checkMenuLabels.contains(string($0, kAXTitleAttribute)) && enabled($0)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    nonisolated private static let checkMenuLabels: Set<String> = ["检查更新…", "检查更新...", "檢查更新…", "檢查更新...",
        "檢查更新項目…", "Check for Updates…", "Check for Updates..."]

    private struct Labels {
        var windows: Set<String> = ["Software Update"]
        var relaunch: Set<String> = ["Install and Relaunch"]
        var current: Set<String> = ["You’re up to date!", "You're up to date!"]
        var errors: Set<String> = ["Update Error!", "Unable to Check For Updates"]
        var progress: Set<String> = ["Checking for updates…", "Downloading update…", "Extracting update…",
            "Installing update…", "Ready to Install"]

        init(sparkle: Bundle? = nil) {
            guard let resourceURL = sparkle?.resourceURL,
                  let directories = try? FileManager.default.contentsOfDirectory(at: resourceURL,
                    includingPropertiesForKeys: nil) else { return }
            for directory in directories where directory.pathExtension == "lproj" {
                guard let data = try? Data(contentsOf: directory.appendingPathComponent("Sparkle.strings")),
                      data.count < 1_048_576,
                      let translations = try? PropertyListSerialization.propertyList(from: data,
                        format: nil) as? [String: String] else { continue }
                for (key, value) in translations {
                    if windows.contains(key) { windows.insert(value) }
                    if relaunch.contains(key) { relaunch.insert(value) }
                    if current.contains(key) { current.insert(value) }
                    if errors.contains(key) { errors.insert(value) }
                    if progress.contains(key) { progress.insert(value) }
                }
            }
        }
    }

    private struct NativeNode {
        var role: String
        var identifier = ""
        var title = ""
        var value = ""
        var enabled = true
    }

    private struct Analysis {
        var installs: [Int] = []
        var relaunches: [Int] = []
        var progress = false
        var current = false
        var failed = false
        var blocked = false
        var duplicate: Bool { installs.count > 1 || relaunches.count > 1 }
        var visible: Bool { !installs.isEmpty || !relaunches.isEmpty || progress || current || failed }
    }

    nonisolated private static func analyze(_ nodes: [NativeNode], modal: Bool, labels: Labels) -> Analysis {
        var result = Analysis()
        for (index, node) in nodes.enumerated() {
            if node.role == "AXButton", node.identifier == "SPUUserUpdateChoiceInstall" {
                if node.enabled { result.installs.append(index) }
                // Disabled native Install also identifies an update offer.
                result.progress = true
            }
            if node.role == "AXButton", node.identifier == "SUStatusButton" {
                result.progress = true
                if labels.relaunch.contains(node.title), node.enabled { result.relaunches.append(index) }
            }
            if node.role == "AXStaticText" {
                let text = node.title.isEmpty ? node.value : node.title
                if labels.current.contains(text) { result.current = true }
                if labels.errors.contains(text) { result.failed = true }
                if labels.progress.contains(text) { result.progress = true }
            }
        }
        result.blocked = modal && !result.visible
        return result
    }

    private struct Control {
        var element: AXUIElement
        var title: String
        var frame: CGRect
        var preferred = false
    }
    private struct Dialog {
        var window: AXUIElement
        var controls: [Control]
    }
    private struct Snapshot {
        var dialog: Dialog?
        var updater = false
        var blocked = false
        var incomplete = false
        var analysis = Analysis()
    }

    /// Ordinary Codex scroll/OK paths pay only a focused-window read plus native
    /// sheet lookup. A standard Electron window without sheets is never traversed.
    private static func focusedSnapshot(in app: NSRunningApplication) -> Snapshot {
        guard AXIsProcessTrusted() else { return Snapshot() }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.03)
        guard let window = interactionWindow(root) else { return Snapshot() }
        let native = isModal(window)
        // Sparkle's download window may be a standard native status window.
        // Inspect only immediate children for the exact Sparkle status identifier.
        let directChildren = children(window)
        let nativeMarker = directChildren.contains {
            ["SUStatusButton", "SPUUserUpdateChoiceInstall"].contains(string($0, kAXIdentifierAttribute))
        }
        // Native Sparkle windows can use AXStandardWindow. Their AppKit nib
        // identifier permits a bounded native scan, but never authorizes a press:
        // the exact Sparkle marker/text below must still validate the window.
        let nativeNib = string(window, kAXIdentifierAttribute).hasPrefix("_NS:")
        let knownTitle = labels(in: app).windows.contains(string(window, kAXTitleAttribute))
        // AppKit update alerts may be standard windows with empty identifiers.
        // A small non-Electron window is a candidate only; exact Sparkle markers
        // remain mandatory before any selection or action is accepted.
        let bounds = frame(window)
        let smallNative = bounds.map { $0.width <= 900 && $0.height <= 900 } == true
            && !directChildren.contains { ["AXWebArea", "AXGroup"].contains(string($0, kAXRoleAttribute)) }
        guard native || nativeMarker || nativeNib || knownTitle || smallNative else { return Snapshot() }
        let defaultButton = element(window, kAXDefaultButtonAttribute)
        var nodes: [NativeNode] = []
        var controls: [Control] = []
        var stack: [(AXUIElement, Int)] = [(window, 0)]
        var count = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        while let (node, depth) = stack.popLast() {
            count += 1
            guard count < 200, depth < 12, ProcessInfo.processInfo.systemUptime < deadline else {
                return Snapshot(incomplete: true)
            }
            let role = string(node, kAXRoleAttribute)
            if depth > 0 && isModal(node) { return Snapshot(blocked: true) }
            if ["AXWebArea", "AXTextArea", "AXTextField", "AXComboBox"].contains(role) { continue }
            if role == "AXStaticText" || ["AXButton", "AXCheckBox", "AXRadioButton"].contains(role) {
                let title = string(node, kAXTitleAttribute)
                nodes.append(NativeNode(role: role, identifier: string(node, kAXIdentifierAttribute),
                    title: title, value: role == "AXStaticText" ? string(node, kAXValueAttribute) : "",
                    enabled: enabled(node)))
                if role != "AXStaticText", enabled(node), hasPressAction(node),
                   !["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"].contains(string(node, kAXSubroleAttribute)),
                   let rect = frame(node), rect.width > 2, rect.height > 2,
                   bounds.map({ $0.intersects(rect) }) ?? false {
                    let label = title.isEmpty ? string(node, kAXDescriptionAttribute) : title
                    guard !label.isEmpty else { continue }
                    controls.append(Control(element: node, title: String(label.prefix(120)), frame: rect,
                        preferred: defaultButton.map { CFEqual($0, node) } ?? (attribute(node, kAXFocusedAttribute) as? Bool == true)))
                }
            }
            for child in children(node).reversed() { stack.append((child, depth + 1)) }
        }
        let analysis = analyze(nodes, modal: native, labels: labels(in: app))
        guard analysis.visible, !analysis.duplicate else {
            return Snapshot(blocked: analysis.blocked, incomplete: analysis.duplicate, analysis: analysis)
        }
        controls.sort { $0.frame.minY == $1.frame.minY ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY }
        return Snapshot(dialog: Dialog(window: window, controls: controls), updater: true, analysis: analysis)
    }

    nonisolated private static func initialIndex(_ controls: [Control]) -> Int? {
        controls.firstIndex(where: \.preferred) ?? controls.indices.first
    }

    nonisolated private static func movedIndex(current: Int?, direction: RemoteKey, controls: [Control]) -> Int? {
        guard !controls.isEmpty else { return nil }
        let nodes = controls.enumerated().map { index, control in
            AppNavigationNode(id: index, label: control.title, role: "AXButton", frame: control.frame, kind: .button)
        }
        let target = AppNavigationGeometry.target(currentID: current, direction: direction, nodes: nodes)
        guard let current, target == current else { return target }
        // Up/down also walk a horizontal button row, so every option is reachable
        // with the remote's usual list navigation. Edges never wrap.
        if direction == .up || direction == .left { return max(0, current - 1) }
        if direction == .down || direction == .right { return min(controls.count - 1, current + 1) }
        return target
    }

    /// Read-only current-instance diagnostics. Never activates or presses anything.
    static func readOnlyStatus(in app: NSRunningApplication) -> String {
        guard app.bundleIdentifier == bundleID else { return "target=false" }
        let state = focusedSnapshot(in: app)
        let a = state.analysis
        let controls = state.dialog?.controls.map(\.title).joined(separator: "|") ?? ""
        return "menu=\(resolveMenu(in: app) != nil) incomplete=\(state.incomplete) blocked=\(state.blocked) install=\(!a.installs.isEmpty) relaunch=\(!a.relaunches.isEmpty) progress=\(a.progress) current=\(a.current) failed=\(a.failed) controls=\(controls)"
    }

    /// With a standalone Sparkle NSAlert, Electron can still report its chat as
    /// AXFocusedWindow. Prefer an attached sheet or a visible modal in this PID.
    /// Both classification and the last check before AXPress use the same window.
    private static func interactionWindow(_ root: AXUIElement) -> AXUIElement? {
        let focused = element(root, kAXFocusedWindowAttribute)
        var candidate = focused
        if focused.map({ !isModal($0) && (attribute($0, "AXSheets") as? [AXUIElement] ?? []).isEmpty }) ?? true {
            let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
            if let modal = windows.first(where: {
                isModal($0) && attribute($0, kAXMinimizedAttribute) as? Bool != true
                    && attribute($0, "AXHidden") as? Bool != true
            }) { candidate = modal }
        }
        guard var top = candidate else { return nil }
        for _ in 0..<4 {
            guard let sheet = (attribute(top, "AXSheets") as? [AXUIElement])?.last else { break }
            top = sheet
        }
        return top
    }

    private static func isModal(_ node: AXUIElement) -> Bool {
        let role = string(node, kAXRoleAttribute)
        return role == "AXSheet" || role == "AXDialog" || string(node, kAXSubroleAttribute) == "AXDialog"
            || attribute(node, kAXModalAttribute) as? Bool == true
    }
    private static func isFrontmost(_ pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }
    private static func enabled(_ node: AXUIElement) -> Bool { attribute(node, kAXEnabledAttribute) as? Bool == true }
    private static func hasPressAction(_ node: AXUIElement) -> Bool {
        var actions: CFArray?
        return AXUIElementCopyActionNames(node, &actions) == .success
            && (actions as? [String])?.contains(kAXPressAction) == true
    }
    private static func press(_ node: AXUIElement) -> Bool {
        enabled(node) && hasPressAction(node) && AXUIElementPerformAction(node, kAXPressAction as CFString) == .success
    }
    private static func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return nil }
        return value
    }
    private static func string(_ node: AXUIElement, _ name: String) -> String { attribute(node, name) as? String ?? "" }
    private static func element(_ node: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(node, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private static func children(_ node: AXUIElement) -> [AXUIElement] { attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    private static func frame(_ node: AXUIElement) -> CGRect? {
        guard let position = attribute(node, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(node, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    /// Fixtures never start an update, click a real control, install or relaunch.
    nonisolated static func selfCheck() -> Bool {
        let labels = Labels()
        let install = NativeNode(role: "AXButton", identifier: "SPUUserUpdateChoiceInstall", title: "Install Update")
        let relaunch = NativeNode(role: "AXButton", identifier: "SUStatusButton", title: "Install and Relaunch")
        let cancel = NativeNode(role: "AXButton", identifier: "SUStatusButton", title: "Cancel")
        let generic = NativeNode(role: "AXButton", title: "Install and Relaunch")
        let latest = NativeNode(role: "AXStaticText", value: "You’re up to date!")
        let first = analyze([install], modal: true, labels: labels)
        let ready = analyze([relaunch], modal: true, labels: labels)
        let ordinary = analyze([generic], modal: true, labels: labels)
        let closed = analyze([], modal: false, labels: labels)
        let dummy = AXUIElementCreateApplication(0)
        let controls = [
            Control(element: dummy, title: "Later", frame: CGRect(x: 0, y: 50, width: 70, height: 24)),
            Control(element: dummy, title: "Install", frame: CGRect(x: 90, y: 50, width: 70, height: 24), preferred: true)
        ]
        return first.installs == [0] && first.relaunches.isEmpty && !first.blocked
            && ready.relaunches == [0] && !ready.blocked
            && analyze([cancel], modal: true, labels: labels).relaunches.isEmpty
            && ordinary.blocked && !ordinary.visible
            && analyze([latest], modal: true, labels: labels).current
            && !analyze([latest], modal: true, labels: labels).blocked
            && analyze([install, install], modal: true, labels: labels).duplicate
            && !closed.visible && !closed.current && !closed.blocked
            && analyze([NativeNode(role: "AXButton", title: "Update")], modal: true, labels: labels).blocked
            && initialIndex(controls) == 1 && initialIndex([]) == nil
            && movedIndex(current: 1, direction: .left, controls: controls) == 0
            && movedIndex(current: 0, direction: .right, controls: controls) == 1
            && movedIndex(current: 1, direction: .up, controls: controls) == 0
            && movedIndex(current: 0, direction: .down, controls: controls) == 1
            && movedIndex(current: 1, direction: .down, controls: controls) == 1
            && movedIndex(current: 0, direction: .left, controls: controls) == 0
            && checkMenuLabels.contains("检查更新…") && !checkMenuLabels.contains("Update")
    }
}
