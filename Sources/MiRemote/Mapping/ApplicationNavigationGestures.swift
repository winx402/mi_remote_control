import Foundation

/// A reserved left/right press may preview virtual selection immediately, but
/// native keys and scrolling must wait for committed. Cancelled never commits.
enum ApplicationNavigationReservedPhase: Equatable {
    case began, committed, cancelled
}

final class ApplicationNavigationGestures {
    private enum Phase { case down, consumed }
    private struct State {
        var phase: Phase
        var token: UInt64
        let reserved: Bool
    }
    private var states: [RemoteKey: State] = [:]
    private var serial: UInt64 = 0
    private let schedule: (Int, @escaping () -> Void) -> Void
    var onNavigate: ((RemoteKey, Bool) -> Void)?
    var onReservedDirection: ((RemoteKey, ApplicationNavigationReservedPhase) -> Void)?
    var onHold: ((RemoteKey) -> Void)?

    init(schedule: @escaping (Int, @escaping () -> Void) -> Void) { self.schedule = schedule }

    func handle(_ event: ButtonEvent, holdMs: Int? = nil) {
        let key = event.key
        if event.isDown {
            guard states[key] == nil else { return } // raw autorepeat never restarts a hold
            serial &+= 1
            let token = serial
            let reserved = (key == .left || key == .right) && holdMs != nil
            states[key] = State(phase: .down, token: token, reserved: reserved)
            guard reserved, let holdMs else { onNavigate?(key, true); return }
            onReservedDirection?(key, .began)
            schedule(max(1, holdMs)) { [weak self] in
                guard let self, var state = self.states[key],
                      state.phase == .down, state.token == token else { return }
                state.phase = .consumed
                self.states[key] = state
                self.onReservedDirection?(key, .cancelled)
                self.onHold?(key)
            }
        } else {
            guard let state = states.removeValue(forKey: key), state.phase == .down else { return }
            if state.reserved { onReservedDirection?(key, .committed) }
            else { onNavigate?(key, false) }
        }
    }

    /// A context change must not turn an already held key into another press.
    func consumeSuppressed(_ event: ButtonEvent) -> Bool {
        guard states[event.key]?.phase == .consumed else { return false }
        if !event.isDown { states.removeValue(forKey: event.key) }
        return true
    }

    func reset(preservePressed: Bool = true) {
        let held = states.filter { $0.value.phase == .down }
        serial &+= 1
        if preservePressed {
            for key in states.keys {
                states[key]?.phase = .consumed
                states[key]?.token = serial
            }
        } else { states.removeAll() }
        for (key, state) in held {
            if state.reserved { onReservedDirection?(key, .cancelled) }
            else { onNavigate?(key, false) }
        }
    }

    static func selfCheck() -> Bool {
        var pending: [() -> Void] = []
        var moves: [String] = []
        var reserved: [(RemoteKey, ApplicationNavigationReservedPhase)] = []
        var holds: [RemoteKey] = []
        let g = ApplicationNavigationGestures { _, work in pending.append(work) }
        g.onNavigate = { moves.append("\($0.rawValue)\($1 ? "+" : "-")") }
        g.onReservedDirection = { reserved.append(($0, $1)) }
        g.onHold = { holds.append($0) }
        func key(_ key: RemoteKey, _ down: Bool, _ holdMs: Int? = 650) {
            g.handle(ButtonEvent(key: key, isDown: down, timeNs: 0), holdMs: holdMs)
        }
        key(.right, true); key(.right, true); key(.right, false)
        key(.right, true); key(.right, false)
        guard reserved.map(\.1) == [.began, .committed, .began, .committed], moves.isEmpty else { return false }
        pending.forEach { $0() }; pending.removeAll()
        guard holds.isEmpty else { return false }
        reserved.removeAll()
        key(.left, true); pending.forEach { $0() }; pending.removeAll()
        key(.left, true); key(.left, false)
        guard reserved.map(\.1) == [.began, .cancelled], holds == [.left] else { return false }
        key(.up, true, nil); g.reset()
        guard moves == ["up+", "up-"] else { return false }
        key(.up, true, nil); key(.up, false, nil)
        guard moves == ["up+", "up-"] else { return false }
        key(.up, true, nil); key(.up, false, nil)
        guard moves == ["up+", "up-", "up+", "up-"] else { return false }
        reserved.removeAll()
        key(.left, true); g.reset(); pending.forEach { $0() }
        key(.left, false)
        return reserved.map(\.1) == [.began, .cancelled] && holds == [.left]
    }
}
