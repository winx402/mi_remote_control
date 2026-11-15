import Foundation

/// 遥控器会先送 PCM，再由 HID 映射确认长按；此门只缓存，不自行计时或启动听写。
/// release/cancel/overflow 后不可重放旧帧，下一次 BLE START 才能建立新物理会话。
struct RemotePCMHoldGate {
    struct Delivery {
        let token: UInt64
        let frames: [VoicePressGate.Frame]
    }
    private var physical = false
    private var token: UInt64?
    private var buffered: [VoicePressGate.Frame] = []
    private var discarded = false

    mutating func begin() {
        physical = true
        buffered.removeAll()
        discarded = false
    }

    mutating func activate(token: UInt64) -> Delivery? {
        self.token = token
        guard physical, !discarded else { return nil }
        let frames = buffered
        buffered.removeAll()
        return Delivery(token: token, frames: frames)
    }

    mutating func deactivate() {
        // A new BLE START can precede the next HID hold while the old startup
        // session is being cancelled. Its unclaimed pre-roll belongs to that new
        // physical stream, not the old recognizer being deactivated.
        guard token != nil else { return }
        token = nil
        buffered.removeAll()
        if physical { discarded = true }
    }

    mutating func receive(_ frame: VoicePressGate.Frame) -> Delivery? {
        guard physical, !discarded, frame.data.count <= 4096 else { return nil }
        if let token { return Delivery(token: token, frames: [frame]) }
        guard buffered.count < 128 else {
            discarded = true
            buffered.removeAll()
            return nil
        }
        buffered.append(frame)
        return nil
    }

    @discardableResult mutating func end() -> UInt64? {
        let old = token
        self = RemotePCMHoldGate()
        return old
    }

    static func selfCheck() -> Bool {
        var gate = RemotePCMHoldGate()
        let frame = VoicePressGate.Frame(data: Data([1]), sync: nil)
        gate.begin()
        guard gate.receive(frame) == nil, gate.end() == nil else { return false } // 短按丢弃
        gate.begin()
        guard gate.receive(frame) == nil,
              let first = gate.activate(token: 7), first.token == 7, first.frames.count == 1,
              gate.receive(frame)?.token == 7 else { return false }
        gate.deactivate()
        guard gate.receive(frame) == nil, gate.activate(token: 8) == nil else { return false }
        _ = gate.end()
        gate.begin()
        for _ in 0..<129 { _ = gate.receive(frame) }
        guard gate.activate(token: 9) == nil, gate.receive(frame) == nil else { return false }
        _ = gate.end()
        // HID 长按通知先于 BLE START 时，只允许随后本次物理会话的数据。
        guard gate.activate(token: 10) == nil else { return false }
        gate.begin()
        guard gate.receive(frame)?.token == 10, gate.end() == 10 else { return false }
        guard gate.receive(frame) == nil else { return false }
        gate.begin()
        guard gate.receive(frame) == nil else { return false }
        gate.deactivate() // Cancelling the old startup must preserve the new pre-roll.
        return gate.activate(token: 11)?.frames.count == 1 && gate.end() == 11
    }
}
