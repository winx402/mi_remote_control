import Foundation

/// Confirmed holds own their PCM before the input method is ready. A transport
/// STOP closes capture, but preserves the bounded backlog until startup succeeds.
struct RemotePCMStartupGate {
    enum Reception { case buffered, deliver, overflow, ended }
    static let maximumSamples = 160_000 // 10 seconds at the remote's 16kHz rate.
    private(set) var isReady = false
    private var ended = false
    private var buffered: [Int16] = []

    mutating func receive(_ samples: [Int16]) -> Reception {
        guard !ended else { return .ended }
        if isReady { return .deliver }
        guard samples.count <= Self.maximumSamples - buffered.count else {
            buffered.removeAll()
            ended = true
            return .overflow
        }
        buffered.append(contentsOf: samples)
        return .buffered
    }

    mutating func markReady() -> (samples: [Int16], transportEnded: Bool) {
        isReady = true
        let samples = buffered
        buffered.removeAll()
        return (samples, ended)
    }

    /// Returns whether startup has completed and the caller can finish now.
    @discardableResult mutating func end() -> Bool {
        ended = true
        return isReady
    }

    static func selfCheck() -> Bool {
        var gate = RemotePCMStartupGate()
        // Cold startup: a complete 2.825s utterance survives STOP before ready.
        let utterance = [Int16](repeating: 123, count: 45_200)
        guard gate.receive(utterance) == .buffered, !gate.end(),
              gate.receive([9]) == .ended else { return false }
        let cold = gate.markReady()
        guard cold.samples == utterance, cold.transportEnded,
              gate.markReady().samples.isEmpty else { return false }
        // A cancelled/retried session gets fresh state; old audio never reappears.
        gate = RemotePCMStartupGate()
        guard gate.receive([1, 2]) == .buffered else { return false }
        let warm = gate.markReady()
        guard warm.samples == [1, 2], !warm.transportEnded,
              gate.receive([3]) == .deliver, gate.end(),
              gate.receive([4]) == .ended else { return false }
        gate = RemotePCMStartupGate()
        guard gate.receive([Int16](repeating: 0, count: maximumSamples)) == .buffered,
              gate.receive([1]) == .overflow,
              gate.receive([2]) == .ended, gate.markReady().samples.isEmpty else { return false }
        gate = RemotePCMStartupGate()
        return gate.receive([5]) == .buffered && gate.markReady().samples == [5]
    }
}
