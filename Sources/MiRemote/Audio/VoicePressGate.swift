import Foundation

/// 单击聚焦与长按听写共享同一实体键；确认长按前只保留有界预录音，不启动识别。
struct VoicePressGate {
    struct Frame {
        let data: Data
        let sync: (predictor: Int16, stepIndex: Int)?
    }
    enum Delivery { case begin([Frame]), frames([Frame]) }
    private var active = false
    private var started = false
    private var startNs: UInt64 = 0
    private var delayNs: UInt64 = 0
    private var buffered: [Frame] = []

    mutating func begin(nowNs: UInt64, holdMs: Int, enabled: Bool) {
        self = VoicePressGate()
        active = enabled
        startNs = nowNs
        delayNs = UInt64(min(5000, max(0, holdMs))) * 1_000_000
    }

    mutating func receive(_ frame: Frame, nowNs: UInt64) -> Delivery? {
        guard active else { return nil }
        if started { return .frames([frame]) }
        guard buffered.count < 128, frame.data.count <= 4096 else {
            _ = end()
            return nil
        }
        buffered.append(frame)
        guard nowNs >= startNs, nowNs - startNs >= delayNs else { return nil }
        started = true
        let frames = buffered
        buffered.removeAll(keepingCapacity: false)
        return .begin(frames)
    }

    @discardableResult mutating func end() -> Bool {
        let wasStarted = started
        self = VoicePressGate()
        return wasStarted
    }

    static func selfCheck() -> Bool {
        var gate = VoicePressGate()
        let f = Frame(data: Data([1]), sync: (0, 0))
        gate.begin(nowNs: 0, holdMs: 600, enabled: true)
        guard gate.receive(f, nowNs: 100_000_000) == nil, !gate.end() else { return false }
        gate.begin(nowNs: 0, holdMs: 600, enabled: true)
        guard gate.receive(f, nowNs: 500_000_000) == nil else { return false }
        guard case .begin(let frames)? = gate.receive(f, nowNs: 610_000_000), frames.count == 2 else { return false }
        guard case .frames(let next)? = gate.receive(f, nowNs: 700_000_000), next.count == 1,
              gate.end(), gate.receive(f, nowNs: 800_000_000) == nil else { return false }
        gate.begin(nowNs: 0, holdMs: 0, enabled: false)
        return gate.receive(f, nowNs: 1_000_000_000) == nil && !gate.end()
    }
}
