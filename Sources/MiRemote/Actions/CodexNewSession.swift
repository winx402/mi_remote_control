import AppKit
import ApplicationServices
import CoreGraphics

extension CodexSessions {
    private(set) static var newSessionFailure: String?

    /// Opens an empty composer. Success means the OS accepted the navigation or
    /// AX action; no prompt, thread/start, or turn/start request is ever sent.
    static func openNew(in project: CodexSessionCatalog.Project?) async -> Bool {
        newSessionFailure = nil
        var catalog = CodexSessionCatalog.Result()
        var target: CodexSessionCatalog.Project?
        if let project {
            catalog = await Task.detached(priority: .userInitiated) { CodexSessionCatalog.read() }.value
            guard !Task.isCancelled else { return false }
            guard let current = catalog.sidebarProjects.first(where: { $0.groupID == project.groupID }),
                  current.name == project.name, current.roots == project.roots else {
                newSessionFailure = "项目已变更或不可用，请刷新会话列表后重试。"
                return false
            }
            target = current
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first else {
            newSessionFailure = "请先打开 Codex，再创建新聊天。"
            return false
        }
        guard AXIsProcessTrusted() else {
            if let target, let url = CodexNewSession.localURL(for: target), !Task.isCancelled {
                let opened = NSWorkspace.shared.open(url)
                if !opened { newSessionFailure = "Codex 未接受项目新聊天链接。" }
                return opened
            }
            newSessionFailure = "需要辅助功能权限，才能打开所选位置的新聊天。"
            return false
        }
        guard !Task.isCancelled else { return false }
        app.activate()
        for _ in 0..<10 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { break }
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return false }
        }
        guard !Task.isCancelled,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            newSessionFailure = "无法将 Codex 切到前台，请切换后重试。"
            return false
        }
        if let target {
            let unambiguous = CodexNewSession.isUnambiguous(target, among: catalog.sidebarProjects)
            var projectButton = unambiguous ? CodexNewSession.projectButton(target, pid: app.processIdentifier) : nil
            if projectButton == nil, unambiguous, target.hostID != nil,
               let showSidebar = CodexNewSession.showSidebarButton(pid: app.processIdentifier) {
                // This is an explicit Show action, never a blind sidebar toggle.
                // Requery only after expansion; a draft action is still sent once.
                guard !Task.isCancelled,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                      AXUIElementPerformAction(showSidebar, kAXPressAction as CFString) == .success else {
                    newSessionFailure = "Codex 未接受显示侧栏动作，请显示侧栏后重试。"
                    return false
                }
                for delay in [80, 120, 160] {
                    try? await Task.sleep(for: .milliseconds(delay))
                    guard !Task.isCancelled,
                          NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return false }
                    projectButton = CodexNewSession.projectButton(target, pid: app.processIdentifier)
                    if projectButton != nil { break }
                }
            }
            if let button = projectButton {
                // Recheck immediately before creating a draft. Never retry a
                // press whose outcome is unknown: that could open a second draft.
                guard !Task.isCancelled,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                      AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
                    newSessionFailure = "Codex 未接受项目新聊天动作，请确认项目和连接状态后重试。"
                    return false
                }
                return true
            }
            if let url = CodexNewSession.localURL(for: target), !Task.isCancelled {
                let opened = NSWorkspace.shared.open(url)
                if !opened { newSessionFailure = "Codex 未接受项目新聊天链接。" }
                return opened
            }
            guard unambiguous else {
                newSessionFailure = "Codex 中有无法区分的同名项目，请在 Codex 内选择目标项目后新建。"
                return false
            }
            newSessionFailure = "请显示 Codex 侧栏并确认远程电脑已连接后重试。"
            return false
        }
        // The generic newTask command inherits the selected project. Only the
        // dedicated newProjectlessTask command explicitly uses activeProject:null.
        guard !Task.isCancelled, let shortcut = CodexNewSession.projectlessShortcut(),
              let down = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.key, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.key, keyDown: false),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            newSessionFailure = "Codex 的无项目新聊天快捷键已禁用或无法安全解析，请在 Codex 内新建。"
            return false
        }
        down.flags = shortcut.flags
        up.flags = shortcut.flags
        down.postToPid(app.processIdentifier)
        up.postToPid(app.processIdentifier)
        return true
    }
}

/// Verified against ChatGPT.app 26.1111.21308 app.asar:
/// newThread deep links resolve local-projects only and discard hostId. Remote
/// routing therefore presses the sidebar's newThreadInGroup button, whose own
/// handler carries the complete project and host. No synthetic remote URL.
enum CodexNewSession {
    struct Shortcut: Equatable {
        let key: CGKeyCode
        let flags: CGEventFlags
    }

    static func localURL(for project: CodexSessionCatalog.Project) -> URL? {
        guard project.hostID == nil, let id = project.localLaunchID,
              valid(id, limit: 512), let root = project.roots.first,
              root.hasPrefix("/"), valid(root, limit: 4096) else { return nil }
        var url = URLComponents(string: "codex://threads/new")!
        // mode is necessary: a projectId-only link is ignored by this build's
        // newThread parser. path and ID refer to the same verified local project.
        url.queryItems = [URLQueryItem(name: "mode", value: "codex"),
            URLQueryItem(name: "projectId", value: id), URLQueryItem(name: "path", value: root)]
        return url.url
    }

    private static func valid(_ value: String, limit: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= limit
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    static func rowLabel(_ project: CodexSessionCatalog.Project) -> String {
        if project.hostID != nil, let name = project.hostName, !name.isEmpty { return project.name + " " + name }
        return project.name
    }

    static func isUnambiguous(_ project: CodexSessionCatalog.Project,
        among projects: [CodexSessionCatalog.Project]) -> Bool {
        let matches = projects.filter { other in
            guard other.name == project.name else { return false }
            if other.hostID != nil && other.hostName == nil || project.hostID != nil && project.hostName == nil { return true }
            return rowLabel(other) == rowLabel(project)
        }
        return Set(matches.map(\.groupID)) == [project.groupID]
    }

    static func buttonLabels(_ name: String) -> Set<String> {
        ["Start new chat in \(name)", "在 \(name) 中开始新聊天", "在 \(name) 中開始新聊天"]
    }

    static let showSidebarLabels: Set<String> = ["显示侧边栏", "顯示側邊欄", "Show sidebar"]

    @MainActor static func projectButton(_ project: CodexSessionCatalog.Project, pid: pid_t) -> AXUIElement? {
        findButton(labels: buttonLabels(project.name), project: project, pid: pid)
    }

    @MainActor static func showSidebarButton(pid: pid_t) -> AXUIElement? {
        findButton(labels: showSidebarLabels, project: nil, pid: pid)
    }

    @MainActor private static func findButton(labels: Set<String>, project: CodexSessionCatalog.Project?,
        pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let window = attribute(app, kAXFocusedWindowAttribute),
              CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        let root = window as! AXUIElement
        var stack: [(AXUIElement, Bool, Int)] = [(root, project == nil, 0)]
        let deadline = ProcessInfo.processInfo.systemUptime + 1.2
        var count = 0
        var candidates: [AXUIElement] = []
        while !stack.isEmpty {
            guard count < 2000, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            let (element, inRow, depth) = stack.removeLast()
            count += 1
            guard depth < 40 else { continue }
            let role = attribute(element, kAXRoleAttribute) as? String ?? ""
            // Never inspect editable values or message text.
            if ["AXTextArea", "AXTextField", "AXStaticText", "AXLink"].contains(role) { continue }
            let title = attribute(element, kAXTitleAttribute) as? String ?? ""
            let description = attribute(element, kAXDescriptionAttribute) as? String ?? ""
            if role == "AXButton", inRow, labels.contains(title) || labels.contains(description) {
                guard (attribute(element, kAXEnabledAttribute) as? Bool) == true else { return nil }
                var actions: CFArray?
                guard AXUIElementCopyActionNames(element, &actions) == .success,
                      (actions as? [String])?.contains(kAXPressAction) == true else { return nil }
                candidates.append(element)
            }
            // Some remote-control hosts have no persisted display name. The
            // caller requires a globally unique project name in that case, and
            // the complete walk below additionally rejects duplicate buttons.
            let rowMatches = project.map { project in
                let row = rowLabel(project), unknownHost = project.hostID != nil && project.hostName == nil
                return role == "AXButton" && (title == row || description == row ||
                    unknownHost && (title.hasPrefix(row + " ") || description.hasPrefix(row + " ")))
            } ?? false
            let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            for child in children.reversed() { stack.append((child, inRow || rowMatches, depth + 1)) }
        }
        guard stack.isEmpty, candidates.count == 1 else { return nil }
        return candidates[0]
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func projectlessShortcut() -> Shortcut? {
        let url = CodexSessionCatalog.home.appendingPathComponent("keybindings.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return shortcut("Command+Alt+O") }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
              let data = try? Data(contentsOf: url) else { return nil }
        return projectlessShortcut(data)
    }

    static func projectlessShortcut(_ data: Data) -> Shortcut? {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              entries.allSatisfy({ $0["command"] is String && ($0["key"] is String || $0["key"] is NSNull) }) else { return nil }
        let bindings = entries.filter { ($0["command"] as? String) == "newProjectlessTask" }
        let candidates = bindings.isEmpty ? [shortcut("Command+Alt+O")].compactMap { $0 }
            : bindings.compactMap { ($0["key"] as? String).flatMap(shortcut) }
        let others = entries.filter { ($0["command"] as? String) != "newProjectlessTask" }
            .compactMap { ($0["key"] as? String).flatMap(shortcut) }
        return candidates.first(where: { !others.contains($0) })
    }

    static func shortcut(_ value: String) -> Shortcut? {
        let parts = value.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1, let last = parts.last else { return nil }
        guard last.count == 1, last.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) == nil,
              let code = ActionRunner.keyCodes[last] else { return nil }
        var flags = CGEventFlags()
        for part in parts.dropLast() {
            switch part {
            case "command", "cmd", "cmdorctrl": flags.insert(.maskCommand)
            case "alt", "option", "opt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "shift": flags.insert(.maskShift)
            default: return nil
            }
        }
        // Never synthesize a typing-only binding or an Enter/Space submit key.
        guard flags.contains(.maskCommand) || flags.contains(.maskControl) else { return nil }
        return Shortcut(key: code, flags: flags)
    }

    static func selfCheck() -> Bool {
        let local = CodexSessionCatalog.Project(id: "legacy", name: "Same", hostID: nil,
            roots: ["/repo & one"], localLaunchID: "legacy")
        let remote = CodexSessionCatalog.Project(id: "remote", name: "Same", hostID: "ssh:test",
            roots: ["/repo"], hostName: "Computer")
        let collision = CodexSessionCatalog.Project(id: "other", name: "Same", hostID: "ssh:other",
            roots: ["/other"], hostName: "Computer")
        let unnamed = CodexSessionCatalog.Project(id: "unnamed", name: "Same", hostID: "ssh:unnamed", roots: ["/repo"])
        guard let url = localURL(for: local), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.first(where: { $0.name == "projectId" })?.value == "legacy",
              components.queryItems?.first(where: { $0.name == "path" })?.value == "/repo & one",
              localURL(for: remote) == nil, isUnambiguous(remote, among: [local, remote]),
              !isUnambiguous(remote, among: [local, remote, collision]),
              !isUnambiguous(unnamed, among: [local, unnamed]), isUnambiguous(unnamed, among: [unnamed]),
              rowLabel(remote) == "Same Computer", buttonLabels("Same").contains("在 Same 中开始新聊天"),
              showSidebarLabels.contains("显示侧边栏"), showSidebarLabels.contains("Show sidebar"),
              !showSidebarLabels.contains("隐藏侧边栏"), !showSidebarLabels.contains("Hide sidebar"),
              projectlessShortcut(Data("[]".utf8)) == shortcut("Command+Alt+O"),
              projectlessShortcut(Data(#"[{"command":"newProjectlessTask","key":null}]"#.utf8)) == nil,
              projectlessShortcut(Data(#"[{"command":"newProjectlessTask","key":"Command+Shift+P"}]"#.utf8)) == shortcut("Command+Shift+P"),
              projectlessShortcut(Data(#"[{"command":"other","key":"Command+Alt+O"}]"#.utf8)) == nil,
              shortcut("Enter") == nil, shortcut("Command+K Command+O") == nil,
              projectlessShortcut(Data("invalid".utf8)) == nil else { return false }
        return true
    }
}
