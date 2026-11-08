import Foundation

/// Reserved holds never send an application key or start scrolling before their
/// decision. A short press commits on release, with no double-click window.
final class ReservedDirectionGestures {
    static let defaultHoldMs = 650

    struct Route {
        var tap: () -> Void
        var hold: () -> Void
    }

    private enum Phase { case down, consumed }
    private struct State {
        var phase: Phase
        var token: UInt64
        var route: Route
    }

    private var states: [RemoteKey: State] = [:]
    private var serial: UInt64 = 0
    private let schedule: (Int, @escaping () -> Void) -> Void

    init(schedule: @escaping (Int, @escaping () -> Void) -> Void) { self.schedule = schedule }

    func handle(_ event: ButtonEvent, holdMs: Int, makeRoute: () -> Route) {
        let key = event.key
        if event.isDown {
            guard states[key] == nil else { return }
            serial &+= 1
            let token = serial
            states[key] = State(phase: .down, token: token, route: makeRoute())
            schedule(max(1, holdMs)) { [weak self] in
                guard let self, var state = self.states[key],
                      state.token == token, state.phase == .down else { return }
                state.phase = .consumed
                self.states[key] = state
                state.route.hold()
            }
        } else {
            guard let state = states.removeValue(forKey: key), state.phase == .down else { return }
            state.route.tap()
        }
    }

    func consumeSuppressed(_ event: ButtonEvent) -> Bool {
        guard states[event.key]?.phase == .consumed else { return false }
        if !event.isDown { states.removeValue(forKey: event.key) }
        return true
    }

    /// Keep physically held keys consumed across a context change. Device
    /// removal/suspension can discard them because their keyUp may never arrive.
    func reset(preservePressed: Bool = true) {
        serial &+= 1
        if !preservePressed { states.removeAll(); return }
        for key in states.keys {
            states[key]?.phase = .consumed
            states[key]?.token = serial
        }
    }
}
