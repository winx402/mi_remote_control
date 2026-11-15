import SwiftUI

/// Applications use an icon tile; commands use a compact horizontal button.
/// Both pointer and remote confirmation still use the same guarded action exit.
struct PowerMenuActionCard: View {
    static let applicationHeight: CGFloat = 64
    static let commandHeight: CGFloat = 40
    let choice: PowerMenuState.Choice
    let selected: Bool
    let executing: Bool
    let confirming: Bool
    let appIcon: NSImage?
    let onSelect: () -> Void
    let onFocus: () -> Void
    let onConfirmed: () -> Void
    var width: CGFloat = 142
    var appIsRunning = false
    var confirmationEpoch: UInt64 = 0

    @State private var mousePressing = false
    @State private var holdStarted: Date?
    @State private var pressedConfirmation: (() -> Void)?
    private var needsConfirmation: Bool { choice.command?.requiresHoldConfirmation == true }
    private var tint: Color { needsConfirmation ? .red : .accentColor }
    private var holding: Bool { confirming || mousePressing }
    private var isApp: Bool {
        if case .launchApp = choice.command { return true }
        return false
    }

    @ViewBuilder var body: some View {
        if needsConfirmation {
            button.onLongPressGesture(minimumDuration: 0.6, maximumDistance: 12,
                pressing: { pressing in
                    guard !choice.disabled, !executing else { return }
                    mousePressing = pressing
                    if pressing {
                        // Keep the callback containing the menu/input generations
                        // from pointer-down, never a newer SwiftUI render's token.
                        pressedConfirmation = onConfirmed
                        onFocus()
                    }
                }, perform: {
                    guard !choice.disabled, !executing, let confirm = pressedConfirmation else { return }
                    pressedConfirmation = nil
                    confirm()
                })
                .onChange(of: holding, initial: true) { _, active in holdStarted = active ? Date() : nil }
                .onChange(of: confirmationEpoch) { _, _ in cancelPointerHold() }
                .onChange(of: selected) { _, active in if !active { cancelPointerHold() } }
                .onChange(of: executing) { _, active in
                    if active { cancelPointerHold() }
                }
                .onDisappear { cancelPointerHold() }
        } else { button }
    }
    private func cancelPointerHold() {
        pressedConfirmation = nil
        mousePressing = false
        holdStarted = nil
    }

    private var button: some View {
        Button {
            if needsConfirmation { onFocus() } else { onSelect() }
        } label: {
            Group {
                if isApp {
                    VStack(spacing: 6) {
                        ZStack(alignment: .bottomTrailing) {
                            if let appIcon {
                                Image(nsImage: appIcon).resizable().interpolation(.high)
                                    .scaledToFit().frame(width: 36, height: 36)
                            } else { Image(systemName: "app").font(.system(size: 30)) }
                            if appIsRunning {
                                Circle().fill(.green).frame(width: 7, height: 7)
                                    .overlay(Circle().stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 1.5))
                                    .offset(x: 2, y: 1)
                            }
                        }
                        Text(choice.title).font(.system(size: 12, weight: selected ? .semibold : .medium))
                            .lineLimit(1).frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, 5)
                } else {
                    HStack(spacing: 8) {
                        commandIcon
                        Text(choice.title).font(.system(size: 12, weight: selected ? .semibold : .medium))
                            .lineLimit(1).minimumScaleFactor(0.9)
                        Spacer(minLength: 0)
                        if needsConfirmation {
                            Image(systemName: "hand.tap").font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }
            .frame(width: width, height: isApp ? Self.applicationHeight : Self.commandHeight)
            .foregroundStyle(choice.disabled ? Color.secondary : .primary)
            .contentShape(RoundedRectangle(cornerRadius: isApp ? 12 : 10))
            .background(selected ? tint.opacity(0.14) : Color.primary.opacity(isApp ? 0.025 : 0.045),
                        in: RoundedRectangle(cornerRadius: isApp ? 12 : 10))
            .overlay(RoundedRectangle(cornerRadius: isApp ? 12 : 10)
                .strokeBorder(selected ? tint : Color.primary.opacity(0.045), lineWidth: selected ? 2 : 1))
            .opacity(choice.disabled ? 0.4 : 1)
        }
        .buttonStyle(.plain).disabled(choice.disabled || executing)
        .help(accessibilityDetail)
        .accessibilityElement(children: .combine)
        .accessibilityHint(accessibilityDetail)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var commandIcon: some View {
        ZStack {
            Image(systemName: choice.symbol).font(.system(size: 16, weight: .medium))
                .foregroundStyle(needsConfirmation ? Color.red.opacity(0.85) : Color.accentColor)
            if holding {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    let progress = min(1, max(0, timeline.date.timeIntervalSince(holdStarted ?? timeline.date) / 0.6))
                    Circle().trim(from: 0, to: progress)
                        .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90)).frame(width: 28, height: 28)
                }
            }
        }.frame(width: 22, height: 28)
    }
    private var accessibilityDetail: String {
        let detail = choice.detail ?? choice.title
        if needsConfirmation { return "\(detail) 按住 0.6 秒确认。" }
        return appIsRunning ? "已运行。\(detail)" : detail
    }
}
