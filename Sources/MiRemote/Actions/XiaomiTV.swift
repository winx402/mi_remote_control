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

enum XiaomiTVCommand: String, Sendable {
    case volumeUp
    case volumeDown
    case sleep

    fileprivate var keyCode: Int32 {
        switch self {
        case .volumeUp: return 24
        case .volumeDown: return 25
        // Android KEYCODE_SLEEP is a no-op when already asleep. Never substitute POWER (26).
        case .sleep: return 223
        }
    }

    fileprivate var title: String {
        switch self {
        case .volumeUp: return "电视音量增加"
        case .volumeDown: return "电视音量降低"
        case .sleep: return "电视休眠"
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

/// 单次连接发送一对 DOWN/UP，不重试；“已送达”仅表示收到对应的两条 MiLink ACK。
@MainActor
final class XiaomiTVController: ObservableObject {
    static let shared = XiaomiTVController()

    @Published private(set) var status = "未配置电视"

    var isConfigured: Bool {
        guard let configuration else { return false }
        return configuration.enabled && !configuration.host.isEmpty && configuration.validationFailure == nil
    }

    private typealias Completion = @MainActor @Sendable (Result<Void, XiaomiTVFailure>) -> Void

    private enum Operation {
        case command(XiaomiTVCommand)
        case checkConnection
    }

    private struct Request {
        let id = UUID()
        // Bound the whole request, including queue time, so stale button presses expire.
        let deadline = ContinuousClock().now.advanced(by: .seconds(4))
        let operation: Operation
        let completion: Completion
    }

    private final class Session {
        let request: Request
        let connection: NWConnection
        var timeout: Task<Void, Never>?
        var packet: XiaomiTVProtocol.KeyPair?
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
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
    }

    private var configuration: XiaomiTVConfiguration?
    private var pending: [Request] = []
    private var active: Session?
    private var nextMessageID: UInt32 = 1
    private var cancellationDepth = 0
    private let maximumRequests = 8

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
        guard pending.count + (active == nil ? 0 : 1) < maximumRequests else {
            completion(.failure(.busy))
            return
        }
        pending.append(Request(operation: operation, completion: completion))
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
            let downID = takeMessageID()
            let upID = takeMessageID()
            let packet = XiaomiTVProtocol.keyPair(command: command, downID: downID, upID: upID)
            session.packet = packet
            session.acknowledgements = .init(expectedIDs: [downID, upID])
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
                guard !session.sendStarted, let packet = session.packet else { return }
                session.sendStarted = true
                // A single send contains the whole pair, preserving order and avoiding a
                // later attempt to synthesize UP after an ambiguous transport failure.
                session.connection.send(content: packet.bytes, completion: .contentProcessed { [weak self] error in
                    MainActor.assumeIsolated {
                        self?.sent(requestID: requestID, failed: error != nil)
                    }
                })
                receive(requestID: requestID)
            }
        case .failed:
            finish(requestID, result: .failure(session.sendStarted ? .deliveryUnconfirmed : .connectionFailed))
        case .cancelled:
            finish(requestID, result: .failure(.cancelled))
        default:
            // Waiting/preparing share the same four-second total deadline.
            break
        }
    }

    private func sent(requestID: UUID, failed: Bool) {
        guard let session = active, session.request.id == requestID else { return }
        guard session.request.deadline > ContinuousClock().now else {
            expire(requestID)
            return
        }
        if failed {
            finish(requestID, result: .failure(.deliveryUnconfirmed))
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
        finish(requestID, result: .failure(session.sendStarted ? .deliveryUnconfirmed : .timedOut))
    }

    private func finish(_ requestID: UUID, result: Result<Void, XiaomiTVFailure>) {
        guard let session = active, session.request.id == requestID else { return }
        active = nil
        session.cancel()
        switch result {
        case .success:
            switch session.request.operation {
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

/// MiLink binary interoperability facts; original implementation, no third-party source.
/// https://github.com/EndLess728/MiTV-Remote (protocol description)
/// https://developer.android.com/reference/android/view/KeyEvent#KEYCODE_SLEEP
private enum XiaomiTVProtocol {
    struct KeyPair {
        let bytes: Data
    }

    static func keyPair(command: XiaomiTVCommand, downID: UInt32, upID: UInt32) -> KeyPair {
        KeyPair(bytes: keyFrame(command: command, action: 0, id: downID)
                    + keyFrame(command: command, action: 1, id: upID))
    }

    private static func keyFrame(command: XiaomiTVCommand, action: Int32, id: UInt32) -> Data {
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
        int32(5, 0)       // repeat
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
            try require(keyPair(command: .sleep, downID: 0x01020304, upID: 0x01020305).bytes == down + up)
            try require(XiaomiTVCommand.volumeUp.keyCode == 24 && XiaomiTVCommand.volumeDown.keyCode == 25)
            try require(XiaomiTVCommand.sleep.keyCode == 223 && XiaomiTVCommand.sleep.keyCode != 26)

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
