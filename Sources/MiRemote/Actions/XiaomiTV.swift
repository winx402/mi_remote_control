import Foundation
import Combine
@preconcurrency import Network

struct XiaomiTVConfiguration: Codable, Equatable, Sendable {
    var enabled: Bool = true
    var host: String = ""
    var port: Int = 6091

    init(enabled: Bool = true, host: String = "", port: Int = 6091) {
        self.enabled = enabled
        self.host = host
        self.port = port
    }

    private enum CodingKeys: String, CodingKey { case enabled, host, port }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        host = try values.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? 6091
    }

    var validationFailure: XiaomiTVFailure? {
        guard (1...65535).contains(port) else {
            return .invalidConfiguration("电视端口必须在 1–65535 之间。")
        }
        guard Self.isAllowedHost(host) else {
            return .invalidConfiguration("请输入局域网 IPv4 地址（10、172.16–31、192.168 或 169.254 网段）；本机测试可用 localhost。")
        }
        return nil
    }

    /// 仅接受明确的私有/链路本地 IPv4，及本机测试地址；不解析 URL、路径或公网主机名。
    private static func isAllowedHost(_ host: String) -> Bool {
        guard host.utf8.count <= 15 else { return false }
        if host.lowercased() == "localhost" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3,
                  part.utf8.allSatisfy({ (48...57).contains($0) }),
                  part.count == 1 || part.first != "0",
                  let value = UInt8(part) else { return false }
            octets.append(value)
        }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }
}

enum XiaomiTVCommand: String, CaseIterable, Sendable {
    case volumeUp
    case volumeDown
    case sleep
    case wake
    /// Open the TV's own menu with a sustained POWER press; never send POWER as a short pair.
    case powerMenu
    case up
    case down
    case left
    case right
    case ok
    case back

    fileprivate var isVolume: Bool { self == .volumeUp || self == .volumeDown }

    fileprivate var keyCode: Int32 {
        switch self {
        case .volumeUp: return 24
        case .volumeDown: return 25
        // Android KEYCODE_SLEEP is a no-op when already asleep. Never substitute POWER (26).
        case .sleep: return 223
        // KEYCODE_WAKEUP never toggles an already-awake TV back to sleep.
        case .wake: return 224
        case .powerMenu: return 26
        case .up: return 19
        case .down: return 20
        case .left: return 21
        case .right: return 22
        case .ok: return 23
        case .back: return 4
        }
    }

    fileprivate var title: String {
        switch self {
        case .volumeUp: return "电视音量增加"
        case .volumeDown: return "电视音量降低"
        case .sleep: return "电视休眠"
        case .wake: return "电视唤醒"
        case .powerMenu: return "电视电源菜单"
        case .up: return "电视向上"
        case .down: return "电视向下"
        case .left: return "电视向左"
        case .right: return "电视向右"
        case .ok: return "电视确认"
        case .back: return "电视返回"
        }
    }
}

enum XiaomiTVFailure: Error, Sendable, Equatable, LocalizedError {
    case notConfigured
    case disabled
    case invalidConfiguration(String)
    case busy
    case cancelled
    case timedOut
    case connectionFailed
    case deliveryUnconfirmed
    case invalidResponse

    var message: String {
        switch self {
        case .notConfigured: return "请先设置电视的局域网地址。"
        case .disabled: return "电视控制已停用。"
        case .invalidConfiguration(let message): return message
        case .busy: return "电视控制繁忙，请稍后再试。"
        case .cancelled: return "电视操作已取消。"
        case .timedOut: return "电视操作等待超时，请检查连接后重试。"
        case .connectionFailed: return "无法连接电视，请检查电视的局域网地址和连接。"
        case .deliveryUnconfirmed: return "未收到电视的完整确认，指令可能已生效，请查看电视；不会自动重发。"
        case .invalidResponse: return "电视响应不符合 MiLink 协议，未收到完整确认；指令可能已生效，请查看电视；不会自动重发。"
        }
    }

    var errorDescription: String? { message }
}

/// 普通按键在单次连接合并发送 DOWN/UP；电源菜单则持续发送长按帧，不重试。
/// “已送达”仅表示全部帧已发送并收到对应 MiLink ACK，不能据此推断电视已关机。
@MainActor
final class XiaomiTVController: ObservableObject {
    static let shared = XiaomiTVController()

    @Published private(set) var status = "未配置电视"

    var isConfigured: Bool {
        guard let configuration else { return false }
        return configuration.enabled && !configuration.host.isEmpty && configuration.validationFailure == nil
    }

    var isIdle: Bool { active == nil && pending.isEmpty && cancellationDepth == 0 }

    private typealias Completion = @MainActor @Sendable (Result<Void, XiaomiTVFailure>) -> Void

    private enum Operation {
        case command(XiaomiTVCommand)
        case checkConnection

        var command: XiaomiTVCommand? {
            if case .command(let command) = self { return command }
            return nil
        }
    }

    private struct Request {
        let id = UUID()
        // Bound the whole request, including queue time, so stale button presses expire.
        let deadline: ContinuousClock.Instant
        let operation: Operation
        let completion: Completion

        init(operation: Operation, completion: @escaping Completion) {
            self.operation = operation
            self.completion = completion
            deadline = ContinuousClock().now.advanced(by: XiaomiTVQueuePolicy.lifetime(for: operation.command))
        }
    }

    private final class Session {
        let request: Request
        let connection: NWConnection
        var timeout: Task<Void, Never>?
        var plan: XiaomiTVProtocol.KeyPlan?
        var sender: XiaomiTVKeySender?
        var acknowledgements: XiaomiTVProtocol.Acknowledgements?
        var sendStarted = false
        var sendCompleted = false

        init(request: Request, connection: NWConnection) {
            self.request = request
            self.connection = connection
        }

        func cancel() {
            timeout?.cancel()
            timeout = nil
            sender?.cancel()
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
    }

    private var configuration: XiaomiTVConfiguration?
    private var pending: [Request] = []
    private var active: Session?
    private var nextMessageID: UInt32 = 1
    private var cancellationDepth = 0

    private var configurationIsCurrent: (@Sendable () -> Bool)?

    func configure(_ configuration: XiaomiTVConfiguration?, isCurrent: (@Sendable () -> Bool)? = nil) {
        configurationIsCurrent = isCurrent
        guard self.configuration != configuration else { return }
        self.configuration = configuration
        let newStatus: String
        if let configuration {
            if !configuration.enabled { newStatus = "电视控制已停用" }
            else if configuration.host.isEmpty { newStatus = "未配置电视" }
            else if let failure = configuration.validationFailure { newStatus = failure.message }
            else { newStatus = "电视控制已就绪" }
        } else {
            newStatus = "未配置电视"
        }
        cancelAll(status: newStatus)
    }

    func perform(_ command: XiaomiTVCommand,
                 completion: @escaping @MainActor @Sendable (Result<Void, XiaomiTVFailure>) -> Void) {
        enqueue(.command(command), completion: completion)
    }

    func matches(_ expected: XiaomiTVConfiguration?) -> Bool {
        configuration == expected && configurationIsCurrent?() != false
    }

    func perform(_ command: XiaomiTVCommand, matching expected: XiaomiTVConfiguration?,
                 completion: @escaping @MainActor @Sendable (Result<Void, XiaomiTVFailure>) -> Void) {
        guard matches(expected) else { completion(.failure(.cancelled)); return }
        perform(command, completion: completion)
    }

    /// Cancel queued navigation before leaving the TV dialog. Never replays POWER.
    func dismissPowerMenu(matching expected: XiaomiTVConfiguration?) {
        guard matches(expected) else { return }
        let cancelled = pending.filter { request in
            guard let command = request.operation.command else { return false }
            return [.up, .down, .left, .right, .ok, .back, .volumeUp, .volumeDown].contains(command)
        }
        let ids = Set(cancelled.map(\.id))
        pending.removeAll { ids.contains($0.id) }
        cancellationDepth += 1
        cancelled.forEach { $0.completion(.failure(.cancelled)) }
        cancellationDepth -= 1
        perform(.back) { _ in }
    }

    /// 仅测试 TCP 是否可达，不发送按键，也不能据此推断电视电源状态。
    func checkConnection(completion: @escaping @MainActor @Sendable (Result<Void, XiaomiTVFailure>) -> Void) {
        enqueue(.checkConnection, completion: completion)
    }

    func stop() {
        cancelAll(status: "电视控制已停止")
    }

    private func configurationFailure() -> XiaomiTVFailure? {
        guard let configuration else { return .notConfigured }
        guard configuration.enabled else { return .disabled }
        guard !configuration.host.isEmpty else { return .notConfigured }
        return configuration.validationFailure
    }

    private func enqueue(_ operation: Operation, completion: @escaping Completion) {
        guard cancellationDepth == 0 else {
            completion(.failure(.cancelled))
            return
        }
        if let failure = configurationFailure() {
            status = failure.message
            completion(.failure(failure))
            return
        }
        let now = ContinuousClock().now
        var discarded: [(Request, XiaomiTVFailure)] = []
        pending.removeAll { request in
            if request.deadline <= now {
                discarded.append((request, .timedOut))
                return true
            }
            if XiaomiTVQueuePolicy.shouldCancelPending(request.operation.command, incoming: operation.command) {
                discarded.append((request, .cancelled))
                return true
            }
            return false
        }
        let accepted = XiaomiTVQueuePolicy.accepts(operation.command,
            pending: pending.map { $0.operation.command }, hasActive: active != nil)
        if accepted { pending.append(Request(operation: operation, completion: completion)) }
        // Detach/append before callbacks. A discarded request cannot re-enter and reorder
        // the queue, and a callback that changes configuration can cancel the new request.
        cancellationDepth += 1
        for (request, failure) in discarded { request.completion(.failure(failure)) }
        cancellationDepth -= 1
        guard accepted else {
            completion(.failure(.busy))
            return
        }
        startNextIfNeeded()
    }

    private func startNextIfNeeded() {
        guard cancellationDepth == 0, active == nil, !pending.isEmpty,
              let configuration, configurationFailure() == nil,
              let port = NWEndpoint.Port(rawValue: UInt16(configuration.port)) else { return }
        let request = pending.removeFirst()
        guard request.deadline > ContinuousClock().now else {
            status = XiaomiTVFailure.timedOut.message
            request.completion(.failure(.timedOut))
            startNextIfNeeded()
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(configuration.host), port: port, using: .tcp)
        let session = Session(request: request, connection: connection)
        active = session
        switch request.operation {
        case .command(let command):
            let ids = (0..<XiaomiTVProtocol.messageCount(for: command)).map { _ in takeMessageID() }
            guard let plan = XiaomiTVProtocol.keyPlan(command: command, messageIDs: ids) else {
                finish(request.id, result: .failure(.invalidResponse))
                return
            }
            session.plan = plan
            session.acknowledgements = .init(expectedIDs: plan.expectedIDs)
            status = "正在发送\(command.title)指令…"
        case .checkConnection:
            status = "正在检查电视 TCP 连接…"
        }
        let id = request.id
        let deadline = request.deadline
        session.timeout = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            self?.expire(id)
        }
        // Network delivers state/send/receive callbacks on the queue passed to start().
        // Keep every session transition on that main queue and the main actor.
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.handle(state, requestID: id) }
        }
        connection.start(queue: .main)
    }

    private func takeMessageID() -> UInt32 {
        let value = nextMessageID
        nextMessageID &+= 1
        if nextMessageID == 0 { nextMessageID = 1 }
        return value
    }

    private func handle(_ state: NWConnection.State, requestID: UUID) {
        guard let session = active, session.request.id == requestID else { return }
        guard session.request.deadline > ContinuousClock().now else {
            expire(requestID)
            return
        }
        switch state {
        case .ready:
            switch session.request.operation {
            case .checkConnection:
                finish(requestID, result: .success(()))
            case .command:
                guard configurationIsCurrent?() != false else {
                    finish(requestID, result: .failure(.cancelled))
                    return
                }
                guard !session.sendStarted, let plan = session.plan else { return }
                guard plan.canStart(remaining: ContinuousClock().now.duration(to: session.request.deadline)) else {
                    // In particular, never begin POWER if there is only time for a short press.
                    finish(requestID, result: .failure(.timedOut))
                    return
                }
                session.sendStarted = true
                let sender = XiaomiTVKeySender(connection: session.connection, plan: plan,
                    deadline: session.request.deadline, configurationIsCurrent: configurationIsCurrent) { [weak self] result in
                    Task { @MainActor in self?.sent(requestID: requestID, result: result) }
                }
                session.sender = sender
                sender.start()
                receive(requestID: requestID)
            }
        case .failed:
            finish(requestID, result: .failure(session.sender?.hasSentFrames == true ? .deliveryUnconfirmed : .connectionFailed))
        case .cancelled:
            finish(requestID, result: .failure(.cancelled))
        default:
            // Waiting/preparing share the same four-second total deadline.
            break
        }
    }

    private func sent(requestID: UUID, result: Result<Void, XiaomiTVFailure>) {
        guard let session = active, session.request.id == requestID else { return }
        guard session.request.deadline > ContinuousClock().now else {
            expire(requestID)
            return
        }
        if case .failure(let failure) = result {
            finish(requestID, result: .failure(failure))
            return
        }
        session.sendCompleted = true
        if session.acknowledgements?.isComplete == true {
            finish(requestID, result: .success(()))
        }
    }

    private func receive(requestID: UUID) {
        guard let session = active, session.request.id == requestID else { return }
        session.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                self?.received(data, requestID: requestID, streamComplete: isComplete, failed: error != nil)
            }
        }
    }

    private func received(_ data: Data?, requestID: UUID, streamComplete: Bool, failed: Bool) {
        guard let session = active, session.request.id == requestID else { return }
        guard session.request.deadline > ContinuousClock().now else {
            expire(requestID)
            return
        }
        if let data, !data.isEmpty {
            do { try session.acknowledgements?.consume(data) }
            catch {
                finish(requestID, result: .failure(.invalidResponse))
                return
            }
        }
        if failed {
            finish(requestID, result: .failure(.deliveryUnconfirmed))
        } else if session.acknowledgements?.isComplete == true {
            // ACKs can arrive before contentProcessed; both conditions must hold.
            if session.sendCompleted { finish(requestID, result: .success(())) }
        } else if streamComplete {
            finish(requestID, result: .failure(.deliveryUnconfirmed))
        } else {
            receive(requestID: requestID)
        }
    }

    private func expire(_ requestID: UUID) {
        guard let session = active, session.request.id == requestID else { return }
        finish(requestID, result: .failure(session.sender?.hasSentFrames == true ? .deliveryUnconfirmed : .timedOut))
    }

    private func finish(_ requestID: UUID, result: Result<Void, XiaomiTVFailure>) {
        guard let session = active, session.request.id == requestID else { return }
        active = nil
        session.cancel()
        switch result {
        case .success:
            switch session.request.operation {
            case .command(.powerMenu): status = "电视电源菜单按键序列已送达，请在电视上确认"
            case .command(let command): status = "\(command.title)指令已送达"
            case .checkConnection: status = "电视 TCP 连接可达"
            }
        case .failure(let failure): status = failure.message
        }
        session.request.completion(result)
        startNextIfNeeded()
    }

    private func cancelAll(status newStatus: String) {
        // Detach first: cancellation and completion callbacks may re-enter this controller.
        let previous = active
        active = nil
        let cancelled = pending
        pending.removeAll()
        previous?.cancel()
        status = newStatus
        cancellationDepth += 1
        previous?.request.completion(.failure(.cancelled))
        for request in cancelled { request.completion(.failure(.cancelled)) }
        cancellationDepth -= 1
    }

    /// Pure protocol/configuration checks: no controller, socket, timer, or device operation.
    nonisolated static func selfCheck() -> Bool {
        XiaomiTVProtocol.selfCheck()
    }
}

/// Pure queue decisions are shared by the controller and its offline checks.
private enum XiaomiTVQueuePolicy {
    static func lifetime(for command: XiaomiTVCommand?) -> Duration {
        command?.isVolume == true ? .milliseconds(1400) : .seconds(4)
    }

    static func shouldCancelPending(_ command: XiaomiTVCommand?, incoming: XiaomiTVCommand?) -> Bool {
        incoming == .powerMenu && command?.isVolume == true
    }

    static func accepts(_ command: XiaomiTVCommand?, pending: [XiaomiTVCommand?], hasActive: Bool) -> Bool {
        guard pending.count + (hasActive ? 1 : 0) < 8 else { return false }
        return command?.isVolume != true || !pending.contains { $0?.isVolume == true }
    }
}

/// Sending runs independently of SwiftUI/main-actor work. Network callbacks still
/// arrive on NWConnection's main delegate queue, but never gate the next repeat.
private final class XiaomiTVKeySender: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MiRemote.XiaomiTV.keySender", qos: .userInitiated)
    private let connection: NWConnection
    private let plan: XiaomiTVProtocol.KeyPlan
    private let deadline: ContinuousClock.Instant
    private let configurationIsCurrent: (@Sendable () -> Bool)?
    private let completion: @Sendable (Result<Void, XiaomiTVFailure>) -> Void
    private let stateLock = NSLock()
    // Only these two values cross queues, always under stateLock.
    private var cancelled = false
    private var sentAny = false
    // Everything below belongs to queue.
    private var workItems: [DispatchWorkItem] = []
    private var processedFrames = 0
    private var completed = false
    private var lastSentAt: ContinuousClock.Instant?

    init(connection: NWConnection, plan: XiaomiTVProtocol.KeyPlan, deadline: ContinuousClock.Instant,
         configurationIsCurrent: (@Sendable () -> Bool)?,
         completion: @escaping @Sendable (Result<Void, XiaomiTVFailure>) -> Void) {
        self.connection = connection
        self.plan = plan
        self.deadline = deadline
        self.configurationIsCurrent = configurationIsCurrent
        self.completion = completion
    }

    var hasSentFrames: Bool { stateLock.withLock { sentAny } }

    func start() {
        queue.async { [self] in
            guard !stateLock.withLock({ cancelled }) else { return }
            // Check again on this queue: waiting for a dispatch slot also spends the
            // request's four-second budget and must not turn POWER into a short press.
            guard plan.canStart(remaining: ContinuousClock().now.duration(to: deadline)) else {
                finish(.failure(.timedOut))
                return
            }
            let start = DispatchTime.now()
            for frame in plan.frames {
                let item = DispatchWorkItem { [weak self] in self?.send(frame) }
                workItems.append(item)
                queue.asyncAfter(deadline: start + .milliseconds(frame.offsetMilliseconds), execute: item)
            }
        }
    }

    func cancel() {
        // Synchronous gate: a scheduled callback cannot start another DOWN after
        // cancellation returns. Already committed sends are never replayed.
        stateLock.withLock { cancelled = true }
        queue.async { [self] in
            workItems.forEach { $0.cancel() }
            workItems.removeAll()
        }
    }

    private func send(_ frame: XiaomiTVProtocol.ScheduledFrame) {
        guard !completed, !stateLock.withLock({ cancelled }) else { return }
        guard configurationIsCurrent?() != false else {
            finish(.failure(.cancelled))
            return
        }
        let now = ContinuousClock().now
        guard lastSentAt != nil || plan.canStart(remaining: now.duration(to: deadline)) else {
            finish(.failure(.timedOut))
            return
        }
        guard now < deadline else {
            finish(.failure(hasSentFrames ? .deliveryUnconfirmed : .timedOut))
            return
        }
        // If the process/queue was suspended beyond MiLink's automatic key-release
        // window, stop instead of starting a second, unintended POWER press.
        if plan.isLongPress, let lastSentAt, lastSentAt.duration(to: now) >= .milliseconds(175) {
            finish(.failure(.deliveryUnconfirmed))
            return
        }
        stateLock.lock()
        guard !cancelled else { stateLock.unlock(); return }
        sentAny = true
        lastSentAt = now
        connection.send(content: frame.bytes, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            let failed = error != nil
            self.queue.async { [self] in self.processed(failed: failed) }
        })
        stateLock.unlock()
    }

    private func processed(failed: Bool) {
        guard !completed, !stateLock.withLock({ cancelled }) else { return }
        if failed {
            finish(.failure(.deliveryUnconfirmed))
            return
        }
        processedFrames += 1
        if processedFrames == plan.frames.count { finish(.success(())) }
    }

    private func finish(_ result: Result<Void, XiaomiTVFailure>) {
        guard !completed else { return }
        completed = true
        stateLock.withLock { cancelled = true }
        workItems.forEach { $0.cancel() }
        workItems.removeAll()
        // MainActor/UUID isolation is supplied by the controller's completion.
        // Cancellation sends no extra DOWN or POWER replay; TV automatic release
        // is the fallback if a transport failure prevents delivery of the final UP.
        completion(result)
    }
}

/// MiLink binary interoperability facts; original implementation, no third-party source.
/// https://github.com/EndLess728/MiTV-Remote (protocol description)
/// https://developer.android.com/reference/android/view/KeyEvent#KEYCODE_SLEEP
private enum XiaomiTVProtocol {
    static let powerHoldMilliseconds = 2200
    static let repeatMilliseconds = 100
    static let acknowledgementMarginMilliseconds = 500

    struct ScheduledFrame: Sendable {
        let offsetMilliseconds: Int
        let bytes: Data
    }

    struct KeyPlan: Sendable {
        let frames: [ScheduledFrame]
        let expectedIDs: Set<UInt32>
        let isLongPress: Bool

        func canStart(remaining: Duration) -> Bool {
            remaining > .zero && (!isLongPress || remaining >= .milliseconds(
                powerHoldMilliseconds + acknowledgementMarginMilliseconds))
        }
    }

    struct KeyPair {
        let bytes: Data
    }

    static func messageCount(for command: XiaomiTVCommand) -> Int {
        command == .powerMenu ? powerHoldMilliseconds / repeatMilliseconds + 1 : 2
    }

    /// POWER must only be constructed by keyPlan's sustained sequence.
    static func keyPair(command: XiaomiTVCommand, downID: UInt32, upID: UInt32) -> KeyPair? {
        guard command != .powerMenu else { return nil }
        return KeyPair(bytes: keyFrame(command: command, action: 0, id: downID)
                    + keyFrame(command: command, action: 1, id: upID))
    }

    static func keyPlan(command: XiaomiTVCommand, messageIDs: [UInt32]) -> KeyPlan? {
        guard messageIDs.count == messageCount(for: command),
              Set(messageIDs).count == messageIDs.count else { return nil }
        guard command == .powerMenu else {
            guard let pair = keyPair(command: command, downID: messageIDs[0], upID: messageIDs[1]) else { return nil }
            return KeyPlan(frames: [.init(offsetMilliseconds: 0, bytes: pair.bytes)],
                expectedIDs: Set(messageIDs), isLongPress: false)
        }
        var frames: [ScheduledFrame] = []
        for index in 0..<(messageIDs.count - 1) {
            frames.append(.init(offsetMilliseconds: index * repeatMilliseconds,
                bytes: keyFrame(command: command, action: 0, repeatCount: Int32(index), id: messageIDs[index])))
        }
        frames.append(.init(offsetMilliseconds: powerHoldMilliseconds,
            bytes: keyFrame(command: command, action: 1, id: messageIDs[messageIDs.count - 1])))
        return KeyPlan(frames: frames, expectedIDs: Set(messageIDs), isLongPress: true)
    }

    private static func keyFrame(command: XiaomiTVCommand, action: Int32, repeatCount: Int32 = 0, id: UInt32) -> Data {
        var fields = Data()
        func int32(_ tag: UInt8, _ value: Int32) {
            fields.append(tag)
            append(UInt32(bitPattern: value), to: &fields)
        }
        func int64(_ tag: UInt8, _ value: Int64) {
            fields.append(tag)
            append(UInt64(bitPattern: value), to: &fields)
        }
        int32(1, 0)       // metaState
        int32(2, action)  // 0 = DOWN, 1 = UP
        int32(3, command.keyCode)
        int32(4, 0)       // scanCode
        int32(5, repeatCount) // repeat
        int32(6, 0)       // flags
        // Zero makes the TV fill in its own uptime; a Mac clock is not Android uptime.
        int64(7, 0)       // downTime
        int64(8, 0)       // eventTime
        int32(10, -1)     // deviceId
        int32(11, 0x101)  // SOURCE_KEYBOARD
        var payload = Data([1])
        append(id, to: &payload)
        append(UInt16(fields.count), to: &payload)
        payload.append(fields)
        return frame(type: 4, payload: payload)
    }

    private static func frame(type: UInt8, payload: Data) -> Data {
        var result = Data([type])
        append(UInt16(payload.count), to: &result)
        result.append(payload)
        return result
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    struct Acknowledgements {
        static let maximumPayloadBytes = 4096
        static let maximumBufferBytes = 8192
        static let maximumTotalBytes = 32768
        static let maximumFrames = 64

        enum Failure: Error { case invalidFrame, sizeLimit, frameLimit }

        private let expectedIDs: Set<UInt32>
        private var acknowledgedIDs: Set<UInt32> = []
        private var buffer: [UInt8] = []
        private var totalBytes = 0
        private var frameCount = 0

        init(expectedIDs: Set<UInt32>) {
            self.expectedIDs = expectedIDs
        }

        var isComplete: Bool { !expectedIDs.isEmpty && acknowledgedIDs == expectedIDs }

        mutating func consume(_ data: Data) throws {
            guard data.count <= Self.maximumBufferBytes - buffer.count,
                  data.count <= Self.maximumTotalBytes - totalBytes else { throw Failure.sizeLimit }
            totalBytes += data.count
            buffer.append(contentsOf: data)
            while buffer.count >= 3 {
                let payloadLength = Int(buffer[1]) << 8 | Int(buffer[2])
                guard payloadLength <= Self.maximumPayloadBytes else { throw Failure.sizeLimit }
                guard buffer.count >= payloadLength + 3 else { return }
                frameCount += 1
                guard frameCount <= Self.maximumFrames else { throw Failure.frameLimit }
                switch buffer[0] {
                case 2: // Heartbeat frames carry no payload and never acknowledge a key.
                    guard payloadLength == 0 else { throw Failure.invalidFrame }
                case 4:
                    guard payloadLength >= 7 else { throw Failure.invalidFrame }
                    let code = buffer[3]
                    guard code == 1 || code == 2 else { throw Failure.invalidFrame }
                    let dataLength = Int(buffer[8]) << 8 | Int(buffer[9])
                    guard dataLength == payloadLength - 7 else { throw Failure.invalidFrame }
                    let id = UInt32(buffer[4]) << 24 | UInt32(buffer[5]) << 16
                        | UInt32(buffer[6]) << 8 | UInt32(buffer[7])
                    if code == 2, expectedIDs.contains(id) { acknowledgedIDs.insert(id) }
                default:
                    throw Failure.invalidFrame
                }
                buffer.removeFirst(payloadLength + 3)
            }
        }
    }

    static func selfCheck() -> Bool {
        do {
            func require(_ value: Bool) throws {
                if !value { throw Acknowledgements.Failure.invalidFrame }
            }
            func response(_ id: UInt32, code: UInt8 = 2, data: Data = Data()) -> Data {
                var payload = Data([code])
                append(id, to: &payload)
                append(UInt16(data.count), to: &payload)
                payload.append(data)
                return frame(type: 4, payload: payload)
            }
            func rejects(_ data: Data) -> Bool {
                var parser = Acknowledgements(expectedIDs: [1, 2])
                do { try parser.consume(data); return false }
                catch { return true }
            }

            let down = keyFrame(command: .sleep, action: 0, id: 0x01020304)
            let up = keyFrame(command: .sleep, action: 1, id: 0x01020305)
            // Independent golden vector, including all fixed-width tags and zero timestamps.
            let golden: [UInt8] = [
                0x04, 0x00, 0x41, 0x01, 0x01, 0x02, 0x03, 0x04, 0x00, 0x3a,
                0x01, 0, 0, 0, 0, 0x02, 0, 0, 0, 0, 0x03, 0, 0, 0, 0xdf,
                0x04, 0, 0, 0, 0, 0x05, 0, 0, 0, 0, 0x06, 0, 0, 0, 0,
                0x07, 0, 0, 0, 0, 0, 0, 0, 0, 0x08, 0, 0, 0, 0, 0, 0, 0, 0,
                0x0a, 0xff, 0xff, 0xff, 0xff, 0x0b, 0, 0, 0x01, 0x01,
            ]
            try require(down == Data(golden) && down.count == 68)
            var goldenUp = golden
            goldenUp[7] = 0x05
            goldenUp[19] = 1
            try require(up == Data(goldenUp))
            try require(keyPair(command: .sleep, downID: 0x01020304, upID: 0x01020305)?.bytes == down + up)
            try require(XiaomiTVCommand.volumeUp.keyCode == 24 && XiaomiTVCommand.volumeDown.keyCode == 25)
            try require(XiaomiTVCommand.sleep.keyCode == 223 && XiaomiTVCommand.sleep.keyCode != 26)
            var goldenWake = golden
            goldenWake[24] = 0xe0
            try require(keyFrame(command: .wake, action: 0, id: 0x01020304) == Data(goldenWake)
                && XiaomiTVCommand.wake.keyCode == 224)
            try require(XiaomiTVCommand.up.keyCode == 19 && XiaomiTVCommand.down.keyCode == 20
                && XiaomiTVCommand.left.keyCode == 21 && XiaomiTVCommand.right.keyCode == 22
                && XiaomiTVCommand.ok.keyCode == 23 && XiaomiTVCommand.back.keyCode == 4)
            try require(XiaomiTVCommand.allCases.filter { $0.keyCode == 26 } == [.powerMenu])
            try require(keyPair(command: .powerMenu, downID: 1, upID: 2) == nil)
            let powerIDs = (1...messageCount(for: .powerMenu)).map { UInt32($0) }
            guard let power = keyPlan(command: .powerMenu, messageIDs: powerIDs),
                  let ordinary = keyPlan(command: .sleep, messageIDs: [0x01020304, 0x01020305]) else { return false }
            try require(ordinary.frames.count == 1 && ordinary.frames[0].bytes == down + up
                && ordinary.expectedIDs == [0x01020304, 0x01020305] && !ordinary.isLongPress)
            try require(power.isLongPress && power.frames.count == 23 && power.expectedIDs == Set(powerIDs))
            try require(power.frames.first?.offsetMilliseconds == 0
                && power.frames.last?.offsetMilliseconds == 2200)
            try require(!power.canStart(remaining: .milliseconds(2699))
                && power.canStart(remaining: .milliseconds(2700)))
            try require(!ordinary.canStart(remaining: .zero) && ordinary.canStart(remaining: .milliseconds(1)))
            try require(keyPlan(command: .powerMenu, messageIDs: Array(powerIDs.dropLast())) == nil)
            try require(keyPlan(command: .powerMenu, messageIDs: Array(repeating: 1, count: powerIDs.count)) == nil)
            for (index, scheduled) in power.frames.enumerated() {
                // Full golden comparison also checks timestamps, flags, source/device,
                // fixed-width tags, independent IDs, and absence of field lengths.
                var expected = golden
                expected[4] = 0
                expected[5] = 0
                expected[6] = 0
                expected[7] = UInt8(index + 1)
                expected[24] = 26
                let isUp = index == power.frames.count - 1
                expected[19] = isUp ? 1 : 0
                expected[34] = isUp ? 0 : UInt8(index)
                try require(scheduled.bytes == Data(expected))
                if index > 0 {
                    try require(scheduled.offsetMilliseconds - power.frames[index - 1].offsetMilliseconds == 100)
                }
            }

            // Every long-press ID must be acknowledged, even if data is fragmented;
            // duplicate/foreign ACKs and heartbeats cannot fill a missing slot.
            var powerACKs = Acknowledgements(expectedIDs: power.expectedIDs)
            for id in powerIDs.dropLast() {
                for byte in response(id) { try powerACKs.consume(Data([byte])) }
            }
            try powerACKs.consume(response(powerIDs[0]) + response(99) + frame(type: 2, payload: Data()))
            try require(!powerACKs.isComplete)
            try powerACKs.consume(response(powerIDs[powerIDs.count - 1]))
            try require(powerACKs.isComplete)
            var reverseACKs = Acknowledgements(expectedIDs: power.expectedIDs)
            let reversed = powerIDs.reversed().reduce(into: Data()) { $0.append(response($1)) }
            try reverseACKs.consume(reversed)
            try require(reverseACKs.isComplete)
            try require(Acknowledgements.maximumFrames >= power.frames.count + 10)

            try require(XiaomiTVQueuePolicy.lifetime(for: .volumeUp) == .milliseconds(1400)
                && XiaomiTVQueuePolicy.lifetime(for: .volumeDown) == .milliseconds(1400)
                && XiaomiTVQueuePolicy.lifetime(for: .powerMenu) == .seconds(4)
                && XiaomiTVQueuePolicy.lifetime(for: nil) == .seconds(4))
            try require(XiaomiTVQueuePolicy.accepts(.volumeUp, pending: [], hasActive: true))
            try require(!XiaomiTVQueuePolicy.accepts(.volumeUp, pending: [.volumeDown], hasActive: false))
            try require(!XiaomiTVQueuePolicy.accepts(.volumeDown, pending: [.wake, .volumeUp], hasActive: true))
            try require(XiaomiTVQueuePolicy.accepts(.ok, pending: [.volumeUp], hasActive: true))
            try require(!XiaomiTVQueuePolicy.accepts(.wake, pending: Array(repeating: .wake, count: 7), hasActive: true))
            let queued: [XiaomiTVCommand?] = [.volumeUp, .back, .volumeDown, nil, .wake]
            let kept = queued.filter { !XiaomiTVQueuePolicy.shouldCancelPending($0, incoming: .powerMenu) }
            try require(kept == [.back, nil, .wake])
            try require(!XiaomiTVQueuePolicy.shouldCancelPending(.volumeUp, incoming: .ok)
                && !XiaomiTVQueuePolicy.shouldCancelPending(.ok, incoming: .powerMenu))

            var parser = Acknowledgements(expectedIDs: [1, 2])
            let unrelated = response(99) + response(1, code: 1) + frame(type: 2, payload: Data())
            try parser.consume(unrelated)
            try require(!parser.isComplete)
            let second = response(2, data: Data([0, 1]))
            for byte in second { try parser.consume(Data([byte])) }
            try parser.consume(response(2)) // A duplicate cannot replace the other ACK.
            try require(!parser.isComplete)
            let first = response(1)
            try parser.consume(first.prefix(2))
            try require(!parser.isComplete)
            try parser.consume(first.dropFirst(2))
            try require(parser.isComplete)

            var concatenated = Acknowledgements(expectedIDs: [1, 2])
            try concatenated.consume(response(2) + response(1))
            try require(concatenated.isComplete)
            try require(rejects(Data([4, 0, 6, 2, 0, 0, 0, 1, 0])))
            try require(rejects(Data([4, 0, 7, 2, 0, 0, 0, 1, 0, 1])))
            try require(rejects(Data([4, 0x10, 0x01])))
            try require(rejects(Data(repeating: 0, count: Acknowledgements.maximumBufferBytes + 1)))
            try require(rejects(frame(type: 2, payload: Data([0]))))
            try require(rejects(response(1, code: 3)))
            var frames = Acknowledgements(expectedIDs: [1, 2])
            for _ in 0..<Acknowledgements.maximumFrames { try frames.consume(Data([2, 0, 0])) }
            do { try frames.consume(Data([2, 0, 0])); return false } catch {}
            var budget = Acknowledgements(expectedIDs: [1, 2])
            let large = response(99, data: Data(repeating: 0, count: Acknowledgements.maximumPayloadBytes - 7))
            for _ in 0..<7 { try budget.consume(large) }
            do { try budget.consume(large); return false } catch {}

            let decoder = JSONDecoder()
            let defaults = try decoder.decode(XiaomiTVConfiguration.self, from: Data("{}".utf8))
            try require(defaults == XiaomiTVConfiguration())
            let partial = try decoder.decode(XiaomiTVConfiguration.self, from: Data(#"{"host":"192.168.20.30"}"#.utf8))
            try require(partial == XiaomiTVConfiguration(host: "192.168.20.30"))
            let disabled = XiaomiTVConfiguration(enabled: false, host: "localhost", port: 1234)
            try require(try decoder.decode(XiaomiTVConfiguration.self, from: JSONEncoder().encode(disabled)) == disabled)
            for host in ["10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.1.2", "169.254.2.3", "127.0.0.1", "localhost"] {
                try require(XiaomiTVConfiguration(host: host).validationFailure == nil)
            }
            for host in ["", "https://192.168.1.2", "192.168.1.2:6091", "192.168.1.2/path", "192.168.1.2\n", "192.168.1.256", "192.168.01.2", "192.168.1", "192.168..2", "::1", "172.32.0.1", "8.8.8.8", "tv.local", " 10.0.0.1", "localhost.evil"] {
                try require(XiaomiTVConfiguration(host: host).validationFailure != nil)
            }
            for port in [Int.min, -1, 0, 65536, Int.max] {
                try require(XiaomiTVConfiguration(host: "localhost", port: port).validationFailure != nil)
            }
            return true
        } catch {
            return false
        }
    }
}
