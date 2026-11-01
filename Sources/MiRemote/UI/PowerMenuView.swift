import SwiftUI

struct PowerMenuView: View {
    let state: PowerMenuState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("电脑电源", systemImage: "power").font(.headline)
            VStack(spacing: 4) {
                ForEach(PowerMenuState.Choice.allCases, id: \.rawValue) { choice in
                    row(choice)
                }
            }
            if state.isExecuting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在请求\(state.selection.title)…")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let error = state.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.sheetPadding)
        .frame(width: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.overlay))
        .overlay(RoundedRectangle(cornerRadius: Radius.overlay)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        .shadow(radius: 24, y: 8)
    }

    private func row(_ choice: PowerMenuState.Choice) -> some View {
        let selected = state.selection == choice
        return HStack(spacing: 12) {
            Image(systemName: choice.symbol).frame(width: 24)
            Text(choice.title).font(.body.weight(selected ? .semibold : .regular))
            Spacer()
        }
        .foregroundStyle(choice == .shutDown ? Color.red : Color.primary)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(minHeight: 48)
        .background(selected ? Color.accentColor.opacity(0.14) : Color.clear,
                    in: RoundedRectangle(cornerRadius: Radius.small))
        .overlay(RoundedRectangle(cornerRadius: Radius.small)
            .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
