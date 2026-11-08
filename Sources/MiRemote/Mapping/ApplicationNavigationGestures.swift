import Foundation

/// Selection is virtual and therefore safe to show on the first press. A second
/// left/right press can still invoke the independent global double shortcut.
final class ApplicationNavigationGestures {
    private enum Phase { case down, waiting, consumed }
    private struct State { var phase: Phase; var token: UInt64; let doubleMs: Int }
    private var states: [RemoteKey: State] = [:]
    private var serial: UInt64 = 0
    private let schedule: (Int, @escaping () -> Void) -> Void
    var onNavigate: ((RemoteKey, Bool) -> Void)?
    var onDouble: ((RemoteKey) -> Void)?

    init(schedule: @escaping (Int, @escaping () -> Void) -> Void) { self.schedule = schedule }

    func handle(_ event: ButtonEvent, doubleMs: Int?) {
        let key = event.key
        if event.isDown {
            if var state = states[key] {
                guard state.phase == .waiting else { return }
                serial &+= 1
                state.phase = .consumed; state.token = serial; states[key] = state
                onDouble?(key)
                return
            }
            serial &+= 1
            states[key] = State(phase: .down, token: serial, doubleMs: max(0, doubleMs ?? 0))
            onNavigate?(key, true)
        } else {
            guard var state = states[key] else { return }
            guard state.phase == .down else {
                if state.phase == .consumed { states.removeValue(forKey: key) }
                return
            }
            onNavigate?(key, false)
            if state.doubleMs == 0 { states.removeValue(forKey: key); return }
            serial &+= 1; state.phase = .waiting; state.token = serial; states[key] = state
            let token = serial
            schedule(state.doubleMs) { [weak self] in
                guard let self, self.states[key]?.token == token else { return }
                self.states.removeValue(forKey: key)
            }
        }
    }

    func reset() {
        let held = states.filter { $0.value.phase == .down }.map(\.key)
        serial &+= 1; states.removeAll()
        held.forEach { onNavigate?($0, false) }
    }

    static func selfCheck() -> Bool {
        var pending: [() -> Void] = []
        var moves: [String] = []; var doubles: [RemoteKey] = []
        let g = ApplicationNavigationGestures { _, work in pending.append(work) }
        g.onNavigate = { moves.append("\($0.rawValue)\($1 ? "+" : "-")") }
        g.onDouble = { doubles.append($0) }
        func key(_ key: RemoteKey, _ down: Bool, _ ms: Int? = 250) {
            g.handle(ButtonEvent(key: key, isDown: down, timeNs: 0), doubleMs: ms)
        }
        key(.right, true)
        guard moves == ["right+"] else { return false }
        key(.right, true); key(.right, false); key(.right, true); key(.right, false)
        guard moves == ["right+", "right-"], doubles == [.right] else { return false }
        pending.forEach { $0() }; pending.removeAll()
        key(.up, true, nil); g.reset()
        guard moves.suffix(2) == ["up+", "up-"] else { return false }
        key(.left, true); key(.left, false); g.reset()
        key(.left, true); pending.forEach { $0() }
        key(.left, false)
        return doubles == [.right] && moves.suffix(2) == ["left+", "left-"]
    }
}
