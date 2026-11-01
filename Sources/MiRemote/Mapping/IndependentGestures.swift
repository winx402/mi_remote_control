import Foundation

/// 只识别物理手势，动作的全局/应用优先级由 MappingEngine 决定。
final class IndependentGestures {
    enum Gesture: Equatable { case tap, double, hold }
    struct Policy {
        var doubleMs: Int
        var holdMs: Int
        var hasDouble: Bool
        var hasHold: Bool
    }
    private enum Phase { case down, waiting, consumed }
    private struct State {
        var phase: Phase
        var token: UInt64
        var policy: Policy
    }
    private var states: [RemoteKey: State] = [:]
    private var serial: UInt64 = 0
    private let schedule: (Int, @escaping () -> Void) -> Void
    var onGesture: ((RemoteKey, Gesture) -> Void)?

    init(schedule: @escaping (Int, @escaping () -> Void) -> Void) { self.schedule = schedule }

    func reset() { serial &+= 1; states.removeAll() }

    func handle(_ event: ButtonEvent, policy: Policy) {
        let key = event.key
        if event.isDown {
            if var old = states[key] {
                if old.phase == .waiting {
                    serial &+= 1
                    old.token = serial
                    old.phase = .consumed
                    states[key] = old
                    onGesture?(key, .double)
                }
                return // 重复 down 不得重启长按计时。
            }
            serial &+= 1
            let token = serial
            states[key] = State(phase: .down, token: token, policy: policy)
            if policy.hasHold {
                schedule(max(1, policy.holdMs)) { [weak self] in
                    guard let self, var state = self.states[key],
                          state.token == token, state.phase == .down else { return }
                    state.phase = .consumed
                    self.states[key] = state
                    self.onGesture?(key, .hold)
                }
            }
        } else {
            guard var state = states[key] else { return }
            if state.phase == .consumed { states.removeValue(forKey: key); return }
            guard state.phase == .down else { return }
            serial &+= 1
            state.token = serial
            if state.policy.hasDouble, state.policy.doubleMs > 0 {
                state.phase = .waiting
                states[key] = state
                let token = state.token
                schedule(state.policy.doubleMs) { [weak self] in
                    guard let self, let current = self.states[key],
                          current.token == token, current.phase == .waiting else { return }
                    self.states.removeValue(forKey: key)
                    self.onGesture?(key, .tap)
                }
            } else {
                states.removeValue(forKey: key)
                onGesture?(key, .tap)
            }
        }
    }

    static func selfCheck() -> Bool {
        var now = 0
        var pending: [(Int, () -> Void)] = []
        var result: [(RemoteKey, Gesture)] = []
        let gestures = IndependentGestures { ms, work in pending.append((now + ms, work)) }
        gestures.onGesture = { result.append(($0, $1)) }
        func advance(_ ms: Int) {
            let end = now + ms
            while let i = pending.enumerated().filter({ $0.element.0 <= end })
                .min(by: { $0.element.0 < $1.element.0 })?.offset {
                let item = pending.remove(at: i); now = item.0; item.1()
            }
            now = end
        }
        let p = Policy(doubleMs: 250, holdMs: 600, hasDouble: true, hasHold: true)
        func event(_ key: RemoteKey, _ down: Bool, _ policy: Policy = p) {
            gestures.handle(ButtonEvent(key: key, isDown: down, timeNs: 0), policy: policy)
        }
        event(.home, true); advance(20); event(.home, false); advance(100)
        event(.home, true); event(.home, false); advance(800)
        guard result.count == 1, result[0].1 == .double else { return false }
        result.removeAll()
        event(.menu, true); advance(610); event(.menu, false); advance(300)
        guard result.count == 1, result[0].1 == .hold else { return false }
        result.removeAll()
        event(.ok, true, Policy(doubleMs: 250, holdMs: 600, hasDouble: false, hasHold: false))
        event(.ok, false)
        guard result.count == 1, result[0].1 == .tap else { return false }
        result.removeAll()
        event(.home, true); event(.home, false); gestures.reset(); advance(1000)
        guard result.isEmpty else { return false }
        event(.back, true, Policy(doubleMs: 250, holdMs: 1200, hasDouble: false, hasHold: true))
        advance(700)
        guard result.isEmpty else { return false }
        advance(500); event(.back, false)
        return result.count == 1 && result[0].1 == .hold
    }
}
