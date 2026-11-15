import AppKit
import ApplicationServices
import SQLite3

/// A short-lived identity captured before the picker takes focus. Reads only window/header
/// and selected-sidebar metadata; never asks AX for conversation text or input values.
struct CodexSessionIdentity: Sendable {
    private let ids: Set<String>
    private let hostIDs: Set<String>
    private let titles: Set<String>

    private init(ids: Set<String>, titles: Set<String>, hostIDs: Set<String> = []) {
        self.hostIDs = hostIDs
        self.ids = ids
        self.titles = titles
    }

    @MainActor
    static func capture() -> CodexSessionIdentity? {
        guard AXIsProcessTrusted(),
              let running = NSWorkspace.shared.frontmostApplication,
              running.bundleIdentifier == "com.openai.codex" else { return nil }
        return Reader(pid: running.processIdentifier).capture()
    }

    /// A title cannot establish uniqueness while more pages are still outstanding.
    /// An explicit ID can be selected as soon as its page arrives.
    func resolve(in entries: [CodexSessions.Entry], complete: Bool) -> String? {
        resolveEntry(in: entries, complete: complete)?.id
    }

    func resolveIdentityKey(in entries: [CodexSessions.Entry], complete: Bool) -> String? {
        resolveEntry(in: entries, complete: complete)?.identityKey
    }

    private func resolveEntry(in entries: [CodexSessions.Entry], complete: Bool) -> CodexSessions.Entry? {
        guard hostIDs.count <= 1 else { return nil }
        let candidates = entries.filter { entry in
            hostIDs.first.map { (entry.hostID ?? "local") == $0 } ?? true
        }
        let matches: [CodexSessions.Entry]
        if !ids.isEmpty {
            guard ids.count == 1, let id = ids.first else { return nil }
            matches = candidates.filter { $0.id == id }
        } else {
            guard complete, titles.count == 1, let title = titles.first else { return nil }
            matches = candidates.filter { Self.fullTitle($0.name) == title }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Background-only, read-only lookup. This covers an active thread outside the bounded
    /// app-server list and verifies title uniqueness across the entire local index.
    nonisolated func lookupInIndex() -> CodexSessions.Entry? {
        guard !Thread.isMainThread, ids.count <= 1, hostIDs.isSubset(of: ["local"]),
              let lookup = indexLookup(), let database = Self.indexDatabase() else { return nil }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let connection else {
            if let connection { sqlite3_close(connection) }
            return nil
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 120)
        var deadline = ProcessInfo.processInfo.systemUptime + 0.4
        return withUnsafeMutablePointer(to: &deadline) { deadlinePointer in
            // A title lookup may scan an unindexed table; interrupt it rather than run
            // without a bound. This connection belongs exclusively to this invocation.
            sqlite3_progress_handler(connection, 1_000, { context in
                guard let context else { return 1 }
                return ProcessInfo.processInfo.systemUptime >= context.assumingMemoryBound(to: Double.self).pointee ? 1 : 0
            }, deadlinePointer)
            defer { sqlite3_progress_handler(connection, 0, nil, nil) }
            var statement: OpaquePointer?
            let sql = "SELECT id,title,updated_at FROM threads WHERE archived=0 AND \(lookup.column)=? LIMIT 2"
            guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            guard sqlite3_bind_text(statement, 1, lookup.value, -1, transient) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW,
                  let idBytes = sqlite3_column_text(statement, 0),
                  sqlite3_column_bytes(statement, 0) <= 2_048,
                  sqlite3_column_bytes(statement, 1) <= 2_048 else { return nil }
            let id = String(cString: idBytes)
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            let entry = CodexSessions.Entry(id: id, name: title, updatedAt: sqlite3_column_double(statement, 2))
            guard sqlite3_step(statement) == SQLITE_DONE,
                  resolve(in: [entry], complete: true) == id else { return nil }
            return entry
        }
    }

    nonisolated private func indexLookup() -> (column: String, value: String)? {
        if ids.count == 1, let id = ids.first { return ("id", id) }
        guard ids.isEmpty, titles.count == 1, let title = titles.first else { return nil }
        return ("title", title)
    }

    nonisolated private static func indexDatabase() -> URL? {
        let override = ProcessInfo.processInfo.environment["CODEX_HOME"]
        let directory = override.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        // Prefer the newest schema version, never a backup, journal, WAL, or session file.
        return files.compactMap { file -> (Int, URL)? in
            let name = file.lastPathComponent
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"),
                  let version = Int(name.dropFirst(6).dropLast(7)) else { return nil }
            return (version, file)
        }.max(by: { $0.0 < $1.0 })?.1
    }

    nonisolated private static func fullTitle(_ value: String?) -> String? {
        guard let value, value.count <= 512,
              !value.contains("…"), !value.contains("..."),
              !value.contains("\0") else { return nil }
        let normalized = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !normalized.isEmpty,
              !["codex", "codex desktop", "chatgpt", "chatgpt work", "work", "new chat", "new thread",
                "新聊天", "新对话", "新会话", "未命名会话"]
                .contains(normalized.lowercased()) else { return nil }
        return normalized
    }

    nonisolated private static func threadReference(_ value: String) -> (id: String, hostID: String?)? {
        if let url = URLComponents(string: value), url.scheme?.lowercased() == "codex",
           url.host?.lowercased() == "threads", url.fragment == nil, url.path.hasPrefix("/") {
            let path = String(url.path.dropFirst())
            let hosts = (url.queryItems ?? []).filter { $0.name == "hostId" }
            guard !path.isEmpty, !path.contains("/"), path.count <= 512,
                  path.rangeOfCharacter(from: .controlCharacters) == nil, hosts.count <= 1 else { return nil }
            if let item = hosts.first {
                guard let hostID = item.value, !hostID.isEmpty, hostID.count <= 512,
                      hostID.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
                return (path, hostID)
            }
            return (path, nil)
        }
        let id = value.hasPrefix("thread:") ? String(value.dropFirst(7)) : value
        return UUID(uuidString: id) == nil ? nil : (id.lowercased(), nil)
    }

    /// Pure fixtures: no AX objects, workspace, index, messages, or real sessions are read.
    nonisolated static func selfCheck() -> Bool {
        let current = CodexSessions.Entry(id: "current", name: "让 Apple TV 遥控器控制 Mac", updatedAt: 1)
        let newest = CodexSessions.Entry(id: "newest", name: "另一个会话", updatedAt: 9)
        let title = CodexSessionIdentity(ids: [], titles: ["让 Apple TV 遥控器控制 Mac"])
        let explicit = CodexSessionIdentity(ids: ["current"], titles: ["另一个会话"])
        let duplicate = CodexSessions.Entry(id: "duplicate", name: current.name, updatedAt: 3)
        let remote = CodexSessions.Entry(id: current.id, name: current.name, updatedAt: 5, hostID: "test:remote")
        let remoteIdentity = CodexSessionIdentity(ids: [current.id], titles: [], hostIDs: ["test:remote"])
        guard remoteIdentity.resolveIdentityKey(in: [current, remote], complete: false) == remote.identityKey,
              explicit.resolveIdentityKey(in: [current, remote], complete: true) == nil,
              title.resolveIdentityKey(in: [current, remote], complete: true) == nil,
              threadReference("codex://threads/current?hostId=test%3Aremote")?.hostID == "test:remote",
              threadReference("codex://threads/current?hostId=a&hostId=b") == nil else { return false }
        return title.resolve(in: [newest, current], complete: true) == "current"
            && title.resolve(in: [newest, current], complete: false) == nil
            && title.resolve(in: [current, duplicate], complete: true) == nil
            && title.resolve(in: [newest], complete: true) == nil
            && explicit.resolve(in: [newest, current], complete: false) == "current"
            && explicit.resolve(in: [newest], complete: true) == nil
            && CodexSessionIdentity(ids: ["current", "newest"], titles: []).resolve(in: [current], complete: true) == nil
            && fullTitle("  让 Apple TV\n遥控器控制 Mac  ") == current.name
            && fullTitle("让 Apple TV…") == nil && fullTitle("Codex") == nil
            && fullTitle("ChatGPT Work") == nil && fullTitle("Codex Desktop") == nil
            && threadReference("codex://threads/current")?.id == "current"
            && threadReference("codex://threads/a/b") == nil && threadReference("https://example.com/current") == nil
            && title.indexLookup()?.column == "title" && explicit.indexLookup()?.value == "current"
    }

    @MainActor
    private final class Reader {
        private let pid: pid_t
        private let deadline = ProcessInfo.processInfo.systemUptime + 0.65
        private var calls = 0
        private var hostIDs = Set<String>()
        private var ids = Set<String>()
        private var titles = Set<String>()
        private var headerTitles: [(x: CGFloat, title: String)] = []
        private var visited: [AXUIElement] = []
        private let excludedRoles: Set<String> = ["AXTextArea", "AXTextField", "AXSearchField", "AXComboBox"]

        init(pid: pid_t) { self.pid = pid }

        func capture() -> CodexSessionIdentity? {
            let app = AXUIElementCreateApplication(pid)
            guard let window = element(app, kAXFocusedWindowAttribute), let frame = frame(window) else { return nil }
            // Electron may not expose its document until accessibility has been requested.
            for attribute in ["AXManualAccessibility", "AXEnhancedUserInterface"] where permitted {
                AXUIElementSetMessagingTimeout(app, 0.025)
                _ = AXUIElementSetAttributeValue(app, attribute as CFString, kCFBooleanTrue)
            }
            readIdentity(window, title: false)
            let windowTitle = string(window, kAXTitleAttribute).flatMap(Self.windowTitle)

            // Header is at y≈21 in the desktop screenshot; hit testing skips arbitrarily
            // deep Electron wrappers. Sidebar edge is discovered by a bounded structural pass.
            let root = AXUIElementCreateSystemWide()
            let headerY = frame.minY + min(23, frame.height * 0.04)
            let positions = [0.28, 0.34, 0.42, 0.5].map { frame.minX + frame.width * $0 }
            for x in positions where permitted {
                if let hit = hit(root, at: CGPoint(x: x, y: headerY)), belongs(hit, to: window) {
                    readHeaderPath(hit, window: window, windowFrame: frame)
                }
                if !ids.isEmpty || !headerTitles.isEmpty { break }
            }
            if ids.isEmpty && headerTitles.isEmpty { scan(window, window: window, windowFrame: frame) }
            if let leftmost = headerTitles.min(by: { $0.x < $1.x }) {
                titles.formUnion(headerTitles.filter { abs($0.x - leftmost.x) < 3 }.map(\.title))
            }
            if titles.isEmpty, let windowTitle { titles.insert(windowTitle) }
            // The traversal has its own reserve; final validation gets one separately
            // bounded AX request even when discovery exhausted its budget.
            AXUIElementSetMessagingTimeout(app, 0.025)
            var latestValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &latestValue) == .success,
                  let latestValue, CFGetTypeID(latestValue) == AXUIElementGetTypeID(), CFEqual(window, latestValue),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  !ids.isEmpty || !titles.isEmpty else { return nil }
            return CodexSessionIdentity(ids: ids, titles: titles, hostIDs: hostIDs)
        }

        private var permitted: Bool { calls < 450 && ProcessInfo.processInfo.systemUptime < deadline }

        private func attribute(_ owner: AXUIElement, _ name: String) -> CFTypeRef? {
            guard permitted else { return nil }
            calls += 1
            AXUIElementSetMessagingTimeout(owner, 0.025)
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(owner, name as CFString, &value) == .success ? value : nil
        }

        private func element(_ owner: AXUIElement, _ name: String) -> AXUIElement? {
            guard let value = attribute(owner, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(value, to: AXUIElement.self)
        }

        private func string(_ owner: AXUIElement, _ name: String) -> String? { attribute(owner, name) as? String }

        private func frame(_ owner: AXUIElement) -> CGRect? {
            guard let position = attribute(owner, kAXPositionAttribute), let size = attribute(owner, kAXSizeAttribute),
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero
            var dimensions = CGSize.zero
            guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
                  AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions),
                  point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
                  dimensions.width > 0, dimensions.height > 0 else { return nil }
            return CGRect(origin: point, size: dimensions)
        }

        private func children(_ owner: AXUIElement, _ name: String = kAXChildrenAttribute, limit: Int = 32) -> [AXUIElement] {
            guard permitted else { return [] }
            calls += 1
            AXUIElementSetMessagingTimeout(owner, 0.025)
            var values: CFArray?
            guard AXUIElementCopyAttributeValues(owner, name as CFString, 0, limit, &values) == .success else { return [] }
            return values as? [AXUIElement] ?? []
        }

        private func hit(_ root: AXUIElement, at point: CGPoint) -> AXUIElement? {
            guard permitted else { return nil }
            calls += 1
            AXUIElementSetMessagingTimeout(root, 0.025)
            var value: AXUIElement?
            guard AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &value) == .success,
                  let value else { return nil }
            var owner: pid_t = 0
            return AXUIElementGetPid(value, &owner) == .success && owner == pid ? value : nil
        }

        private func belongs(_ owner: AXUIElement, to window: AXUIElement) -> Bool {
            if CFEqual(owner, window) { return true }
            if let owningWindow = element(owner, kAXWindowAttribute) { return CFEqual(owningWindow, window) }
            var node = owner
            for _ in 0..<16 {
                guard let parent = element(node, kAXParentAttribute), !CFEqual(parent, node) else { return false }
                if CFEqual(parent, window) { return true }
                node = parent
            }
            return false
        }

        private func readIdentity(_ owner: AXUIElement, title: Bool, headerX: CGFloat? = nil) {
            for name in [kAXURLAttribute, kAXDocumentAttribute, "AXIdentifier"] {
                let value = attribute(owner, name)
                let text = (value as? URL)?.absoluteString ?? (value as? String)
                if let text, let ref = CodexSessionIdentity.threadReference(text) {
                    ids.insert(ref.id)
                    if let hostID = ref.hostID { hostIDs.insert(hostID) }
                }
            }
            guard title, let role = string(owner, kAXRoleAttribute),
                  ["AXStaticText", "AXHeading", "AXButton", "AXLink", "AXRow"].contains(role) else { return }
            // AXValue is read only for a geometry-verified header/selected-row text leaf.
            let names = role == "AXStaticText" ? [kAXValueAttribute, kAXTitleAttribute] : [kAXTitleAttribute]
            for name in names {
                if let title = CodexSessionIdentity.fullTitle(string(owner, name)) {
                    if let headerX {
                        // Toolbar actions are not chat titles; actual title text is the
                        // leftmost content-header label after the sidebar.
                        guard !["share", "more", "back", "forward", "分享", "更多", "后退", "前进"]
                            .contains(title.lowercased()) else { continue }
                        headerTitles.append((headerX, title))
                    } else { titles.insert(title) }
                    break
                }
            }
        }

        private func readHeaderPath(_ leaf: AXUIElement, window: AXUIElement, windowFrame: CGRect) {
            var node = leaf
            for _ in 0..<5 where permitted {
                guard !CFEqual(node, window), let bounds = frame(node),
                      bounds.minY >= windowFrame.minY - 2,
                      bounds.maxY <= windowFrame.minY + 64,
                      bounds.minX >= windowFrame.minX + windowFrame.width * 0.21,
                      bounds.minX <= windowFrame.minX + windowFrame.width * 0.8,
                      bounds.width < windowFrame.width * 0.75,
                      (attribute(node, "AXHidden") as? Bool) != true else { break }
                readIdentity(node, title: true, headerX: bounds.minX)
                // A title button can wrap a single AXStaticText node.
                for child in children(node, limit: 4) where permitted {
                    if string(child, kAXRoleAttribute) == "AXStaticText", let childFrame = frame(child), bounds.contains(childFrame) {
                        readIdentity(child, title: true, headerX: childFrame.minX)
                    }
                }
                guard let parent = element(node, kAXParentAttribute), !CFEqual(parent, node) else { break }
                node = parent
            }
        }

        private func scan(_ root: AXUIElement, window: AXUIElement, windowFrame: CGRect) {
            var queue: [(AXUIElement, Int)] = [(root, 0)]
            var index = 0
            while index < queue.count, visited.count < 100, permitted {
                let (node, depth) = queue[index]
                index += 1
                guard depth < 96, !visited.contains(where: { CFEqual($0, node) }) else { continue }
                visited.append(node)
                guard let role = string(node, kAXRoleAttribute), !excludedRoles.contains(role),
                      (attribute(node, "AXHidden") as? Bool) != true else { continue }
                let bounds = frame(node)
                if let bounds, bounds.maxY <= windowFrame.minY + 64,
                   bounds.minX >= windowFrame.minX + windowFrame.width * 0.21,
                   ["AXStaticText", "AXHeading", "AXButton"].contains(role) {
                    readIdentity(node, title: true, headerX: bounds.minX)
                    if !headerTitles.isEmpty { return }
                }
                let sidebar = bounds.map { $0.minX < windowFrame.minX + windowFrame.width * 0.4
                    && $0.maxX < windowFrame.minX + windowFrame.width * 0.47 && $0.intersects(windowFrame) } ?? false
                if sidebar {
                    let selected = children(node, kAXSelectedRowsAttribute, limit: 2)
                        + children(node, kAXSelectedChildrenAttribute, limit: 2)
                    for row in selected where permitted {
                        guard let rowFrame = frame(row), rowFrame.intersects(windowFrame),
                              rowFrame.maxX <= windowFrame.minX + windowFrame.width * 0.47,
                              belongs(row, to: window) else { continue }
                        readIdentity(row, title: true)
                        for child in children(row, limit: 5) where permitted {
                            if string(child, kAXRoleAttribute) == "AXStaticText" { readIdentity(child, title: true) }
                        }
                    }
                    if role == "AXRow", (attribute(node, kAXSelectedAttribute) as? Bool) == true {
                        readIdentity(node, title: true)
                        for child in children(node, limit: 5) where permitted {
                            if string(child, kAXRoleAttribute) == "AXStaticText" { readIdentity(child, title: true) }
                        }
                    }
                }
                // Do not descend into the message surface. Wrappers which span the window
                // remain traversable, including long single-child Electron ancestry chains.
                if let bounds, !CFEqual(node, window), bounds.minY > windowFrame.minY + 64, !sidebar { continue }
                if !["AXStaticText", "AXHeading", "AXButton", "AXLink"].contains(role) {
                    queue.append(contentsOf: children(node).map { ($0, depth + 1) })
                }
            }
        }

        private static func windowTitle(_ value: String) -> String? {
            var value = value
            for suffix in [" — Codex", " – Codex", " - Codex"] where value.hasSuffix(suffix) {
                value.removeLast(suffix.count)
                break
            }
            return CodexSessionIdentity.fullTitle(value)
        }
    }
}
