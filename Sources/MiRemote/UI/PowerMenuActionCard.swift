import SwiftUI

/// 危险卡的短按只聚焦；手势与遥控计时都仅反馈到同一个明确确认入口。
struct PowerMenuActionCard: View {
    let choice: PowerMenuState.Choice
    let selected: Bool
    let executing: Bool
    let confirming: Bool
    let appIcon: NSImage?
    let onSelect: () -> Void
    let onFocus: () -> Void
    let onConfirmed: () -> Void
    var width: CGFloat = 142

    @State private var mousePressing = false
    @State private var holdStarted: Date?

    private var needsConfirmation: Bool { choice.command?.requiresHoldConfirmation == true }
    private var tint: Color { needsConfirmation ? .red : .accentColor }
    private var holding: Bool { confirming || mousePressing }

    @ViewBuilder
    var body: some View {
        if needsConfirmation {
            button
                .onLongPressGesture(minimumDuration: 0.6, maximumDistance: 12,
                                    pressing: { pressing in
                    guard !choice.disabled, !executing else { return }
                    mousePressing = pressing
                    if pressing { onFocus() }
                }, perform: {
                    guard !choice.disabled, !executing else { return }
                    onConfirmed()
                })
                .onChange(of: holding, initial: true) { _, active in holdStarted = active ? Date() : nil }
                .onChange(of: executing) { _, active in
                    if active { mousePressing = false; holdStarted = nil }
                }
        } else {
            button
        }
    }

    private var button: some View {
        Button {
            if needsConfirmation { onFocus() } else { onSelect() }
        } label: {
            VStack(spacing: 10) {
                icon
                Text(choice.title)
                    .font(.callout.weight(selected ? .semibold : .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(height: 36)
                Text(choice.disabled ? "不可用" : needsConfirmation ? (holding ? "继续按住…" : "按住确认") : "按 OK 执行")
                    .font(.caption2)
                    .foregroundStyle(needsConfirmation ? tint : .secondary)
            }
            .foregroundStyle(choice.disabled ? Color.secondary : needsConfirmation ? tint : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 14)
            .frame(width: width, height: 156)
            .contentShape(RoundedRectangle(cornerRadius: Radius.card))
            .background(selected ? tint.opacity(0.13) : Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card)
                .stroke(selected ? tint : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 1))
            .opacity(choice.disabled ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(choice.disabled || executing)
        .help(accessibilityDetail)
        .accessibilityElement(children: .combine)
        .accessibilityHint(accessibilityDetail)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var icon: some View {
        ZStack {
            if let appIcon {
                Image(nsImage: appIcon).resizable().interpolation(.high)
                    .scaledToFit().frame(width: 46, height: 46)
            } else {
                Circle().fill(tint.opacity(selected ? 0.1 : 0.06)).frame(width: 48, height: 48)
                Image(systemName: choice.symbol).font(.system(size: 24, weight: .regular))
            }
            if holding {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    let progress = min(1, max(0, timeline.date.timeIntervalSince(holdStarted ?? timeline.date) / 0.6))
                    Circle().trim(from: 0, to: progress)
                        .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 56, height: 56)
                }
            }
        }
        .frame(height: 52)
    }

    private var accessibilityDetail: String {
        let detail = choice.detail ?? choice.title
        return needsConfirmation ? "\(detail) 按住 0.6 秒确认。" : detail
    }
}
