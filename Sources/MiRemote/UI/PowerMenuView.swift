import SwiftUI

/// 遥控与指针共用的控制中心：分类始终可见，当前分类只占一行功能卡。
struct PowerMenuView: View {
    let state: PowerMenuState
    let onSelect: (PowerMenuState.Choice) -> Void
    var televisionStatus: String? = nil
    var favoriteApps: [DockApplications.Entry] = []
    var onFocus: (PowerMenuState.Choice) -> Void = { _ in }
    var onFocusSection: (String) -> Void = { _ in }
    var onConfirmed: (PowerMenuState.Choice) -> Void = { _ in }
    var confirmingID: String? = nil

    @State private var lastSectionID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            HStack(alignment: .top, spacing: 20) {
                categoryNavigation
                Divider()
                currentCategory
            }
            .frame(minHeight: 298)
            Divider()
            footer
        }
        .padding(24)
        .frame(width: 920)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.overlay))
        .overlay(RoundedRectangle(cornerRadius: Radius.overlay)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 28, y: 10)
        .onChange(of: state.selection.section) { _, section in
            guard state.selection.id != PowerMenuState.Choice.cancel.id else { return }
            lastSectionID = section
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: Radius.card))
            VStack(alignment: .leading, spacing: 4) {
                Text("控制中心").font(.title2.weight(.semibold))
                Text("App、工作区与设备控制")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Text("↑↓ 切换分类   ←→ 选择功能")
                Text("OK 执行   ·   返回关闭")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var displayedSection: PowerMenuState.Section? {
        state.sections.first(where: { $0.id == state.selection.section })
            ?? state.sections.first(where: { $0.id == lastSectionID })
            ?? state.sections.first
    }

    private var categoryNavigation: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("分类").font(.caption.weight(.medium)).foregroundStyle(.tertiary)
                .padding(.horizontal, 10).padding(.bottom, 6)
            ForEach(state.sections) { section in
                let active = displayedSection?.id == section.id
                let focused = active && state.selection.id != PowerMenuState.Choice.cancel.id
                Button { onFocusSection(section.id) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: sectionSymbol(section))
                            .font(.system(size: 15, weight: .medium)).frame(width: 20)
                        Text(section.title.isEmpty ? "操作" : section.title)
                            .font(.callout.weight(active ? .semibold : .regular))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if focused {
                            Capsule().fill(Color.accentColor).frame(width: 3, height: 15)
                        }
                    }
                    .foregroundStyle(active ? Color.primary : Color.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 40)
                    .contentShape(RoundedRectangle(cornerRadius: Radius.badge))
                    .background(active ? Color.accentColor.opacity(focused ? 0.12 : 0.06) : .clear,
                                in: RoundedRectangle(cornerRadius: Radius.badge))
                }
                .buttonStyle(.plain)
                .disabled(state.isExecuting || section.choices.allSatisfy(\.disabled))
                .help(section.choices.first(where: \.disabled)?.detail ?? "选择分类")
                .accessibilityAddTraits(active ? .isSelected : [])
                .accessibilityHint("选择分类，不会执行操作")
            }
            Spacer(minLength: 0)
        }
        .frame(width: 144)
    }

    @ViewBuilder
    private var currentCategory: some View {
        if let section = displayedSection {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(section.title.isEmpty ? "操作" : section.title)
                            .font(.headline)
                        Text(sectionSubtitle(section))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(selectionPosition(in: section))
                        .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        .padding(.top, 3)
                }
                actionCards(in: section)
                selectionDetail
                if let televisionStatus {
                    Label(televisionStatus, systemImage: "tv")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ContentUnavailableView("暂无操作", systemImage: "square.grid.2x2",
                                   description: Text("按返回键关闭控制中心。"))
                .frame(maxWidth: .infinity)
        }
    }

    private func actionCards(in section: PowerMenuState.Section) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(section.choices) { choice in
                        PowerMenuActionCard(choice: choice,
                            selected: state.selection.id == choice.id,
                            executing: state.isExecuting,
                            confirming: confirmingID == choice.id,
                            appIcon: appIcon(for: choice),
                            onSelect: { onSelect(choice) },
                            onFocus: { onFocus(choice) },
                            onConfirmed: { onConfirmed(choice) },
                            width: min(142, (681 - CGFloat(max(0, min(section.choices.count, 6) - 1)) * 12)
                                / CGFloat(max(1, min(section.choices.count, 6)))))
                            .id(choice.id)
                    }
                }
                .padding(3)
            }
            .scrollIndicators(.automatic)
            .frame(height: 174)
            .onChange(of: state.selection.id) { _, id in
                guard section.choices.contains(where: { $0.id == id }) else { return }
                withAnimation(Motion.select) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: section.id) { _, _ in
                let selectedID = section.choices.first(where: { $0.id == state.selection.id })?.id
                    ?? section.choices.first?.id
                if let selectedID { proxy.scrollTo(selectedID, anchor: .leading) }
            }
            .onAppear {
                if section.choices.contains(where: { $0.id == state.selection.id }) {
                    proxy.scrollTo(state.selection.id, anchor: .center)
                }
            }
        }
    }

    private var selectionDetail: some View {
        HStack(alignment: .top, spacing: 9) {
            if state.isExecuting {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: state.selection.command?.requiresHoldConfirmation == true
                      ? "hand.tap" : "info.circle")
                    .foregroundStyle(.secondary)
            }
            Text(detailText)
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 46, alignment: .topLeading)
    }

    private var detailText: String {
        if state.isExecuting { return "正在请求\(state.selection.title)…" }
        if state.selection.id == PowerMenuState.Choice.cancel.id {
            return "按 ↑ 或 ↓ 浏览分类，按 OK 取消。"
        }
        let detail = state.selection.detail ?? "执行\(state.selection.title)。"
        return state.selection.command?.requiresHoldConfirmation == true
            ? "\(detail) 按住 OK 或功能卡 0.6 秒确认。" : detail
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Group {
                if let error = state.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else if confirmingID != nil {
                    Label("继续按住以确认，松开取消", systemImage: "hand.tap")
                        .foregroundStyle(.secondary)
                } else {
                    Label("需要确认的操作请按住 0.6 秒", systemImage: "hand.tap")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            cancelButton
        }
        .frame(minHeight: 38)
    }

    private var cancelButton: some View {
        let selected = state.selection.id == PowerMenuState.Choice.cancel.id
        return Button { onSelect(.cancel) } label: {
            HStack(spacing: 8) {
                Image(systemName: "xmark")
                Text("取消").fontWeight(selected ? .semibold : .regular)
                Text("返回").font(.caption).foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .contentShape(RoundedRectangle(cornerRadius: Radius.badge))
            .background(selected ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: Radius.badge))
            .overlay(RoundedRectangle(cornerRadius: Radius.badge)
                .stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .disabled(state.isExecuting)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func appIcon(for choice: PowerMenuState.Choice) -> NSImage? {
        guard case .launchApp(let bundleID) = choice.command else { return nil }
        return favoriteApps.first(where: {
            $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame
        })?.icon
    }

    private func selectionPosition(in section: PowerMenuState.Section) -> String {
        if let index = section.choices.firstIndex(where: { $0.id == state.selection.id }) {
            return "\(index + 1) / \(section.choices.count)"
        }
        return "\(section.choices.count) 项功能"
    }

    private func sectionSymbol(_ section: PowerMenuState.Section) -> String {
        guard let command = section.choices.first?.command else { return "square.grid.2x2" }
        switch command {
        case .launchApp: return "square.grid.2x2"
        case .tvWake, .tvStandby, .tvOff, .tvVolumeUp, .tvVolumeDown: return "tv"
        case .computer: return "power"
        case .quitCurrentApp, .quitApp, .openSettings: return "app.badge"
        case .systemAction(let action) where ["play_pause", "mute"].contains(action): return "playpause"
        default: return "rectangle.3.group"
        }
    }

    private func sectionSubtitle(_ section: PowerMenuState.Section) -> String {
        switch sectionSymbol(section) {
        case "square.grid.2x2": return "打开或切换到常用 App"
        case "tv": return "电视电源与音量"
        case "power": return "管理这台 Mac 的电源与访问"
        case "app.badge": return "退出 App 或打开遥控器设置"
        case "playpause": return "控制播放与 Mac 声音"
        default: return "管理窗口、桌面和输入焦点"
        }
    }
}
