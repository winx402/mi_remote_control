import Foundation
import SQLite3

/// Desktop's metadata catalog includes already-discovered SSH and remote-control hosts.
/// Read-only access never establishes a remote connection or reads rollout/message content.
enum CodexSessionCatalog {
    struct Project: Sendable {
        let id: String
        let name: String
        let hostID: String?
        let roots: [String]
        var hostName: String? = nil
        // Deep links resolve IDs against the raw desktop local-projects map,
        // whose keys can differ from migrated app-server UUIDs.
        var localLaunchID: String? = nil
        var groupID: String { CodexSessions.Entry.key(hostID ?? "local", id) }
    }

    struct Result: Sendable {
        var entries: [CodexSessions.Entry] = []
        var projects: [Project] = []
        var sidebarProjects: [Project] = []
        var legacyIDsByServerID: [String: String] = [:]
        var assignments: [String: Assignment] = [:]
        var projectless: Set<String> = []
        var membershipHosts: [String: String] = [:]
        var hostNames: [String: String] = [:]
        var notice: String?
        var isComplete = true

        func merge(_ live: [CodexSessions.Entry]) -> [CodexSessions.Entry] {
            var combined = Dictionary(entries.map { ($0.identityKey, decorate($0)) }, uniquingKeysWith: { _, new in new })
            // The local app-server remains authoritative for a thread it returned.
            for entry in live { combined[entry.identityKey] = decorate(entry) }
            return CodexSessions.sorted(Array(combined.values))
        }

        private func decorate(_ entry: CodexSessions.Entry) -> CodexSessions.Entry {
            let assignment = assignments[entry.id].flatMap { assignment -> Assignment? in
                let host = assignment.hostID ?? (assignment.projectKind == "local" ? nil :
                    projects.first(where: { $0.id == assignment.projectId })?.hostID)
                return host == entry.hostID ? assignment : nil
            }
            let hasProjectlessOverride = projectless.contains(entry.id)
                && normalizedHost(membershipHosts[entry.id]) == entry.hostID
            let explicitID = (entry.projectID ?? assignment?.projectId).map {
                entry.hostID == nil ? legacyIDsByServerID[$0] ?? $0 : $0
            }
            var project: Project?
            if hasProjectlessOverride, assignment == nil {
                project = nil
            } else if let id = explicitID {
                project = projects.first(where: { $0.id == id && $0.hostID == entry.hostID })
            } else if let cwd = entry.cwd {
                // A separator boundary prevents /repo-other from matching /repo.
                project = projects.filter { $0.hostID == entry.hostID }.compactMap { project -> (Project, Int)? in
                    let length = project.roots.filter { Self.contains(root: $0, path: cwd) }.map(\.count).max()
                    return length.map { (project, $0) }
                }.max(by: { $0.1 < $1.1 })?.0
            } else { project = nil }
            if project == nil, !hasProjectlessOverride, entry.projectName == nil,
               let cwd = entry.cwd, let inferred = Self.directoryProject(cwd, hostID: entry.hostID) {
                project = inferred
            }
            return CodexSessions.Entry(id: entry.id, name: entry.name, updatedAt: entry.updatedAt,
                hostID: entry.hostID, hostName: entry.hostID.flatMap { hostNames[$0] } ?? entry.hostName,
                projectID: project?.id ?? (hasProjectlessOverride && assignment == nil ? nil : explicitID),
                projectName: project?.name ?? entry.projectName, cwd: entry.cwd)
        }

        fileprivate static func directoryProject(_ cwd: String, hostID: String?) -> Project? {
            guard cwd.hasPrefix("/"), cwd.count <= 4096,
                  cwd.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            var components: [String] = []
            for component in cwd.split(separator: "/") {
                if component == "." { continue }
                if component == ".." { if !components.isEmpty { components.removeLast() }; continue }
                components.append(String(component))
            }
            let path = "/" + components.joined(separator: "/")
            guard let name = components.last,
                  !["/", "/Users", "/home", "/root", "/tmp", "/private/tmp", "/var/tmp"].contains(path),
                  !(components.count == 2 && ["Users", "home"].contains(components[0])),
                  !path.hasPrefix("/tmp/"), !path.hasPrefix("/private/tmp/"), !path.hasPrefix("/var/tmp/"),
                  !path.hasPrefix("/var/folders/"), !path.hasPrefix("/private/var/folders/"),
                  !path.contains("/.codex/worktrees/"), !path.hasSuffix("/.codex/worktrees"),
                  !path.contains("/.codex/automations/") else { return nil }
            return Project(id: "cwd:" + path, name: name, hostID: hostID, roots: [path])
        }

        private func normalizedHost(_ host: String?) -> String? {
            host == "local" || host?.hasPrefix("local:") == true ? nil : host
        }

        private static func contains(root: String, path: String) -> Bool {
            guard !root.isEmpty else { return false }
            let root = root == "/" ? root : root.trimmingSuffixSlashes()
            return path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
        }
    }

    struct Assignment: Decodable, Sendable {
        let projectKind: String
        let projectId: String
        let hostID: String?
        enum CodingKeys: String, CodingKey { case projectKind, projectId; case hostID = "hostId" }
    }

    private struct Global: Decodable {
        struct Local: Decodable { let id: String; let name: String; let rootPaths: [String] }
        struct Remote: Decodable { let id: String; let hostId: String; let remotePath: String; let label: String }
        struct Host: Decodable { let hostId: String; let displayName: String? }
        let locals: [String: Local]?
        let remotes: [Remote]?
        let assignments: [String: Assignment]?
        let projectless: [String]?
        let membershipHosts: [String: String]?
        let hosts: [Host]?
        let serverIDsByLegacyIDByHost: [String: [String: String]]?
        let order: [String]?
        enum CodingKeys: String, CodingKey {
            case locals = "local-projects", remotes = "remote-projects"
            case assignments = "thread-project-assignments", projectless = "projectless-thread-ids"
            case hosts = "codex-managed-remote-connections"
            case membershipHosts = "thread-project-membership-host-ids"
            case serverIDsByLegacyIDByHost = "app-server-project-id-by-legacy-project-id-by-host"
            case order = "project-order"
        }
    }

    static var home: URL {
        ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    static func read() -> Result {
        var result = Result()
        var projectOrder: [String] = []
        var autoConnect: [String: Bool] = [:]
        var registeredHosts = Set<String>()
        var localProjectsMigrated = false
        let state = home.appendingPathComponent(".codex-global-state.json")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: state.path),
           let bytes = attributes[.size] as? NSNumber, bytes.intValue <= 32 * 1024 * 1024,
           let data = try? Data(contentsOf: state), let global = try? JSONDecoder().decode(Global.self, from: data) {
            projectOrder = global.order ?? []
            if let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Remote preferences are account scoped in current Desktop builds.
                let suffix = (raw["electron-renderer-content-owner"] as? String).map { ":" + $0 } ?? ""
                autoConnect = raw["electron-account-remote-preference:remote-connection-auto-connect-by-host-id" + suffix]
                    as? [String: Bool] ?? raw["remote-connection-auto-connect-by-host-id"] as? [String: Bool] ?? [:]
                let migrations = raw["electron-owner-value:app-server-projects-migration-by-host" + suffix]
                    as? [String: [String: Any]] ?? raw["app-server-projects-migration-by-host"] as? [String: [String: Any]] ?? [:]
                localProjectsMigrated = migrations["local:" + home.path]?["projectsMigrated"] as? Bool
                    ?? migrations["local"]?["projectsMigrated"] as? Bool ?? false
            }
            result.projects = (global.locals ?? [:]).values.sorted { $0.id < $1.id }.map {
                Project(id: $0.id, name: $0.name, hostID: nil, roots: $0.rootPaths, localLaunchID: $0.id)
            } + (global.remotes ?? []).map {
                Project(id: $0.id, name: $0.label, hostID: $0.hostId, roots: [$0.remotePath])
            }
            for (host, ids) in global.serverIDsByLegacyIDByHost ?? [:] where host == "local" || host == "local:" + home.path {
                for (legacyID, serverID) in ids { result.legacyIDsByServerID[serverID] = legacyID }
            }
            result.assignments = global.assignments ?? [:]
            result.projectless = Set(global.projectless ?? [])
            result.membershipHosts = global.membershipHosts ?? [:]
            for host in global.hosts ?? [] {
                if let name = host.displayName, !name.isEmpty { result.hostNames[host.hostId] = name }
            }
        }
        readLocalProjects(into: &result, authoritative: localProjectsMigrated)
        let database = home.appendingPathComponent("sqlite/codex.db")
        if FileManager.default.fileExists(atPath: database.path) {
            let success = withDatabase(database) { db in
                // This is the client's registered host catalog, independent of thread count.
                // Persisted remote-projects and auto-connect preferences can retain removed hosts.
                guard rows(db, sql: "SELECT host_id FROM local_thread_catalog_hosts WHERE host_kind IN ('ssh','wsl','remote-control')", visit: { statement in
                    if let host = string(statement, 0) { registeredHosts.insert(host) }
                }) else { return false }
                let sql = """
                    SELECT c.host_id,c.thread_id,c.display_title,c.source_updated_at,c.cwd,c.project_id,h.host_kind
                    FROM local_thread_catalog c JOIN local_thread_catalog_hosts h USING(host_id)
                    WHERE c.missing_candidate=0 AND h.host_kind IN ('local','ssh','wsl','remote-control')
                    AND c.source_kind IN ('appServer','cli','vscode')
                    ORDER BY c.source_updated_at DESC,c.host_id,c.thread_id LIMIT 2001
                    """
                return rows(db, sql: sql) { statement in
                    guard result.entries.count < 2000, let rawHost = string(statement, 0),
                          let id = string(statement, 1), let kind = string(statement, 6) else { return }
                    let hostID = kind == "local" ? nil : rawHost
                    guard CodexSessions.url(for: id, hostID: hostID) != nil else { return }
                    let fallback = hostID.map { host in
                        "电脑 " + String(host.suffix(8))
                    }
                    result.entries.append(CodexSessions.Entry(id: id, name: string(statement, 2),
                        updatedAt: sqlite3_column_double(statement, 3), hostID: hostID,
                        hostName: hostID.flatMap { result.hostNames[$0] } ?? fallback,
                        projectID: string(statement, 5), cwd: string(statement, 4)))
                }
            }
            if !success {
                result.isComplete = false
                result.notice = "无法完整读取桌面已同步索引；已保留可读取的会话。"
            }
            if result.entries.count >= 2000 { result.isComplete = false }
        }
        result.sidebarProjects = sidebarProjects(result.projects, order: projectOrder,
            registeredHosts: registeredHosts, autoConnect: autoConnect, hostNames: result.hostNames)
        if result.entries.contains(where: \.isRemote) {
            result.notice = [result.notice, "远程会话来自 Codex 桌面最近同步的索引；连接状态以 Codex 为准。"]
                .compactMap { $0 }.joined(separator: "\n")
        }
        if result.entries.count >= 2000 {
            result.notice = [result.notice, "已限制为最近 2000 条索引记录。"]
                .compactMap { $0 }.joined(separator: "\n")
        }
        return result
    }

    /// Desktop's Xqyo ordering prepends projects absent from project-order; it is not
    /// an allowlist. The sidebar also excludes ChatGPT backing folders and remote
    /// projects whose registered connection is disabled. No thread existence check.
    private static func sidebarProjects(_ projects: [Project], order: [String],
        registeredHosts: Set<String>, autoConnect: [String: Bool], hostNames: [String: String]) -> [Project] {
        let visible = projects.filter { project in
            if let host = project.hostID { return registeredHosts.contains(host) && autoConnect[host] != false }
            return !(project.roots.count == 1 && project.roots[0].split(whereSeparator: { $0 == "/" || $0 == "\\" })
                .dropLast().last == ".chatgpt-projects")
        }
        let visibleIDs = Set(visible.map(\.id))
        var seenIDs = Set<String>()
        let storedOrder = order.filter { visibleIDs.contains($0) && seenIDs.insert($0).inserted }
        let storedIDs = Set(storedOrder)
        let orderedIDs = visible.filter { !storedIDs.contains($0.id) }.map(\.id) + storedOrder
        let rank = Dictionary(orderedIDs.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return visible.filter { seen.insert($0.groupID).inserted }.sorted {
            rank[$0.id, default: Int.max] < rank[$1.id, default: Int.max]
        }.map { project in
            var project = project
            project.hostName = project.hostID.flatMap { hostNames[$0] }
            return project
        }
    }

    private static func readLocalProjects(into result: inout Result, authoritative: Bool) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil),
              let database = files.compactMap({ file -> (Int, URL)? in
                  let name = file.lastPathComponent
                  guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"),
                        let version = Int(name.dropFirst(6).dropLast(7)) else { return nil }
                  return (version, file)
              }).max(by: { $0.0 < $1.0 })?.1 else { return }
        _ = withDatabase(database) { db in
            var projects: [String: (String, [String])] = [:]
            var orderedIDs: [String] = []
            let success = rows(db, sql: "SELECT p.id,p.name,r.path FROM projects p LEFT JOIN project_roots r ON r.project_id=p.id ORDER BY p.position,p.id,r.position LIMIT 2000") { statement in
                guard let serverID = string(statement, 0), let name = string(statement, 1) else { return }
                let id = result.legacyIDsByServerID[serverID] ?? serverID
                if projects[id] == nil { orderedIDs.append(id) }
                var project = projects[id] ?? (name, [])
                if let root = string(statement, 2) { project.1.append(root) }
                projects[id] = project
            }
            if success {
                let ids = Set(orderedIDs)
                let remaining = result.projects.filter { $0.hostID != nil || (!authoritative && !ids.contains($0.id)) }
                result.projects = orderedIDs.compactMap { id in
                    projects[id].map { value in
                        Project(id: id, name: value.0, hostID: nil, roots: value.1,
                            localLaunchID: result.projects.first(where: { $0.id == id && $0.hostID == nil })?.localLaunchID)
                    }
                } + remaining
            }
            return success
        }
    }

    private static func withDatabase(_ url: URL, body: (OpaquePointer) -> Bool) -> Bool {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let connection else {
            if let connection { sqlite3_close(connection) }
            return false
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 120)
        var deadline = ProcessInfo.processInfo.systemUptime + 0.8
        return withUnsafeMutablePointer(to: &deadline) { pointer in
            sqlite3_progress_handler(connection, 1000, { context in
                guard let context else { return 1 }
                return ProcessInfo.processInfo.systemUptime >= context.assumingMemoryBound(to: Double.self).pointee ? 1 : 0
            }, pointer)
            defer { sqlite3_progress_handler(connection, 0, nil, nil) }
            return body(connection)
        }
    }

    private static func rows(_ db: OpaquePointer, sql: String, visit: (OpaquePointer) -> Void) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW { visit(statement); status = sqlite3_step(statement) }
        return status == SQLITE_DONE
    }

    private static func string(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_bytes(statement, column) <= 8192,
              let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    static func selfCheck() -> Bool {
        let local = CodexSessions.Entry(id: "same", name: "local", updatedAt: 1, cwd: "/repo/a")
        let remote = CodexSessions.Entry(id: "same", name: "remote", updatedAt: 2,
            hostID: "remote-control:env_example", projectID: "remote", cwd: "/repo")
        let metadata = Result(entries: [remote], projects: [
            Project(id: "local", name: "Local", hostID: nil, roots: ["/repo/"]),
            Project(id: "remote", name: "Remote", hostID: remote.hostID, roots: ["/repo"])
        ])
        let hidden = Project(id: "backing", name: "ChatGPT", hostID: nil, roots: ["/home/.codex/.chatgpt-projects/p"])
        let empty = Project(id: "empty", name: "Empty", hostID: nil, roots: ["/empty"])
        let removed = Project(id: "removed", name: "Remote", hostID: "removed-host", roots: ["/repo"])
        let disabled = Project(id: "disabled", name: "Disabled", hostID: "disabled-host", roots: ["/repo"])
        let sidebar = sidebarProjects(metadata.projects + [empty, hidden, removed, disabled],
            order: ["remote", "stale", "local", "remote"],
            registeredHosts: [remote.hostID!, "disabled-host"], autoConnect: ["disabled-host": false],
            hostNames: [remote.hostID!: "Remote computer"])
        guard sidebar.map(\.id) == ["empty", "remote", "local"],
              sidebar[1].hostName == "Remote computer",
              sidebar[1].groupID == remote.groupID else { return false }
        var migrated = metadata
        migrated.legacyIDsByServerID = ["server-local": "local"]
        let normalized = migrated.merge([CodexSessions.Entry(id: "migrated", name: nil,
            updatedAt: 1, projectID: "server-local", cwd: "/repo")])
        let remoteCollision = migrated.merge([CodexSessions.Entry(id: "collision", name: nil,
            updatedAt: 1, hostID: remote.hostID, projectID: "server-local")])
        guard normalized.first(where: { $0.id == "migrated" })?.groupID == metadata.projects[0].groupID,
              remoteCollision.first(where: { $0.id == "collision" })?.projectID == "server-local" else { return false }
        let merged = metadata.merge([local])
        let explicit = metadata.merge([CodexSessions.Entry(id: "explicit", name: nil, updatedAt: 4,
            projectID: "unavailable", cwd: "/repo/a")])
        var projectless = metadata
        projectless.projectless = ["same"]
        let withProjectless = projectless.merge([local])
        let wrongRoot = metadata.merge([CodexSessions.Entry(id: "other", name: nil, updatedAt: 3, cwd: "/repo-other")])
        return merged.count == 2 && Set(merged.map(\.identityKey)).count == 2
            && merged.first(where: { !$0.isRemote })?.projectName == "Local"
            && merged.first(where: \.isRemote)?.projectName == "Remote"
            && wrongRoot.first(where: { $0.id == "other" })?.projectID == "cwd:/repo-other"
            && explicit.first(where: { $0.id == "explicit" })?.projectID == "cwd:/repo/a"
            && explicit.first(where: { $0.id == "explicit" })?.projectName == "a"
            && withProjectless.first(where: { !$0.isRemote })?.projectID == nil
            && withProjectless.first(where: \.isRemote)?.projectName == "Remote"
            && Result.directoryProject("/projects/a/../b/", hostID: nil)?.id == "cwd:/projects/b"
            && Result.directoryProject("/Users/example", hostID: nil) == nil
            && Result.directoryProject("/", hostID: nil) == nil
            && Result.directoryProject("/private/var/folders/example", hostID: nil) == nil
            && Result.directoryProject("/Users/example/.codex/worktrees/abc/repo", hostID: nil) == nil
            && CodexSessions.url(for: "same", hostID: remote.hostID)?.query?.contains("hostId=") == true
            && CodexSessions.url(for: "same", hostID: "bad\nhost") == nil
    }
}

private extension String {
    func trimmingSuffixSlashes() -> String {
        var value = self
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}
