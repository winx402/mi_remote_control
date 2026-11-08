import SwiftUI

struct PowerMenuView: View {
    let state: PowerMenuState
    let onSelect: (PowerMenuState.Choice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.intra) {
            Label("电源与应用", systemImage: "power").font(.headline)
            Text("方向键选择 · OK 执行 · 返回取消")
                .font(.caption).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(menuChoices.enumerated()), id: \.element.id) { index, choice in
                            if startsSection(at: index), !choice.section.isEmpty {
                                Text(choice.section)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, Spacing.rowH)
                                    .padding(.top, index == 0 ? 2 : Spacing.intra)
                                    .padding(.bottom, 2)
                            }
                            row(choice).id(choice.id)
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .frame(height: listHeight)
                .onChange(of: state.selection.id) { _, id in
                    guard id != PowerMenuState.Choice.cancel.id else { return }
                    withAnimation(Motion.select) { proxy.scrollTo(id) }
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
            Divider()
            row(.cancel)
        }
        .padding(Spacing.sheetPadding)
        .frame(width: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.overlay))
        .overlay(RoundedRectangle(cornerRadius: Radius.overlay)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        .shadow(radius: 24, y: 8)
    }

    private var menuChoices: [PowerMenuState.Choice] {
        state.choices.filter { $0.id != PowerMenuState.Choice.cancel.id }
    }

    private func startsSection(at index: Int) -> Bool {
        index == 0 || menuChoices[index - 1].section != menuChoices[index].section
    }

    private var listHeight: CGFloat {
        let rows = menuChoices.reduce(CGFloat.zero) { total, choice in
            total + (choice.detail == nil ? 46 : 68)
        }
        let headers = menuChoices.indices.filter {
            startsSection(at: $0) && !menuChoices[$0].section.isEmpty
        }.count
        return min(500, rows + CGFloat(headers * 30) + CGFloat(max(0, menuChoices.count - 1) * 4))
    }

    private func row(_ choice: PowerMenuState.Choice) -> some View {
        let selected = state.selection.id == choice.id
        let isShutDown = choice.command == .computer(.shutDown)
        return Button { onSelect(choice) } label: {
            HStack(spacing: 12) {
                Image(systemName: choice.symbol)
                    .foregroundStyle(isShutDown ? Color.red : Color.primary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(choice.title).font(.body.weight(selected ? .semibold : .regular))
                        .foregroundStyle(isShutDown ? Color.red : Color.primary)
                    if let detail = choice.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                if choice.disabled {
                    Text("不可用").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Spacing.rowH)
            .padding(.vertical, Spacing.rowV + 2)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .background(selected ? Color.accentColor.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: Radius.small))
            .overlay(RoundedRectangle(cornerRadius: Radius.small)
                .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2))
            .opacity(choice.disabled ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(choice.disabled || state.isExecuting)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
