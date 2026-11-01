import Foundation

/// 左右保留双击先决断，再把单击/按住交回按下时的上下文。
/// 只产生回调；浮层、鼠标及原生方向键各自保留原来的持续按住实现。
final class ReservedDirectionGestures {
    static let decisionMs = 250

    struct Route {
        var tap: () -> Void
        var down: () -> Void
        var up: () -> Void
        var double: () -> Void
    }

    private enum Phase { case down, waiting, forwarded, consumed }
    private struct State {
        var phase: Phase
        var token: UInt64
        var route: Route
    }

    private var states: [RemoteKey: State] = [:]
    private var serial: UInt64 = 0
    private let schedule: (Int, @escaping () -> Void) -> Void

    init(schedule: @escaping (Int, @escaping () -> Void) -> Void) {
        self.schedule = schedule
    }

    func handle(_ event: ButtonEvent, makeRoute: () -> Route) {
        let key = event.key
        if event.isDown {
            if var state = states[key] {
                guard state.phase == .waiting else { return } // autorepeat 不重启计时
                serial &+= 1
                state.token = serial
                state.phase = .consumed
                states[key] = state
                state.route.double()
                return
            }
            serial &+= 1
            let token = serial
            states[key] = State(phase: .down, token: token, route: makeRoute())
            schedule(Self.decisionMs) { [weak self] in
                guard let self, var state = self.states[key],
                      state.token == token, state.phase == .down else { return }
                state.phase = .forwarded
                self.states[key] = state
                state.route.down()
            }
            return
        }

        guard var state = states[key] else { return }
        switch state.phase {
        case .down:
            serial &+= 1
            state.token = serial
            state.phase = .waiting
            states[key] = state
            let token = state.token
            schedule(Self.decisionMs) { [weak self] in
                guard let self, let current = self.states[key],
                      current.token == token, current.phase == .waiting else { return }
                self.states.removeValue(forKey: key)
                current.route.tap()
            }
        case .forwarded:
            states.removeValue(forKey: key)
            state.route.up()
        case .consumed:
            states.removeValue(forKey: key)
        case .waiting:
            break // 重复 keyUp 不延长双击窗口
        }
    }

    /// 先更新状态再补 up，允许释放回调同步引起另一次上下文切换。
    /// 上下文变化时仍按住的键持续吞到 keyUp，避免 autorepeat 落入新面板；
    /// 设备移除/暂停可清除物理按压记录，因为那次 keyUp 可能永远不会再到达。
    func reset(preservePressed: Bool = true) {
        serial &+= 1
        var releases: [() -> Void] = []
        for (key, var state) in states {
            if state.phase == .forwarded { releases.append(state.route.up) }
            if state.phase == .waiting || !preservePressed {
                states.removeValue(forKey: key)
                continue
            }
            state.phase = .consumed
            state.token = serial
            states[key] = state
        }
        for release in releases { release() }
    }
}
