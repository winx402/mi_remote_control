import SwiftUI

/// 只呈现项目、宿主、用户设置的会话名和更新时间。
struct CodexSessionsView: View {
    let snapshot: CodexSessions.Snapshot
    let list: CodexSessionList
    let tabIndex: Int
    let selected: Int
    let onTabSelected: (Int) -> Void

    private var currentTabIndex: Int? {
        guard !list.tabs.isEmpty else { return nil }
        return min(max(tabIndex, 0), list.tabs.count - 1)
    }

    private var currentTab: CodexSessionList.Tab? {
        currentTabIndex.map { list.tabs[$0] }
    }

    private var entries: [CodexSessions.Entry] { currentTab?.entries ?? [] }

    private var selectedIndex: Int? {
        guard !entries.isEmpty else { return nil }
        return min(max(selected, 0), entries.count - 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: "text.bubble")
                Text("Codex 会话").font(.headline)
                Spacer()
                if snapshot.isLoading {
                    ProgressView().controlSize(.small)
                    Text("读取中…").font(.callout).foregroundStyle(.secondary)
                } else if let selectedIndex {
                    Text("\(selectedIndex + 1) / \(entries.count)")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if !list.tabs.isEmpty {
                projectTabs
            }
            if entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: snapshot.error == nil ? "text.bubble" : "exclamationmark.bubble")
                        .font(.system(size: 30)).foregroundStyle(.secondary)
                    Text(snapshot.isLoading ? "正在读取会话…"
                         : snapshot.error == nil ? "没有可打开的会话" : "无法读取会话")
                        .font(.body)
                }
                .frame(maxWidth: .infinity).frame(height: list.tabs.count > 1 ? 360 : 150)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(entries.enumerated()), id: \.element.identityKey) { index, entry in
                                row(entry, selected: index == selectedIndex)
                                    .id(entry.identityKey)
                            }
                        }
                        .padding(.horizontal, 4).padding(.vertical, 5)
                    }
                    .frame(height: 360)
                    .onAppear { scroll(proxy) }
                    .onChange(of: selected) { _, _ in scroll(proxy) }
                    .onChange(of: currentTab?.id) { _, _ in scroll(proxy) }
                    .onChange(of: entries.map(\.identityKey)) { _, _ in scroll(proxy) }
                }
            }
            if let error = snapshot.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let notice = snapshot.notice {
                Text(notice).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let currentIndex = CodexSessionList.currentIndex(in: snapshot) {
                let current = snapshot.entries[currentIndex]
                Label("当前：\(current.groupTitle) · \(current.title)", systemImage: "location.fill")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text("↑↓ 选择 · 按住连续移动 · ←→ 切项目 · OK 打开 · 返回 / Home / TV 取消")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(Spacing.sheetPadding)
        .frame(width: min(742, (NSScreen.main?.visibleFrame.width ?? 782) - 40))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.overlay))
        .overlay(RoundedRectangle(cornerRadius: Radius.overlay)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        .shadow(radius: 24, y: 8)
    }

    private var projectTabs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 8) {
                    ForEach(Array(list.tabs.enumerated()), id: \.element.id) { index, tab in
                        projectTab(tab, index: index).id(tab.id)
                    }
                }
                .padding(.horizontal, 4).padding(.vertical, 5)
            }
            .frame(height: 76)
            .onAppear { scrollTab(proxy) }
            .onChange(of: currentTab?.id) { _, _ in scrollTab(proxy) }
        }
    }

    private func projectTab(_ tab: CodexSessionList.Tab, index: Int) -> some View {
        let isSelected = index == currentTabIndex
        return Button {
            onTabSelected(index)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: index == 0 ? "clock" : tab.isRemote ? "network" : "folder")
                    Text(tab.title).fontWeight(isSelected ? .semibold : .regular)
                        .lineLimit(1).truncationMode(.middle)
                    Text("\(tab.entries.count)").font(.caption).monospacedDigit()
                }
                Text(subtitle(for: tab, recent: index == 0))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 12)
            .frame(width: 130, height: 52, alignment: .leading)
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .background(isSelected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: Radius.small))
            .overlay(RoundedRectangle(cornerRadius: Radius.small)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .help([tab.title, tab.isRemote ? "远程" : nil, tab.hostTitle].compactMap { $0 }.joined(separator: " · "))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func subtitle(for tab: CodexSessionList.Tab, recent: Bool) -> String {
        if recent { return "按更新时间" }
        guard tab.isRemote else { return "本机" }
        return tab.hostTitle.map { "远程 · " + $0 } ?? "远程"
    }

    private func scrollTab(_ proxy: ScrollViewProxy) {
        guard let currentTab else { return }
        withAnimation(Motion.select) {
            proxy.scrollTo(currentTab.id, anchor: .center)
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let selectedIndex else { return }
        withAnimation(Motion.select) {
            proxy.scrollTo(entries[selectedIndex].identityKey, anchor: .center)
        }
    }

    private func row(_ entry: CodexSessions.Entry, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isRemote ? "network" : "bubble.left")
                .font(.body).foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.body.weight(selected ? .semibold : .regular))
                    .lineLimit(2)
                if currentTabIndex == 0 {
                    Text("\(entry.groupTitle) · \(entry.isRemote ? "远程 · " : "")\(entry.hostTitle)")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if entry.identityKey == snapshot.currentIdentityKey {
                Text("当前会话").font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
            if entry.updatedAt > 0 {
                Text(Date(timeIntervalSince1970: entry.updatedAt), style: .relative)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .frame(width: 98, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(minHeight: 50)
        .background(selected ? Color.accentColor.opacity(0.14) : Color.clear,
                    in: RoundedRectangle(cornerRadius: Radius.small))
        .overlay(RoundedRectangle(cornerRadius: Radius.small)
            .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
