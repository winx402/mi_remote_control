import Foundation

/// PCM never waits on AX. A monitor supplies evidence; uncertain evidence holds
/// a bounded tail locally until the original context is positively verified.
struct RemoteDictationContextGuard {
    enum Observation: Equatable {
        case matched
        case unavailable(String)
        case changed(String)
    }
    enum Decision: Equatable {
        case allow
        case quarantine
        case cancel(String)
    }
    enum Reception: Equatable {
        case deliver([Int16])
        case buffered
        case cancel(String)
    }
    static let evidenceLifetime: TimeInterval = 0.25
    static let uncertaintyLimit: TimeInterval = 0.5
    // A cold-start backlog may arrive as one batch. The time deadline still
    // bounds uncertainty; preserve the startup gate's full batch plus live tail.
    static let maximumSamples = RemotePCMStartupGate.maximumSamples + 8_000
    private var checkedAt: TimeInterval?
    private var uncertainSince: TimeInterval?
    private var observation: Observation = .unavailable("context-not-checked")
    private var pending: [Int16] = []

    static func isTransientWindowPlaceholder(role: String?, originalWindowMatches: Bool) -> Bool {
        originalWindowMatches && (role == "AXWindow" || role == "AXWebArea")
    }

    /// Contradictory positive evidence always wins over an unavailable AX read.
    static func combined(_ values: [Observation]) -> Observation {
        if let changed = values.first(where: { if case .changed = $0 { true } else { false } }) { return changed }
        return values.first(where: { if case .unavailable = $0 { true } else { false } }) ?? .matched
    }

    mutating func observe(_ value: Observation, now: TimeInterval) -> Decision {
        if case .changed(let reason) = observation { return .cancel(reason) }
        observation = value
        checkedAt = now
        switch value {
        case .matched: uncertainSince = nil
        case .unavailable: if uncertainSince == nil { uncertainSince = now }
        case .changed: pending.removeAll()
        }
        return decision(now: now)
    }

    func needsRefresh(now: TimeInterval) -> Bool {
        checkedAt.map { now - $0 > Self.evidenceLifetime } ?? true
    }

    mutating func decision(now: TimeInterval) -> Decision {
        switch observation {
        case .changed(let reason): return .cancel(reason)
        case .matched:
            if let checkedAt, now - checkedAt <= Self.evidenceLifetime { return .allow }
            observation = .unavailable("context-monitor-stale")
            uncertainSince = checkedAt.map { $0 + Self.evidenceLifetime } ?? now
        case .unavailable:
            if uncertainSince == nil { uncertainSince = now }
        }
        if let uncertainSince, now - uncertainSince >= Self.uncertaintyLimit {
            pending.removeAll()
            if case .unavailable(let reason) = observation { return .cancel("context-unavailable:\(reason)") }
        }
        return .quarantine
    }

    mutating func receive(_ samples: [Int16], now: TimeInterval) -> Reception {
        switch decision(now: now) {
        case .allow:
            guard !pending.isEmpty else { return .deliver(samples) }
            let result = pending + samples
            pending.removeAll(keepingCapacity: true)
            return .deliver(result)
        case .quarantine:
            guard samples.count <= Self.maximumSamples - pending.count else {
                pending.removeAll()
                observation = .changed("context-quarantine-overflow")
                return .cancel("context-quarantine-overflow")
            }
            pending.append(contentsOf: samples)
            return .buffered
        case .cancel(let reason): return .cancel(reason)
        }
    }

    static func selfCheck() -> Bool {
        var gate = Self()
        guard gate.observe(.matched, now: 0) == .allow,
              gate.receive([1], now: 0.01) == .deliver([1]),
              gate.observe(.unavailable("ax-focus"), now: 0.1) == .quarantine,
              gate.receive([2, 3], now: 0.11) == .buffered,
              gate.observe(.matched, now: 0.2) == .allow,
              gate.receive([4], now: 0.21) == .deliver([2, 3, 4]),
              gate.receive([], now: 0.22) == .deliver([]) else { return false }
        // STOP while quarantined: the empty flush releases the tail only after
        // positive verification. A real switch instead permanently drops it.
        guard gate.observe(.unavailable("ax-window"), now: 0.3) == .quarantine,
              gate.receive([5], now: 0.31) == .buffered,
              gate.observe(.matched, now: 0.4) == .allow,
              gate.receive([], now: 0.4) == .deliver([5]),
              gate.observe(.unavailable("ax-focus"), now: 0.5) == .quarantine,
              gate.receive([6], now: 0.51) == .buffered,
              gate.observe(.changed("focus"), now: 0.6) == .cancel("focus"),
              gate.receive([7], now: 0.61) == .cancel("focus"),
              gate.observe(.matched, now: 0.62) == .cancel("focus") else { return false }
        gate = Self()
        guard gate.observe(.unavailable("ax"), now: 0) == .quarantine,
              gate.receive([8], now: 0.1) == .buffered,
              gate.decision(now: 0.5) == .cancel("context-unavailable:ax") else { return false }
        gate = Self()
        guard gate.observe(.matched, now: 0) == .allow,
              gate.receive([9], now: 0.3) == .buffered,
              gate.decision(now: 0.75) == .cancel("context-unavailable:context-monitor-stale") else { return false }
        gate = Self()
        guard gate.receive([Int16](repeating: 1, count: maximumSamples), now: 0) == .buffered,
              gate.receive([1], now: 0) == .cancel("context-quarantine-overflow") else { return false }
        // Preserve a complete cold-start utterance if AX is briefly unavailable
        // exactly when startup hands its large batch to the live path.
        gate = Self()
        let cold = [Int16](repeating: 12, count: RemotePCMStartupGate.maximumSamples)
        guard gate.receive(cold, now: 0) == .buffered,
              gate.observe(.matched, now: 0.1) == .allow,
              gate.receive([13], now: 0.11) == .deliver(cold + [13]) else { return false }
        for issue in ["frontmost-application", "app-focused-element", "app-focused-window", "input-source", "default-input-device"] {
            gate = Self()
            guard gate.observe(.unavailable("ax"), now: 0) == .quarantine,
                  gate.receive([1], now: 0) == .buffered,
                  gate.observe(.changed(issue), now: 0.01) == .cancel(issue),
                  gate.receive([], now: 0.02) == .cancel(issue) else { return false }
        }
        gate = Self()
        guard gate.needsRefresh(now: 0), gate.observe(.matched, now: 0) == .allow,
              !gate.needsRefresh(now: 0.2), gate.needsRefresh(now: 2),
              gate.observe(.matched, now: 2) == .allow,
              gate.receive([14], now: 2.01) == .deliver([14]) else { return false }
        return isTransientWindowPlaceholder(role: "AXWindow", originalWindowMatches: true)
            && isTransientWindowPlaceholder(role: "AXWebArea", originalWindowMatches: true)
            && !isTransientWindowPlaceholder(role: "AXWebArea", originalWindowMatches: false)
            && !isTransientWindowPlaceholder(role: "AXTextArea", originalWindowMatches: true)
            && !isTransientWindowPlaceholder(role: "AXTextField", originalWindowMatches: true)
            && !isTransientWindowPlaceholder(role: nil, originalWindowMatches: true)
            && combined([.unavailable("ax"), .changed("input-source")]) == .changed("input-source")
            && combined([.matched, .unavailable("ax")]) == .unavailable("ax")

    }
}
