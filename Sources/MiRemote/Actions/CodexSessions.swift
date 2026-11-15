import AppKit
import Darwin
import os

/// 只读本地及桌面已同步的远程会话元数据；不恢复会话，也不向模型发送请求。
@MainActor
final class CodexSessions {
    struct Entry: Identifiable, Decodable, Sendable, Equatable {
        let id: String
        let name: String?
        let updatedAt: Double
        let hostID: String?
        let hostName: String?
        let projectID: String?
        let projectName: String?
        let cwd: String?

        var isRemote: Bool { hostID != nil }
        var identityKey: String { Self.key(hostID ?? "local", id) }
        var groupID: String { Self.key(hostID ?? "local", projectID ?? "") }
        var groupTitle: String { projectName ?? "未分组" }
        var hostTitle: String { hostName ?? (isRemote ? "远程电脑" : "本机") }
        private static func key(_ host: String, _ item: String) -> String {
            "\(host.utf8.count):\(host)\(item)"
        }

        var title: String {
            let normalized = name?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
            return normalized.isEmpty ? "未命名会话" : String(normalized.prefix(180))
        }

        private enum CodingKeys: String, CodingKey { case id, name, updatedAt, cwd, projectID = "projectId" }

        init(id: String, name: String?, updatedAt: Double, hostID: String? = nil,
             hostName: String? = nil, projectID: String? = nil, projectName: String? = nil,
             cwd: String? = nil) {
            self.id = id
            self.name = name
            self.updatedAt = updatedAt
            self.hostID = hostID
            self.hostName = hostName
            self.projectID = projectID
            self.projectName = projectName
            self.cwd = cwd
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            name = try values.decodeIfPresent(String.self, forKey: .name)
            updatedAt = try values.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
            hostID = nil
            hostName = nil
            projectID = try values.decodeIfPresent(String.self, forKey: .projectID)
            projectName = nil
            cwd = try values.decodeIfPresent(String.self, forKey: .cwd)
        }
    }

    struct Snapshot: Sendable {
        var entries: [Entry] = []
        var currentID: String?
        var currentIdentityKey: String?
        var isLoading = false
        var notice: String?
        var error: String?

        func selection(after previous: Snapshot, index: Int, userMoved: Bool) -> Int {
            let prior = previous.entries.indices.contains(index) ? previous.entries[index].identityKey : nil
            let anchor = userMoved ? prior : currentIdentityKey ?? currentID.flatMap { id in
                let matches = entries.filter { $0.id == id }; return matches.count == 1 ? matches[0].identityKey : nil
            } ?? prior
            if let anchor, let found = entries.firstIndex(where: { $0.identityKey == anchor }) { return found }
            return min(max(index, 0), max(0, entries.count - 1))
        }
    }

    /// 两级代次检查挡住「关闭后回调」和「快速重开后旧回调覆盖新列表」。
    private struct Generation {
        private(set) var value: UInt64 = 0
        mutating func advance() -> UInt64 { value &+= 1; return value }
        func accepts(_ token: UInt64) -> Bool { value == token }
    }

    private struct Page: Decodable {
        let data: [Entry]
        let nextCursor: String?
    }

    private static let trace = Logger(subsystem: "com.miremote.controller", category: "CodexSessionAnchor")
    private var generation = Generation()
    private var worker: Worker?

    deinit { worker?.cancel() }

    @MainActor private final class LoadState {
        var latest = Snapshot(isLoading: true)
        var indexed: Entry?
        var desktop = CodexSessionCatalog.Result()
        var catalogLoading = true
    }

    func load(identity: CodexSessionIdentity?, onUpdate: @escaping @MainActor @Sendable (Snapshot) -> Void) {
        cancel()
        let token = generation.value
        let state = LoadState()
        let publish: @MainActor () -> Void = { [weak self] in
            guard self?.generation.accepts(token) == true else { return }
            var result = state.latest
            if let indexed = state.indexed,
               !result.entries.contains(where: { $0.identityKey == indexed.identityKey }) {
                result.entries.append(indexed)
            }
            result.entries = state.desktop.merge(result.entries)
            result.isLoading = result.isLoading || state.catalogLoading
            result.currentIdentityKey = identity?.resolveIdentityKey(in: result.entries,
                complete: !result.isLoading && result.notice == nil && result.error == nil && state.desktop.isComplete)
            result.currentID = result.currentIdentityKey.flatMap { key in
                result.entries.first(where: { $0.identityKey == key })?.id
            }
            if let notice = state.desktop.notice {
                result.notice = [result.notice, notice].compactMap { $0 }.joined(separator: "\n")
            }
            if !result.isLoading { Self.trace.notice("identity=\(identity != nil) match=\(result.currentID != nil)") }
            onUpdate(result)
        }
        Task {
            let desktop = await Task.detached(priority: .userInitiated) { CodexSessionCatalog.read() }.value
            guard generation.accepts(token) else { return }
            state.desktop = desktop
            state.catalogLoading = false
            publish()
        }
        if let identity {
            Task {
                let match = await Task.detached(priority: .userInitiated) { identity.lookupInIndex() }.value
                guard generation.accepts(token), let match else { return }
                state.indexed = match
                publish()
            }
        }
        let next = Worker { snapshot in
            DispatchQueue.main.async {
                state.latest = snapshot
                publish()
            }
        }
        worker = next
        next.start()
    }

    func cancel() {
        _ = generation.advance()
        worker?.cancel()
        worker = nil
    }

    nonisolated static func url(for id: String, hostID: String? = nil) -> URL? {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              id.count <= 512,
              id.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        // thread ID 是单一路径段，必须编码斜杠、百分号和 URL 分隔符。
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        guard var components = URLComponents(string: "codex://threads/" + encoded) else { return nil }
        if let hostID {
            guard !hostID.isEmpty, hostID.count <= 512,
                  hostID.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            components.queryItems = [URLQueryItem(name: "hostId", value: hostID)]
        }
        return components.url
    }

    @discardableResult
    static func open(_ entry: Entry) -> Bool {
        guard let url = url(for: entry.id, hostID: entry.hostID) else { return false }
        return NSWorkspace.shared.open(url)
    }

    nonisolated static func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted {
            $0.updatedAt == $1.updatedAt ? $0.identityKey < $1.identityKey : $0.updatedAt > $1.updatedAt
        }
    }

    /// 夹到列表边界；左右按一屏跳转时也不会跳过首尾。
    nonisolated static func movedIndex(_ index: Int, delta: Int, count: Int) -> Int {
        count > 0 ? min(max(index + delta, 0), count - 1) : 0
    }

    /// 子服务提前退出时让写入抛出 EPIPE，而不是用 SIGPIPE 终止整个遥控器应用。
    nonisolated private static func protectPipeWrites(_ handle: FileHandle) -> Bool {
        fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) == 0
    }

    nonisolated static func selfCheck() -> Bool {
        let fixture = #"{"data":[{"id":"older","name":"  第一个\n会话  ","updatedAt":1,"preview":"PRIVATE PREVIEW","cwd":"/private/example"},{"id":"newer","name":null,"updatedAt":3},{"id":"same-time","name":"   ","updatedAt":3}],"nextCursor":"next-page"}"#
        guard CodexSessionIdentity.selfCheck(), CodexSessionCatalog.selfCheck() else { return false }
        guard let page = try? JSONDecoder().decode(Page.self, from: Data(fixture.utf8)),
              page.data.count == 3, page.nextCursor == "next-page",
              page.data[0].title == "第一个 会话",
              page.data[1].title == "未命名会话", page.data[2].title == "未命名会话",
              sorted(page.data).map(\.id) == ["newer", "same-time", "older"],
              url(for: "a/b?c#d%")?.absoluteString == "codex://threads/a%2Fb%3Fc%23d%25",
              url(for: "") == nil, url(for: "bad\nid") == nil,
              movedIndex(0, delta: -1, count: 3) == 0,
              movedIndex(1, delta: 8, count: 3) == 2,
              movedIndex(0, delta: 1, count: 0) == 0 else { return false }
        let previous = Snapshot(entries: [page.data[0]])
        let loaded = Snapshot(entries: [page.data[2], page.data[0], page.data[1]], currentID: page.data[1].id)
        guard loaded.selection(after: previous, index: 0, userMoved: false) == 2,
              loaded.selection(after: previous, index: 0, userMoved: true) == 1 else { return false }
        var generation = Generation()
        let first = generation.advance()
        guard generation.accepts(first) else { return false }
        let reopened = generation.advance()
        guard !generation.accepts(first) && generation.accepts(reopened) else { return false }
        // 精确复现服务已关闭 stdin：测试只操作独立匿名管道，不启动任何会话。
        let pipe = Pipe()
        guard protectPipeWrites(pipe.fileHandleForWriting) else { return false }
        defer { try? pipe.fileHandleForWriting.close() }
        do {
            try pipe.fileHandleForReading.close()
            try pipe.fileHandleForWriting.write(contentsOf: Data([0x0A]))
            return false
        } catch {
            return true
        }
    }

    /// 所有 Process / pipe 状态只在同一串行队列读写；主线程只接收轻量快照。
    private final class Worker: @unchecked Sendable {
        private struct Header: Decodable {
            struct RPCError: Decodable { let code: Int }
            let id: Int?
            let error: RPCError?
        }
        private struct InitializeReply: Decodable {
            struct Result: Decodable {}
            let result: Result
        }
        private struct PageReply: Decodable { let result: Page }

        private let queue = DispatchQueue(label: "com.miremote.codex-sessions", qos: .userInitiated)
        private let onUpdate: @Sendable (Snapshot) -> Void
        private var process: Process?
        private var input: FileHandle?
        private var output: FileHandle?
        private var readSource: DispatchSourceRead?
        private var buffer = Data()
        private var receivedBytes = 0
        private var completed = false
        private var expectedID = 1
        private var pageCount = 0
        private var cursors = Set<String>()
        private var entries: [String: Entry] = [:]
        private static let maxEntries = 500
        private static let maxPages = 20
        private static let maxOutputBytes = 4 * 1024 * 1024

        init(onUpdate: @escaping @Sendable (Snapshot) -> Void) { self.onUpdate = onUpdate }

        func start() { queue.async { self.launch() } }
        func cancel() { queue.async { self.cleanup() } }

        private static func executable() -> URL? {
            // GUI 进程的 PATH 常缺 Homebrew；仅解析可执行文件，不启动 shell。
            let paths = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
                + (ProcessInfo.processInfo.environment["PATH"] ?? "")
                    .split(separator: ":").map { String($0) + "/codex" }
            return paths.first(where: FileManager.default.isExecutableFile(atPath:))
                .map { URL(fileURLWithPath: $0) }
        }

        private func launch() {
            guard !completed else { return }
            guard let executable = Self.executable() else {
                fail("找不到 Codex CLI。安装后重新打开会话列表。")
                return
            }
            let task = Process()
            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            task.executableURL = executable
            task.arguments = ["app-server", "-c", "analytics.enabled=false"]
            task.standardInput = stdinPipe
            task.standardOutput = stdoutPipe
            // app-server 错误可能含本地路径或会话信息，不转发到日志或界面。
            task.standardError = FileHandle.nullDevice
            input = stdinPipe.fileHandleForWriting
            output = stdoutPipe.fileHandleForReading
            process = task
            guard CodexSessions.protectPipeWrites(stdinPipe.fileHandleForWriting) else {
                fail("无法安全连接 Codex 会话服务，请重新打开列表。")
                return
            }
            let reader = stdoutPipe.fileHandleForReading
            let source = DispatchSource.makeReadSource(fileDescriptor: reader.fileDescriptor,
                                                       queue: queue)
            source.setEventHandler { [weak self] in self?.readOutput() }
            // 等 dispatch 注销 fd 后再关闭，防止快速重开时复用的 fd 被旧 source 误读。
            source.setCancelHandler { try? reader.close() }
            readSource = source
            source.resume()
            task.terminationHandler = { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    guard !self.completed else { return }
                    self.fail("Codex 会话服务已停止，请重新打开列表。")
                }
            }
            do {
                try task.run()
                try send(["id": 1, "method": "initialize", "params": [
                    "clientInfo": ["name": "miremote_sessions", "title": "MiRemote Session Picker", "version": "0.1.0"]
                ]])
            } catch {
                fail("无法启动 Codex 会话服务，请检查 CLI 安装。")
                return
            }
            // 总读取时限覆盖握手和全部分页，取消不必等超时。
            queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, !self.completed else { return }
                self.fail("读取 Codex 会话超时，请重新打开列表重试。")
            }
        }

        private func send(_ message: [String: Any]) throws {
            var line = try JSONSerialization.data(withJSONObject: message)
            line.append(0x0A)
            guard let input else { throw CocoaError(.fileWriteUnknown) }
            try input.write(contentsOf: line)
        }

        private func list(cursor: String?) throws {
            var params: [String: Any] = [
                "limit": 50, "sortKey": "updated_at", "sortDirection": "desc",
                "archived": false, "useStateDbOnly": true,
                "sourceKinds": ["appServer", "cli", "vscode"]
            ]
            if let cursor { params["cursor"] = cursor }
            expectedID += 1
            try send(["id": expectedID, "method": "thread/list", "params": params])
        }

        private func receive(_ chunk: Data) {
            guard !completed else { return }
            guard !chunk.isEmpty else {
                fail("Codex 会话服务已断开，请重新打开列表。")
                return
            }
            receivedBytes += chunk.count
            guard receivedBytes <= Self.maxOutputBytes else {
                fail("Codex 返回的数据过多，请在 Codex 中查看其余会话。")
                return
            }
            buffer.append(chunk)
            while !completed, let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                if !line.isEmpty { receiveLine(line) }
            }
        }

        private func readOutput() {
            guard !completed, let output else { return }
            do {
                // 读取和解析共用队列，避免高速 stdout 在回调队列积压无界 Data。
                let available = min(Int(readSource?.data ?? 0), 64 * 1024)
                let chunk = try output.read(upToCount: max(1, available)) ?? Data()
                receive(chunk)
            } catch {
                fail("无法读取 Codex 会话服务的响应，请重新打开列表。")
            }
        }

        private func receiveLine(_ line: Data) {
            let decoder = JSONDecoder()
            do {
                let header = try decoder.decode(Header.self, from: line)
                // 通知与非本次响应不影响只读列表请求。
                guard header.id == expectedID else { return }
                guard header.error == nil else {
                    fail("Codex 无法读取会话列表，请更新 CLI 或稍后重试。")
                    return
                }
                if expectedID == 1 {
                    _ = try decoder.decode(InitializeReply.self, from: line)
                    try send(["method": "initialized"])
                    try list(cursor: nil)
                    return
                }
                let page = try decoder.decode(PageReply.self, from: line).result
                pageCount += 1
                var omitted = false
                for entry in page.data where CodexSessions.url(for: entry.id) != nil {
                    if entries[entry.id] != nil || entries.count < Self.maxEntries {
                        entries[entry.id] = entry
                    } else {
                        omitted = true
                    }
                }
                let cursor = page.nextCursor.flatMap { $0.isEmpty ? nil : $0 }
                let more = cursor != nil
                if omitted || (more && (entries.count >= Self.maxEntries || pageCount >= Self.maxPages)) {
                    publish(loading: false, notice: "已显示最近 \(entries.count) 个会话；其余会话请在 Codex 中查看。")
                    cleanup()
                } else if let cursor {
                    guard cursors.insert(cursor).inserted else {
                        fail("Codex 分页未继续，已保留读取到的会话。请重新打开列表。")
                        return
                    }
                    publish(loading: true)
                    try list(cursor: cursor)
                } else {
                    publish(loading: false)
                    cleanup()
                }
            } catch {
                fail("Codex 返回的数据格式无法识别，请更新 CLI 后重试。")
            }
        }

        private func publish(loading: Bool, notice: String? = nil, error: String? = nil) {
            onUpdate(Snapshot(entries: CodexSessions.sorted(Array(entries.values)),
                              isLoading: loading, notice: notice, error: error))
        }

        private func fail(_ message: String) {
            guard !completed else { return }
            publish(loading: false, error: message)
            cleanup()
        }

        private func cleanup() {
            guard !completed else { return }
            completed = true
            readSource?.cancel()
            readSource = nil
            try? input?.close()
            output = nil
            input = nil
            buffer.removeAll(keepingCapacity: false)
            entries.removeAll(keepingCapacity: false)
            guard let task = process else { return }
            process = nil
            task.terminationHandler = nil
            if task.isRunning {
                task.terminate()
                queue.asyncAfter(deadline: .now() + 0.5) {
                    if task.isRunning { kill(task.processIdentifier, SIGKILL) }
                }
            }
        }
    }
}
