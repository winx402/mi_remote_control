import AppKit
import ApplicationServices

/// Uses the installed app's own Sparkle UI. No feed, installer, process termination,
/// preference change, or response to a system authorization dialog is synthesized.
/// Verified with ChatGPT 26.1111.21308 / Sparkle 2.9.1: the nibs expose
/// SPUUserUpdateChoiceInstall and SUStatusButton as accessibility identifiers.
@MainActor enum CodexAppUpdate {
    private static let bundleID = "com.openai.codex"
    private static var running = false

    static func run() async -> String? {
        guard !running else { return "Codex 更新正在进行，请等待原生更新窗口。" }
        guard AXIsProcessTrusted() else { return "需要辅助功能权限，才能操作 Codex 原生更新。" }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              let url = app.bundleURL, let bundle = Bundle(url: url),
              bundle.bundleIdentifier == bundleID,
              let sparkle = Bundle(url: url.appendingPathComponent("Contents/Frameworks/Sparkle.framework")),
              sparkle.bundleIdentifier == "org.sparkle-project.Sparkle" else {
            return "请先打开已安装的 Codex；未找到它的原生 Sparkle 更新器。"
        }
        running = true
        defer { running = false }
        let pid = app.processIdentifier
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.05)
        let labels = Labels(sparkle: sparkle)
        app.activate()
        for _ in 0..<15 {
            if isFrontmost(pid) { break }
            try? await Task.sleep(for: .milliseconds(40))
        }
        guard !Task.isCancelled, isFrontmost(pid) else { return "无法将 Codex 切到前台，请重试。" }

        var state = snapshot(root, labels: labels)
        guard !state.blocked else { return "Codex 有其他原生对话框，请先处理后重试更新。" }
        if state.current { return nil } // Keep the native up-to-date result visible.
        if state.failed { return "Codex 原生更新器报告错误，请查看它的提示。" }
        guard !state.incomplete else { return "无法完整读取 Codex 原生更新窗口，请在 Codex 内检查更新。" }
        if state.install == nil && state.relaunch == nil && !state.progress {
            guard let menu = resolveMenu(in: app), press(menu) else {
                return "未找到可用的 Codex「检查更新」菜单，请在应用内检查更新。"
            }
        }

        let started = ProcessInfo.processInfo.systemUptime
        var installedAt: TimeInterval?
        var sawUpdater = state.progress || state.install != nil || state.relaunch != nil
        while ProcessInfo.processInfo.systemUptime - started < 15 * 60 {
            guard !Task.isCancelled else { return "已停止自动操作；Codex 原生更新可能仍在进行。" }
            // Never follow a replacement instance or reactivate after the user switches away.
            // AXPress targets this PID; background downloading does not require focus.
            if app.isTerminated {
                return installedAt != nil ? nil : "Codex 已退出，已停止更新操作。"
            }
            state = snapshot(root, labels: labels)
            guard !state.incomplete else { return "无法完整读取更新窗口，请在 Codex 内继续更新。" }
            if state.blocked {
                return "更新需要处理 Codex 或系统的确认窗口，请手动确认；自动操作已停止。"
            }
            if state.failed { return "Codex 原生更新器报告错误，请查看它的提示。" }
            if state.current { return nil }
            if let relaunch = state.relaunch {
                // Only Sparkle's exact native status-button identifier and localized
                // Install and Relaunch title qualify. Never approve a generic Update/OK.
                guard !Task.isCancelled, press(relaunch) else {
                    return "Codex 未接受原生安装并重启动作，请在更新窗口继续。"
                }
                return nil
            }
            if let install = state.install, installedAt == nil {
                guard !Task.isCancelled, press(install) else {
                    return "Codex 未接受原生安装更新动作，请在更新窗口继续。"
                }
                installedAt = ProcessInfo.processInfo.systemUptime
            }
            let visible = state.install != nil || state.relaunch != nil || state.progress
            if visible {
                sawUpdater = true
            } else if sawUpdater {
                // Sparkle replaces its offer with a download/status window. Only
                // this immediate transition gets a short observation-only grace;
                // installedAt prevents another Install press throughout the run.
                if installedAt.map({ ProcessInfo.processInfo.systemUptime - $0 >= 2 }) ?? true {
                    return "原生更新窗口已关闭，已停止自动操作；请在 Codex 内确认更新状态。"
                }
            } else if ProcessInfo.processInfo.systemUptime - started > 45 {
                return "Codex 尚未显示可识别的原生更新结果，请在应用内查看。"
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return "更新等待超时，自动操作已停止；请在 Codex 原生窗口继续。"
    }

    /// Read-only: resolves only the application menu, never Apple/File/other menus.
    /// Useful for verifying installed versions without starting an update check.
    static func resolveMenu(in app: NSRunningApplication) -> AXUIElement? {
        guard app.bundleIdentifier == bundleID else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.05)
        guard let bar = element(root, kAXMenuBarAttribute) else { return nil }
        let items = children(bar)
        // The first menu is the system Apple menu; the next is this app's menu.
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
        var relaunch: Set<String> = ["Install and Relaunch"]
        var current: Set<String> = ["You’re up to date!"]
        var errors: Set<String> = ["Update Error!", "Unable to Check For Updates"]
        var progress: Set<String> = ["Checking for updates…", "Downloading update…", "Extracting update…",
            "Installing update…", "Ready to Install"]

        init(sparkle: Bundle? = nil) {
            guard let resourceURL = sparkle?.resourceURL,
                  let directories = try? FileManager.default.contentsOfDirectory(at: resourceURL,
                    includingPropertiesForKeys: nil) else { return }
            // Read the installed framework's translations; the app can use a language
            // different from this remote's language. No user preferences are changed.
            for directory in directories where directory.pathExtension == "lproj" {
                let url = directory.appendingPathComponent("Sparkle.strings")
                guard let data = try? Data(contentsOf: url), data.count < 1_048_576,
                      let translations = try? PropertyListSerialization.propertyList(from: data,
                        format: nil) as? [String: String] else { continue }
                for (key, value) in translations {
                    if relaunch.contains(key) { relaunch.insert(value) }
                    if current.contains(key) { current.insert(value) }
                    if errors.contains(key) { errors.insert(value) }
                    if progress.contains(key) { progress.insert(value) }
                }
            }
        }
    }

    private struct Snapshot {
        var install: AXUIElement?
        var relaunch: AXUIElement?
        var progress = false
        var current = false
        var failed = false
        var blocked = false
        var incomplete = false
    }

    private struct NativeNode {
        var role: String
        var identifier = ""
        var title = ""
        var value = ""
        var enabled = true
        var element: AXUIElement?
    }

    private struct Analysis {
        var installs: [Int] = []
        var relaunches: [Int] = []
        var progress = false
        var current = false
        var failed = false
        var blocked = false
        var duplicate: Bool { installs.count > 1 || relaunches.count > 1 }
        var visible: Bool { !installs.isEmpty || !relaunches.isEmpty || progress }
    }

    nonisolated private static func analyze(_ nodes: [NativeNode], modal: Bool, labels: Labels) -> Analysis {
        var result = Analysis()
        var updater = false
        for (index, node) in nodes.enumerated() {
            if node.role == "AXButton", node.identifier == "SPUUserUpdateChoiceInstall" {
                updater = true
                if node.enabled { result.installs.append(index) }
            }
            if node.role == "AXButton", node.identifier == "SUStatusButton" {
                updater = true
                result.progress = true
                if labels.relaunch.contains(node.title), node.enabled { result.relaunches.append(index) }
            }
            if node.role == "AXStaticText" {
                let text = node.title.isEmpty ? node.value : node.title
                if labels.current.contains(text) { result.current = true; updater = true }
                if labels.errors.contains(text) { result.failed = true; updater = true }
                if labels.progress.contains(text) { result.progress = true; updater = true }
            }
        }
        result.blocked = modal && !updater
        return result
    }

    /// Read-only current-instance preflight. Does not activate the app or press anything.
    static func readOnlyStatus(in app: NSRunningApplication) -> String {
        guard app.bundleIdentifier == bundleID, let url = app.bundleURL,
              let sparkle = Bundle(url: url.appendingPathComponent("Contents/Frameworks/Sparkle.framework")) else {
            return "target=false"
        }
        let state = snapshot(AXUIElementCreateApplication(app.processIdentifier), labels: Labels(sparkle: sparkle))
        return "menu=\(resolveMenu(in: app) != nil) incomplete=\(state.incomplete) blocked=\(state.blocked) install=\(state.install != nil) relaunch=\(state.relaunch != nil) progress=\(state.progress) current=\(state.current) failed=\(state.failed)"
    }

    private static func snapshot(_ root: AXUIElement, labels: Labels) -> Snapshot {
        AXUIElementSetMessagingTimeout(root, 0.05)
        var result = Snapshot()
        var roots = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        if let focused = element(root, kAXFocusedWindowAttribute), !roots.contains(where: { CFEqual($0, focused) }) {
            roots.append(focused)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.6
        var total = 0
        var visited: [AXUIElement] = []
        while !roots.isEmpty {
            let window = roots.removeFirst()
            guard !visited.contains(where: { CFEqual($0, window) }) else { continue }
            visited.append(window)
            var stack: [(AXUIElement, Int)] = [(window, 0)]
            let modal = isModal(window)
            var nodes: [NativeNode] = []
            while let (node, depth) = stack.popLast() {
                total += 1
                guard total < 500, depth < 16, ProcessInfo.processInfo.systemUptime < deadline else {
                    result.incomplete = true
                    return result
                }
                let role = string(node, kAXRoleAttribute)
                // Native sheets are analyzed independently: a parent's updater
                // marker must never authorize an unrelated attached confirmation.
                if depth > 0 && isModal(node) { roots.append(node); continue }
                // Never inspect web/chat content, editable values, or release notes.
                if ["AXWebArea", "AXTextArea", "AXTextField", "AXComboBox"].contains(role) { continue }
                if role == "AXButton" || role == "AXStaticText" {
                    nodes.append(NativeNode(role: role, identifier: string(node, kAXIdentifierAttribute),
                        title: string(node, kAXTitleAttribute),
                        value: role == "AXStaticText" ? string(node, kAXValueAttribute) : "",
                        enabled: enabled(node), element: node))
                }
                let descendants = children(node)
                for child in descendants.reversed() { stack.append((child, depth + 1)) }
                for sheet in attribute(node, "AXSheets") as? [AXUIElement] ?? [] {
                    roots.append(sheet)
                }
            }
            let analysis = analyze(nodes, modal: modal, labels: labels)
            result.progress = result.progress || analysis.progress
            result.current = result.current || analysis.current
            result.failed = result.failed || analysis.failed
            result.blocked = result.blocked || analysis.blocked
            result.incomplete = result.incomplete || analysis.duplicate
            if let index = analysis.installs.first {
                if result.install != nil { result.incomplete = true }
                result.install = nodes[index].element
            }
            if let index = analysis.relaunches.first {
                if result.relaunch != nil { result.incomplete = true }
                result.relaunch = nodes[index].element
            }
        }
        return result
    }

    private static func isModal(_ node: AXUIElement) -> Bool {
        let role = string(node, kAXRoleAttribute)
        return role == "AXSheet" || role == "AXDialog" || string(node, kAXSubroleAttribute) == "AXDialog"
            || attribute(node, kAXModalAttribute) as? Bool == true
    }

    private static func isFrontmost(_ pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    private static func enabled(_ node: AXUIElement) -> Bool {
        attribute(node, kAXEnabledAttribute) as? Bool == true
    }

    private static func press(_ node: AXUIElement) -> Bool {
        var actions: CFArray?
        return enabled(node) && AXUIElementCopyActionNames(node, &actions) == .success
            && (actions as? [String])?.contains(kAXPressAction) == true
            && AXUIElementPerformAction(node, kAXPressAction as CFString) == .success
    }

    private static func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func string(_ node: AXUIElement, _ name: String) -> String {
        attribute(node, name) as? String ?? ""
    }

    private static func element(_ node: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(node, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func children(_ node: AXUIElement) -> [AXUIElement] {
        attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    /// Fixture checks; never presses a menu/button or starts an update.
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
        return first.installs == [0] && first.relaunches.isEmpty && !first.blocked
            && ready.relaunches == [0] && !ready.blocked
            && analyze([cancel], modal: true, labels: labels).relaunches.isEmpty
            && ordinary.blocked && !ordinary.visible
            && analyze([latest], modal: true, labels: labels).current
            && !analyze([latest], modal: true, labels: labels).blocked
            && analyze([install, install], modal: true, labels: labels).duplicate
            && !closed.visible && !closed.current && !closed.blocked
            && analyze([NativeNode(role: "AXButton", title: "Update")], modal: true, labels: labels).blocked
            && checkMenuLabels.contains("检查更新…") && !checkMenuLabels.contains("Update")
    }
}
