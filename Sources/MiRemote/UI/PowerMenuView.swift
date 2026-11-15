import SwiftUI

/// A single expanded surface. Grid columns are shared with remote navigation.
private struct SelectedAppAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        if let next = nextValue() { value = next }
    }
}

struct PowerMenuView: View {
    let state: PowerMenuState
    let onSelect: (PowerMenuState.Choice) -> Void
    var televisionStatus: String? = nil
    var favoriteApps: [DockApplications.Entry] = []
    var runningAppIDs: Set<String> = []
    var onFocus: (PowerMenuState.Choice) -> Void = { _ in }
    var onConfirmed: (PowerMenuState.Choice) -> Void = { _ in }
    var confirmingID: String? = nil
    var confirmationEpoch: UInt64 = 0
    var availableSize: CGSize? = nil

    private let gap: CGFloat = 8
    private let sectionGap: CGFloat = 8
    private var screenSize: CGSize {
        availableSize ?? NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
    }
    private var panelWidth: CGFloat { min(1080, max(640, screenSize.width - 48)) }
    private var contentWidth: CGFloat { panelWidth - 48 }
    private var appSection: PowerMenuState.Section? {
        state.sections.first { section in section.choices.allSatisfy { isApp($0) } }
    }
    private var actionSections: [PowerMenuState.Section] {
        state.sections.filter { $0.id != appSection?.id }
    }
    private var contentHeight: CGFloat {
        var height: CGFloat = 0
        if let appSection {
            height += sectionHeight(appSection, tileHeight: PowerMenuActionCard.applicationHeight) + 26
            if !actionSections.isEmpty { height += 18 }
        }
        for section in actionSections { height += sectionHeight(section, tileHeight: PowerMenuActionCard.commandHeight) + 22 }
        height += CGFloat(max(0, actionSections.count - 1)) * sectionGap
        return height
    }
    private func sectionHeight(_ section: PowerMenuState.Section, tileHeight: CGFloat) -> CGFloat {
        let count = rows(in: section)
        let tileHeightTotal = CGFloat(count) * tileHeight
        let gapsTotal = CGFloat(max(0, count - 1)) * gap
        return tileHeightTotal + gapsTotal
    }
    private var bodyHeight: CGFloat {
        min(contentHeight, max(200, min(880, screenSize.height - 48) - 148))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header.frame(height: 38)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        if let appSection {
                            appArea(appSection)
                            if !actionSections.isEmpty {
                                Divider().opacity(0.55).padding(.vertical, 8)
                            }
                        }
                        VStack(alignment: .leading, spacing: sectionGap) {
                            ForEach(actionSections) { section in
                                VStack(alignment: .leading, spacing: 6) {
                                    Label(section.title, systemImage: sectionSymbol(section))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.primary.opacity(0.7))
                                        .frame(height: 16, alignment: .leading)
                                    cards(in: section)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 2).padding(.vertical, 2)
                }
                .allowsHitTesting(state.appOption == nil)
                .scrollIndicators(.automatic)
                .onChange(of: state.selection.id) { _, id in
                    guard contentHeight > bodyHeight else { return }
                    proxy.scrollTo(id)
                }
            }
            .frame(height: bodyHeight + 4)
            footer.frame(height: 26)
        }
        .overlayPreferenceValue(SelectedAppAnchor.self) { anchor in
            if let anchor, let option = state.appOption {
                GeometryReader { geometry in
                    let rect = geometry[anchor]
                    let width: CGFloat = 180
                    let x = rect.maxX + width + 8 <= geometry.size.width
                        ? rect.maxX + 8 : rect.minX - width - 8
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.selection.title).font(.headline).lineLimit(1).padding(6)
                        optionRow(state.canQuitSelectedApp ? "切换到 App" : "打开 App", symbol: "arrow.up.forward.app", selected: option == .open)
                        optionRow(state.canQuitSelectedApp ? "退出 App · 按 OK" : "退出 App · 未运行", symbol: "rectangle.portrait.and.arrow.right", selected: option == .quit)
                            .opacity(state.canQuitSelectedApp ? 1 : 0.45)
                    }
                    .padding(8).frame(width: width)
                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.18)))
                    .shadow(radius: 8).offset(x: max(0, x), y: max(0, min(rect.minY, geometry.size.height - 132)))
                    .allowsHitTesting(false)
                }
            }
        }
        .padding(24)
        .frame(width: panelWidth)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 28, y: 12)
    }

    private func optionRow(_ title: String, symbol: String, selected: Bool) -> some View {
        Label(title, systemImage: symbol).font(.callout).padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 18, weight: .medium)).foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            Text("控制中心").font(.system(size: 22, weight: .semibold))
            Spacer()
            Text("方向键选择  ·  OK 执行  ·  返回关闭")
                .font(.caption).foregroundStyle(.secondary)
            Button { onSelect(.cancel) } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Color.primary.opacity(0.06), in: Circle())
                    .overlay(Circle().stroke(state.selection.id == "cancel" ? Color.accentColor : .clear, lineWidth: 2))
            }
            .buttonStyle(.plain).help("关闭控制中心（返回键）")
            .disabled(state.isExecuting)
            .accessibilityLabel("关闭控制中心")
        }
    }

    private func appArea(_ section: PowerMenuState.Section) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("常用软件").font(.system(size: 13, weight: .semibold))
                Spacer()
                let runningCount = section.choices.filter { running($0) }.count
                Text("共 \(section.choices.count) 个  ·  已运行 \(runningCount) 个")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(height: 18)
            cards(in: section)
        }
    }

    private func cards(in section: PowerMenuState.Section) -> some View {
        let count = section.columnCount
        let width = (contentWidth - 4 - CGFloat(count - 1) * gap) / CGFloat(count)
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: gap), count: count),
                         alignment: .leading, spacing: gap) {
            ForEach(section.choices) { choice in
                PowerMenuActionCard(choice: choice, selected: state.selection.id == choice.id,
                    executing: state.isExecuting, confirming: confirmingID == choice.id,
                    appIcon: appIcon(for: choice), onSelect: { onSelect(choice) },
                    onFocus: { onFocus(choice) }, onConfirmed: { onConfirmed(choice) },
                    width: width, appIsRunning: running(choice), confirmationEpoch: confirmationEpoch)
                    .anchorPreference(key: SelectedAppAnchor.self, value: .bounds) {
                        state.selection.id == choice.id && state.appOption != nil ? $0 : nil
                    }
                    .id(choice.id)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 9) {
            if state.isExecuting { ProgressView().controlSize(.small) }
            else {
                Image(systemName: state.error != nil ? "exclamationmark.triangle" : "info.circle")
                    .foregroundStyle(state.error != nil ? Color.orange : .secondary)
            }
            Text(detailText).lineLimit(1).help(detailText)
                .frame(maxWidth: .infinity, alignment: .leading)
            if confirmingID != nil {
                Text("继续按住…").foregroundStyle(.red)
            } else if state.selection.command?.requiresHoldConfirmation == true {
                Text("按住 OK 0.6 秒确认").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12)).foregroundStyle(.secondary)
    }

    private var detailText: String {
        if state.appOption != nil { return "上下选择操作，返回收起菜单。" }
        if let error = state.error { return error }
        if state.isExecuting { return "正在请求\(state.selection.title)…" }
        if state.selection.id == "cancel" { return "按返回关闭，或用方向键继续选择。" }
        if state.selection.section == "小米电视", let televisionStatus { return televisionStatus }
        if isApp(state.selection) { return "OK 打开或切换  ·  菜单键查看软件选项" }
        return state.selection.detail ?? "\(state.selection.title)"
    }
    private func rows(in section: PowerMenuState.Section) -> Int {
        (section.choices.count + section.columnCount - 1) / section.columnCount
    }
    private func isApp(_ choice: PowerMenuState.Choice) -> Bool {
        if case .launchApp = choice.command { return true }
        return false
    }
    private func running(_ choice: PowerMenuState.Choice) -> Bool {
        guard case .launchApp(let id) = choice.command else { return false }
        return runningAppIDs.contains(id.lowercased())
    }
    private func appIcon(for choice: PowerMenuState.Choice) -> NSImage? {
        guard case .launchApp(let id) = choice.command else { return nil }
        return favoriteApps.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }?.icon
    }
    private func sectionSymbol(_ section: PowerMenuState.Section) -> String {
        switch section.title {
        case "小米电视": "tv"
        case "工作区": "rectangle.3.group"
        case "媒体": "playpause"
        case "这台 Mac": "desktopcomputer"
        default: "app.badge"
        }
    }
}
