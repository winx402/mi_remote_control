import SwiftUI

enum DouyinMenuItem: Hashable {
    case playback, enableSound, fullscreen, chooseRoom, clearClutter, retryPlayerOptions, collapseMore, returnToLargeWindow
    case room(String), category(String)
    case playerGroup(DouyinLiveOptions.Group)
    case playerOption(DouyinLiveOptions.Group, DouyinLiveOptions.Option)

    static let categories: [Self] = ["精选", "推荐", "关注", "直播"].map(Self.category)
    static let playbackControls: [Self] = [.playback, .enableSound, .fullscreen]
    static let roomControls: [Self] = [.chooseRoom, .clearClutter]
    static let functions = playbackControls + roomControls

    var title: String {
        switch self {
        case .playback: "播放 / 暂停"
        case .enableSound: "开启声音"
        case .fullscreen: "全屏播放"
        case .returnToLargeWindow: "返回大窗播放"
        case .chooseRoom: "选择直播间"
        case .clearClutter: "清除牛皮癣"
        case .collapseMore: "收起更多设置"
        case .retryPlayerOptions: "重新读取播放器选项"
        case .room(let name), .category(let name): name
        case .playerGroup(let group): Self.groupTitle(group)
        case .playerOption(_, let option): option.title
        }
    }

    var symbol: String {
        switch self {
        case .playback: "playpause.fill"
        case .enableSound: "speaker.wave.2.fill"
        case .fullscreen: "arrow.up.left.and.arrow.down.right"
        case .returnToLargeWindow: "pip.exit"
        case .chooseRoom: "rectangle.stack.fill"
        case .clearClutter: "eraser.fill"
        case .collapseMore: "chevron.up.circle"
        case .retryPlayerOptions: "arrow.clockwise"
        case .room: "person.fill"
        case .playerGroup(let group), .playerOption(let group, _): group.symbol
        case .category(let name):
            switch name {
            case "精选": "sparkles"
            case "推荐": "heart.fill"
            case "关注": "person.2.fill"
            case "直播": "dot.radiowaves.left.and.right"
            default: "rectangle.grid.1x2.fill"
            }
        }
    }

    static func groupTitle(_ group: DouyinLiveOptions.Group) -> String {
        group.title.components(separatedBy: " · ").first ?? group.title
    }

    var isSettingOption: Bool {
        guard case .playerOption(_, let option) = self else { return false }
        return !["perform", "reset", "increase", "decrease"].contains(option.id)
    }

    static func groupSection(_ group: DouyinLiveOptions.Group) -> String {
        if group.id.hasPrefix("danmaku.") { return "弹幕设置" }
        if group.id.hasPrefix("gift.") { return "礼物设置" }
        return "播放器设置"
    }

    var isChecked: Bool {
        if case .playerOption(_, let option) = self { return option.isSelected }
        return false
    }
}

/// The same row geometry drives rendering and the physical remote. Each section
/// starts a new row; moving vertically never assumes the previous row was full.
struct DouyinMenuLayout {
    struct Section: Identifiable {
        let title: String?
        let indices: [Int]
        let columnCount: Int
        var id: Int { indices.first ?? -1 }
        var rows: [[Int]] {
            stride(from: 0, to: indices.count, by: columnCount).map {
                Array(indices[$0..<min($0 + columnCount, indices.count)])
            }
        }
    }

    let panelWidth: CGFloat
    let sections: [Section]
    let isList: Bool
    let isOptions: Bool
    private let ignoresHorizontalInput: Bool
    static let cardHeight: CGFloat = 40
    static let gap: CGFloat = 4
    static let sectionGap: CGFloat = 8
    static let padding: CGFloat = 16

    init(items: [DouyinMenuItem], availableSize: CGSize) {
        let list: Bool
        switch items.first {
        case .room?, .category?: list = true
        default: list = false
        }
        let options: Bool
        if case .playerOption? = items.first { options = true } else { options = false }
        isList = list
        if case .category? = items.first { ignoresHorizontalInput = true }
        else { ignoresHorizontalInput = false }
        isOptions = options
        let maxWidth: CGFloat = list ? 500 : options ? 640 : 920
        panelWidth = min(maxWidth, max(1, availableSize.width - (availableSize.width < 600 ? 24 : 48)))
        let width = panelWidth - Self.padding * 2 - 8
        let columns = list ? 1 : options ? (width >= 340 ? 2 : 1)
            : width >= 840 ? 6 : width >= 720 ? 4 : width >= 520 ? 3 : width >= 340 ? 2 : 1
        if list || options {
            sections = [Section(title: items.contains(where: \.isChecked) ? "勾选为当前设置" : nil,
                                indices: Array(items.indices), columnCount: columns)]
        } else {
            var grouped: [(String, [Int])] = []
            for index in items.indices {
                let title: String
                switch items[index] {
                case .chooseRoom, .clearClutter: title = "直播间"
                case .playerGroup(let group): title = DouyinMenuItem.groupSection(group)
                case .retryPlayerOptions, .collapseMore: title = "播放器设置"
                default: title = "播放"
                }
                if grouped.last?.0 == title { grouped[grouped.count - 1].1.append(index) }
                else { grouped.append((title, [index])) }
            }
            sections = grouped.map { Section(title: $0.0, indices: $0.1, columnCount: columns) }
        }
    }

    var rows: [[Int]] { sections.flatMap(\.rows) }
    var contentHeight: CGFloat {
        sections.reduce(0) { result, section in
            result + CGFloat(section.rows.count) * Self.cardHeight
                + CGFloat(max(0, section.rows.count - 1)) * Self.gap
                + (section.title == nil ? 0 : 18)
        } + CGFloat(max(0, sections.count - 1)) * Self.sectionGap + 8
    }

    func viewportHeight(availableHeight: CGFloat, hasMessage: Bool) -> CGFloat {
        // 104 points contain padding, header, footer and their spacing. Errors
        // reserve two compact lines. Short displays scroll the same grid rows.
        min(contentHeight, max(1, availableHeight - 48 - 104 - (hasMessage ? 46 : 0)))
    }

    func move(_ index: Int, key: RemoteKey) -> Int {
        let rows = rows
        guard let row = rows.firstIndex(where: { $0.contains(index) }),
              let column = rows[row].firstIndex(of: index),
              let last = rows.last?.last else { return 0 }
        switch key {
        case .left, .right:
            guard !ignoresHorizontalInput else { return index }
            let delta = key == .left ? -1 : 1
            let line = rows[row]
            // A one-item row has no horizontal neighbor. Continue in menu order
            // so even the last standalone tile can wrap directly to the first.
            if line.count == 1 { return (index + delta + last + 1) % (last + 1) }
            return line[(column + delta + line.count) % line.count]
        case .up, .down:
            let delta = key == .up ? -1 : 1
            // The category picker keeps its original single-column navigation.
            let target = ignoresHorizontalInput ? min(max(row + delta, 0), rows.count - 1)
                : (row + delta + rows.count) % rows.count
            return rows[target][min(column, rows[target].count - 1)]
        default: return index
        }
    }

    static func wrapSelfCheck() -> Bool {
        let size = CGSize(width: 1280, height: 720)
        let grid = Self(items: DouyinMenuItem.functions, availableSize: size)
        let rooms = Self(items: [.room("A"), .room("B")], availableSize: size)
        let categories = Self(items: DouyinMenuItem.categories, availableSize: size)
        let singleTile = Self(items: [.playback, .enableSound, .chooseRoom], availableSize: size)
        return grid.rows == [[0, 1, 2], [3, 4]]
            && grid.move(0, key: .left) == 2 && grid.move(2, key: .right) == 0
            && grid.move(0, key: .up) == 3 && grid.move(3, key: .down) == 0
            && grid.move(2, key: .down) == 4 && grid.move(4, key: .right) == 3
            && singleTile.move(2, key: .right) == 0
            && rooms.move(0, key: .up) == 1 && rooms.move(1, key: .down) == 0
            && rooms.move(0, key: .left) == 1 && rooms.move(1, key: .right) == 0
            && categories.move(1, key: .right) == 1 && categories.move(0, key: .up) == 0
            && Self(items: [], availableSize: size).move(0, key: .down) == 0
    }
}

struct DouyinLiveMenu: View {
    let items: [DouyinMenuItem]
    let selected: Int
    let activate: (DouyinMenuItem) -> Void
    let onBack: (() -> Void)?
    let message: String?

    init(items: [DouyinMenuItem], selected: Int, activate: @escaping (DouyinMenuItem) -> Void,
         onBack: (() -> Void)? = nil, message: String? = nil) {
        self.items = items
        self.selected = selected
        self.activate = activate
        self.onBack = onBack
        self.message = message
    }

    private var isRoomList: Bool {
        if case .room = items.first { return true }
        return false
    }
    private var isCategoryList: Bool {
        if case .category = items.first { return true }
        return false
    }
    private var optionGroup: DouyinLiveOptions.Group? {
        if case .playerOption(let group, _) = items.first { return group }
        return nil
    }
    private var menuTitle: String {
        if let optionGroup { return DouyinMenuItem.groupTitle(optionGroup) }
        if isCategoryList { return "切换栏目" }
        if isRoomList { return "关注的直播间" }
        return "直播控制"
    }
    private var headerSymbol: String {
        if let optionGroup { return optionGroup.symbol }
        if isCategoryList { return "square.grid.2x2.fill" }
        if isRoomList { return "person.2.wave.2.fill" }
        return "play.tv.fill"
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = DouyinMenuLayout(items: items, availableSize: geometry.size)
            panel(layout: layout, viewportHeight: layout.viewportHeight(
                availableHeight: geometry.size.height, hasMessage: message != nil))
                .frame(width: layout.panelWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func panel(layout: DouyinMenuLayout, viewportHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header.frame(height: 32)
            if let message {
                Label(message, systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(height: 36, alignment: .leading)
                    .help(message)
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: DouyinMenuLayout.sectionGap) {
                        ForEach(layout.sections) { section in
                            VStack(alignment: .leading, spacing: DouyinMenuLayout.gap) {
                                if let title = section.title {
                                    Text(title)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.leading, 3)
                                        .frame(height: 14, alignment: .leading)
                                }
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DouyinMenuLayout.gap),
                                                         count: section.columnCount),
                                          spacing: DouyinMenuLayout.gap) {
                                    ForEach(section.indices, id: \.self) { index in
                                        DouyinMenuCard(item: items[index], selected: selected == index) {
                                            activate(items[index])
                                        }
                                        .id(index)
                                    }
                                }
                            }
                        }
                    }
                    .padding(4)
                }
                .scrollIndicators(.automatic)
                .frame(height: viewportHeight)
                .onAppear { revealSelection(in: proxy, layout: layout, viewportHeight: viewportHeight) }
                .onChange(of: selected) { _, _ in revealSelection(in: proxy, layout: layout, viewportHeight: viewportHeight) }
                .onChange(of: items) { _, _ in revealSelection(in: proxy, layout: layout, viewportHeight: viewportHeight) }
                .onChange(of: viewportHeight) { _, _ in revealSelection(in: proxy, layout: layout, viewportHeight: viewportHeight) }
                .onChange(of: layout.panelWidth) { _, _ in revealSelection(in: proxy, layout: layout, viewportHeight: viewportHeight) }
            }
            footer.frame(height: 20)
        }
        .padding(DouyinMenuLayout.padding)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 28, y: 12)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: headerSymbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            Text(menuTitle).font(.system(size: 20, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 8)
            Text(isRoomList ? "\(items.count) 个" : "\(items.count) 项")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: isRoomList || isCategoryList ? "arrow.up.arrow.down" : "arrow.up.and.down.and.arrow.left.and.right")
            Text("选择  ·  OK 确认")
            Spacer(minLength: 8)
            if optionGroup != nil || items.contains(.collapseMore), let onBack {
                Button("返回上一级", action: onBack)
                    .buttonStyle(.plain)
                    .help("返回直播控制")
            } else {
                Text(optionGroup != nil || items.contains(.collapseMore) ? "返回上一级" : "返回关闭")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
    }

    private func revealSelection(in proxy: ScrollViewProxy, layout: DouyinMenuLayout, viewportHeight: CGFloat) {
        guard items.indices.contains(selected), layout.contentHeight > viewportHeight else { return }
        // NSScrollView must finish its first layout before resolving a lazy
        // grid item. Defer initial/resize scrolling to the next main-loop turn.
        DispatchQueue.main.async { proxy.scrollTo(selected, anchor: .center) }
    }
}

private struct DouyinMenuCard: View {
    let item: DouyinMenuItem
    let selected: Bool
    let activate: () -> Void
    @State private var hovered = false

    private var detail: String? {
        guard case .playerGroup(let group) = item,
              let separator = group.title.range(of: " · ") else { return nil }
        return String(group.title[separator.upperBound...])
    }

    var body: some View {
        Button(action: activate) {
            HStack(spacing: 6) {
                Image(systemName: item.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 22, height: 22)
                    .foregroundStyle(Color.accentColor)
                    .background(Color.accentColor.opacity(selected ? 0.14 : 0.07),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .lineLimit(detail == nil ? 2 : 1)
                        .multilineTextAlignment(.leading)
                        .minimumScaleFactor(0.85)
                    if let detail {
                        Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if item.isSettingOption {
                    Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .opacity(item.isChecked ? 1 : 0.3)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .opacity(selected ? 0.9 : 0.4)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .frame(height: DouyinMenuLayout.cardHeight)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(hovered ? 0.10 : 0.045))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.04),
                                  lineWidth: selected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(detail.map { "\(item.title) · \($0)" } ?? item.title)
        .accessibilityLabel(item.title)
        .accessibilityValue(item.isSettingOption ? (item.isChecked ? "当前设置" : "未选中") : (detail ?? (selected ? "当前焦点" : "")))
        .accessibilityAddTraits((item.isSettingOption ? item.isChecked : selected) ? [.isSelected] : [])
    }
}
