import SwiftUI

struct PowerMenuView: View {
    let state: PowerMenuState
    let onSelect: (PowerMenuState.Choice) -> Void
    var televisionStatus: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.intra) {
            HStack {
                Label("电源与应用", systemImage: "power").font(.headline)
                Spacer()
                Text("↑↓ 切分类 · ←→ 选按钮 · OK 执行")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: Spacing.intra + 2) {
                        ForEach(state.sections) { section in
                            category(section).id(section.id)
                        }
                    }
                    .padding(2)
                }
                .scrollIndicators(.automatic)
                .frame(height: categoriesHeight)
                .onChange(of: state.selection.section) { _, section in
                    guard state.selection.id != PowerMenuState.Choice.cancel.id else { return }
                    withAnimation(Motion.select) { proxy.scrollTo(section) }
                }
            }
            detail
            if let televisionStatus {
                Text(televisionStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if let error = state.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            cancelButton
        }
        .padding(Spacing.sheetPadding)
        .frame(width: 720)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.overlay))
        .overlay(RoundedRectangle(cornerRadius: Radius.overlay)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        .shadow(radius: 24, y: 8)
    }

    private var categoriesHeight: CGFloat {
        let heights = state.sections.map { section in
            CGFloat(106 + (unavailableDetail(in: section) == nil ? 0 : 34))
        }
        return min(400, heights.reduce(0, +) + CGFloat(max(0, heights.count - 1) * 12) + 4)
    }

    private func category(_ section: PowerMenuState.Section) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title.isEmpty ? "操作" : section.title)
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(section.choices) { choice in
                            choiceButton(choice).id(choice.id)
                        }
                    }
                    .padding(2)
                }
                .scrollIndicators(.automatic)
                .frame(height: 86)
                .onChange(of: state.selection.id) { _, id in
                    guard section.choices.contains(where: { $0.id == id }) else { return }
                    withAnimation(Motion.select) { proxy.scrollTo(id) }
                }
            }
            if let unavailable = unavailableDetail(in: section) {
                Text(unavailable)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func unavailableDetail(in section: PowerMenuState.Section) -> String? {
        let details = section.choices.filter(\.disabled).compactMap { choice in
            choice.detail.map { "\(choice.title)：\($0)" }
        }
        return details.isEmpty ? nil : details.joined(separator: " · ")
    }

    private var detail: some View {
        HStack(spacing: 8) {
            if state.isExecuting {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
            Text(state.isExecuting ? "正在请求\(state.selection.title)…" : selectionDetail)
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 36, alignment: .leading)
    }

    private var selectionDetail: String {
        if state.selection.id == PowerMenuState.Choice.cancel.id {
            return "按 ↑ 进入操作分类，返回键或再次按电源键取消。"
        }
        return state.selection.detail ?? "按 OK 执行\(state.selection.title)。"
    }

    private func choiceButton(_ choice: PowerMenuState.Choice) -> some View {
        let selected = state.selection.id == choice.id
        let destructive = choice.command == .computer(.shutDown) || choice.command == .tvOff
        return Button { onSelect(choice) } label: {
            VStack(spacing: 6) {
                Image(systemName: choice.symbol).font(.system(size: 20))
                Text(choice.title)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if choice.disabled {
                    Text("不可用").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(destructive ? Color.red : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(width: 126, height: 82)
            .contentShape(RoundedRectangle(cornerRadius: Radius.small))
            .background(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: Radius.small))
            .overlay(RoundedRectangle(cornerRadius: Radius.small)
                .stroke(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 1))
            .opacity(choice.disabled ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(choice.disabled || state.isExecuting)
        .help(choice.detail ?? choice.title)
        .accessibilityElement(children: .combine)
        .accessibilityHint(choice.detail ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var cancelButton: some View {
        let selected = state.selection.id == PowerMenuState.Choice.cancel.id
        return Button { onSelect(.cancel) } label: {
            HStack(spacing: 10) {
                Image(systemName: "xmark")
                Text("取消").font(.body.weight(selected ? .semibold : .regular))
                Spacer()
                Text("返回").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Spacing.rowH)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .background(selected ? Color.accentColor.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: Radius.small))
            .overlay(RoundedRectangle(cornerRadius: Radius.small)
                .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .disabled(state.isExecuting)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
