import SwiftUI

/// Dropdown state belongs to this open panel, never persisted as app defaults.
struct CodexSessionSettingsPanel {
    var snapshot: CodexSessionSettings.Snapshot?
    var selected: CodexSessionSettings.Field = .presets
    var expanded: CodexSessionSettings.Field?
    var options: [CodexSessionSettings.Option] = []
    var optionIndex = 0
    var busy = false
    var error: String?

    mutating func move(_ key: RemoteKey) {
        let delta = key == .up || key == .left ? -1 : 1
        if expanded != nil {
            optionIndex = CodexSessions.movedIndex(optionIndex, delta: delta, count: options.count)
        } else if let index = CodexSessionSettings.Field.allCases.firstIndex(of: selected) {
            let fields = CodexSessionSettings.Field.allCases
            selected = fields[CodexSessions.movedIndex(index, delta: delta, count: fields.count)]
        }
    }

    mutating func collapse() {
        expanded = nil
        options = []
        optionIndex = 0
    }
}

struct CodexSessionSettingsView: View {
    let state: CodexSessionSettingsPanel
    let onField: (CodexSessionSettings.Field) -> Void
    let onOption: (CodexSessionSettings.Option) -> Void
    let onBack: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button(action: onBack) { Image(systemName: "chevron.left") }.buttonStyle(.plain)
                Text("当前会话设置").font(.headline)
                Spacer()
                if state.busy { ProgressView().controlSize(.small) }
            }
            VStack(spacing: 10) {
                fieldRow(.presets, title: "常用模型和强度", icon: "star")
                fieldRow(.model, title: "模型", value: state.snapshot?.model ?? "读取中…")
                fieldRow(.effort, title: "思考强度", value: state.snapshot?.effort ?? "读取中…")
                fieldRow(.plugins, title: "添加插件", icon: "puzzlepiece.extension")
            }
            if let field = state.expanded {
                Divider()
                if state.options.isEmpty {
                    Text(field == .plugins ? "当前没有可添加的插件" : "当前模型没有可调整的选项")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if field != .presets {
                    Text(field == .model ? "选择模型" : field == .effort ? "选择思考强度" : "添加插件到当前输入框")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(state.options.enumerated()), id: \.element.id) { index, option in
                                Button { onOption(option) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: option.isSelected ? "checkmark" : "circle")
                                            .font(.caption).foregroundStyle(.secondary).frame(width: 16)
                                        Text(option.label).frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(12)
                                    .foregroundStyle(option.isEnabled ? Color.primary : .secondary)
                                    .background(rowFill(index == state.optionIndex), in: RoundedRectangle(cornerRadius: Radius.small))
                                    .overlay(RoundedRectangle(cornerRadius: Radius.small)
                                        .stroke(index == state.optionIndex ? Color.accentColor : .clear, lineWidth: 2))
                                }
                                .buttonStyle(.plain).disabled(state.busy || !option.isEnabled)
                                .id(option.id)
                            }
                        }.padding(3)
                    }.frame(maxHeight: 240)
                    .onAppear {
                        if state.options.indices.contains(state.optionIndex) {
                            proxy.scrollTo(state.options[state.optionIndex].id, anchor: .center)
                        }
                    }
                    .onChange(of: state.optionIndex) { _, index in
                        if state.options.indices.contains(index) {
                            withAnimation(Motion.select) { proxy.scrollTo(state.options[index].id, anchor: .center) }
                        }
                    }
                }
            }
            if (state.snapshot == nil || state.error != nil), !state.busy {
                Button("重新读取当前会话", action: onRetry).buttonStyle(.borderedProminent)
            }
            if let error = state.error {
                Text(error).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text("↑↓ 选择 · OK 展开 / 应用 · 返回收起 / 返回菜单")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(Spacing.sheetPadding)
        .frame(width: 570)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.overlay))
        .overlay(RoundedRectangle(cornerRadius: Radius.overlay).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        .shadow(radius: 24, y: 8)
    }

    private func fieldRow(_ field: CodexSessionSettings.Field, title: String, value: String? = nil, icon: String? = nil) -> some View {
        Button { onField(field) } label: {
            HStack {
                if let icon { Image(systemName: icon) }
                Text(title)
                Spacer()
                if let value { Text(value).lineLimit(2).multilineTextAlignment(.trailing) }
                Image(systemName: state.expanded == field ? "chevron.up" : "chevron.down")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            .background(rowFill(state.selected == field), in: RoundedRectangle(cornerRadius: Radius.small))
            .overlay(RoundedRectangle(cornerRadius: Radius.small)
                .stroke(state.selected == field ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .disabled(state.busy || state.snapshot == nil)
    }

    private func rowFill(_ selected: Bool) -> Color {
        selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06)
    }
}
