import Foundation

/// Local control state only; an ACK never becomes a claim that the TV shut down.
struct TelevisionPowerMenuState {
    enum Phase: Equatable { case opening, ready, uncertain, failed }
    enum Effect: Equatable { case none, cancel, send(XiaomiTVCommand) }
    private(set) var phase = Phase.opening
    private(set) var message = "正在请求电视原生电源菜单…"

    var isLoading: Bool { if case .opening = phase { true } else { false } }
    // The TV supplies the visible menu. Further physical key presses are the
    // user's navigation intent even when a transport ACK was incomplete.
    var canNavigate: Bool { phase == .ready || phase == .uncertain }
    var needsVisualConfirmation: Bool { if case .uncertain = phase { true } else { false } }
    var mayBeOpen: Bool { canNavigate || needsVisualConfirmation }

    static func mayHaveOpened(_ result: Result<Void, XiaomiTVFailure>) -> Bool {
        switch result {
        case .success, .failure(.deliveryUnconfirmed), .failure(.invalidResponse): true
        default: false
        }
    }

    mutating func opened(_ result: Result<Void, XiaomiTVFailure>) {
        switch result {
        case .success:
            phase = .ready
            message = "请看电视原生菜单，用方向键选择“关机”，再按 OK 确认。"
        case .failure(let failure):
            phase = Self.mayHaveOpened(result) ? .uncertain : .failed
            message = failure.message
            if needsVisualConfirmation { message += " 请在电视原生菜单操作；返回退出电视控制。" }
        }
    }

    mutating func handle(_ key: RemoteKey) -> Effect {
        if [.back, .home, .tv, .menu, .power].contains(key) { return .cancel }
        guard canNavigate else { return .none }
        switch key {
        case .up: return .send(.up)
        case .down: return .send(.down)
        case .left: return .send(.left)
        case .right: return .send(.right)
        case .ok: return .send(.ok)
        default: return .none
        }
    }

    /// A failed reachability check ends only local routing, not the TV menu.
    /// Busy/cancelled checks say nothing about whether the TV is still online.
    static func endsSession(_ result: Result<Void, XiaomiTVFailure>) -> Bool {
        switch result {
        case .failure(.connectionFailed), .failure(.timedOut),
             .failure(.notConfigured), .failure(.disabled): true
        default: false
        }
    }

    mutating func received(_ result: Result<Void, XiaomiTVFailure>, key: RemoteKey) {
        switch result {
        case .success:
            message = key == .ok
                ? "确认键已送达；如电视还有确认框，再按 OK。实际关机结果请看电视。"
                : "方向键已送达；请在电视菜单中选择“关机”。"
        case .failure(let failure): message = failure.message + " 请查看电视实际状态；不会自动重发。"
        }
    }

    static func selfCheck() -> Bool {
        var state = Self()
        guard state.handle(.ok) == .none, state.handle(.right) == .none else { return false }
        state.opened(.success(()))
        guard state.handle(.right) == .send(.right), state.handle(.ok) == .send(.ok),
              state.handle(.back) == .cancel else { return false }
        state = Self(); state.opened(.failure(.deliveryUnconfirmed))
        guard state.handle(.left) == .send(.left), state.handle(.ok) == .send(.ok) else { return false }
        state = Self(); state.opened(.failure(.connectionFailed))
        return !state.mayBeOpen && state.handle(.ok) == .none && state.handle(.back) == .cancel
            && endsSession(.failure(.connectionFailed)) && endsSession(.failure(.timedOut))
            && !endsSession(.success(())) && !endsSession(.failure(.busy))
            && !endsSession(.failure(.cancelled)) && !endsSession(.failure(.deliveryUnconfirmed))
    }
}
