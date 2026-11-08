import SwiftUI

/// Local control state only; an ACK never becomes a claim that the TV shut down.
struct TelevisionPowerMenuState {
    enum Phase { case opening, ready, uncertain, failed }
    enum Effect: Equatable { case none, cancel, send(XiaomiTVCommand) }
    private(set) var phase = Phase.opening
    private(set) var message = "正在请求电视原生电源菜单…"

    var isLoading: Bool { if case .opening = phase { true } else { false } }
    var canNavigate: Bool { if case .ready = phase { true } else { false } }
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
            if needsVisualConfirmation { message += " 若已看到电源菜单，按 OK 开始控制；否则按返回取消。" }
        }
    }

    mutating func handle(_ key: RemoteKey) -> Effect {
        if [.back, .home, .tv, .menu, .power].contains(key) { return .cancel }
        if needsVisualConfirmation, key == .ok {
            phase = .ready
            message = "已确认菜单可见；方向键选择“关机”，OK 发送确认。"
            return .none
        }
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
        guard state.handle(.left) == .none, state.handle(.ok) == .none,
              state.handle(.ok) == .send(.ok) else { return false }
        state = Self(); state.opened(.failure(.connectionFailed))
        return !state.mayBeOpen && state.handle(.ok) == .none && state.handle(.back) == .cancel
    }
}

struct TelevisionPowerMenuView: View {
    let state: TelevisionPowerMenuState
    let onKey: (RemoteKey) -> Void

    var body: some View {
        VStack(spacing: 18) {
            Label("在电视上确认关机", systemImage: "tv").font(.title2.weight(.semibold))
            Text("请选择电视菜单中的“关机”，与“待机”分开。")
                .font(.callout).foregroundStyle(.secondary)
            if state.isLoading { ProgressView().controlSize(.small) }
            Text(state.message).font(.body).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 52)
            if state.needsVisualConfirmation {
                Button("已看到电视电源菜单") { onKey(.ok) }.buttonStyle(.borderedProminent)
            }
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow { Color.clear.frame(width: 64, height: 1); key(.up, "arrow.up"); Color.clear.frame(width: 64, height: 1) }
                GridRow { key(.left, "arrow.left"); key(.ok, "checkmark"); key(.right, "arrow.right") }
                GridRow { Color.clear.frame(width: 64, height: 1); key(.down, "arrow.down"); Color.clear.frame(width: 64, height: 1) }
            }
            Divider()
            Button("取消电视菜单并返回控制中心") { onKey(.back) }
                .buttonStyle(.bordered).controlSize(.large)
            Text("方向键和 OK 此时控制电视；短按返回恢复 Mac 控制。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(28).frame(width: 540)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.primary.opacity(0.1)))
        .shadow(radius: 24, y: 8)
    }

    private func key(_ key: RemoteKey, _ symbol: String) -> some View {
        Button { onKey(key) } label: {
            Image(systemName: symbol).font(.title3).frame(width: 64, height: 44)
        }.buttonStyle(.bordered).disabled(!state.canNavigate)
    }
}
