import Foundation

/// Explicit Codex context bindings use physical presses, never OS autorepeat.
/// Only vertical navigation repeats; confirmation holds commit once and consume
/// their release. Context changes retain held keys until their physical release.
final class CodexContextGestures {
    private enum Phase { case down, consumed }
    private struct State {
        var phase: Phase
        var token: UInt64
    }
    private var states: [RemoteKey: State] = [:]
    private var serial: UInt64 = 0
    private let schedule: (Int, @escaping () -> Void) -> Void
    var onDirection: ((RemoteKey) -> Void)?
    var onConfirm: ((_ hold: Bool) -> Void)?

    init(schedule: @escaping (Int, @escaping () -> Void) -> Void) { self.schedule = schedule }

    func handle(_ event: ButtonEvent, holdMs: Int) {
        let key = event.key
        if event.isDown {
            guard states[key] == nil else { return }
            serial &+= 1
            let token = serial
            states[key] = State(phase: .down, token: token)
            if key == .ok {
                schedule(max(1, holdMs)) { [weak self] in
                    guard let self, var state = self.states[key],
                          state.token == token, state.phase == .down else { return }
                    state.phase = .consumed
                    self.states[key] = state
                    self.onConfirm?(true)
                }
            } else {
                onDirection?(key)
                if key == .up || key == .down { repeatDirection(key, token: token, delay: 350) }
            }
        } else {
            guard let state = states.removeValue(forKey: key), state.phase == .down else { return }
            if key == .ok { onConfirm?(false) }
        }
    }

    private func repeatDirection(_ key: RemoteKey, token: UInt64, delay: Int) {
        schedule(delay) { [weak self] in
            guard let self, let state = self.states[key],
                  state.token == token, state.phase == .down else { return }
            self.onDirection?(key)
            self.repeatDirection(key, token: token, delay: 160)
        }
    }

    func consumeSuppressed(_ event: ButtonEvent) -> Bool {
        guard states[event.key]?.phase == .consumed else { return false }
        if !event.isDown { states.removeValue(forKey: event.key) }
        return true
    }

    func reset(preservePressed: Bool = true) {
        serial &+= 1
        if !preservePressed { states.removeAll(); return }
        for key in states.keys {
            states[key]?.phase = .consumed
            states[key]?.token = serial
        }
    }
}
