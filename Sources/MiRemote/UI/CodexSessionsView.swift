import SwiftUI

/// 只呈现项目、宿主、用户设置的会话名和更新时间。
struct CodexSessionsView: View {
    let snapshot: CodexSessions.Snapshot
    let list: CodexSessionList
    let selected: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: "text.bubble")
                Text("Codex 会话").font(.headline)
                Spacer()
                if snapshot.isLoading {
                    ProgressView().controlSize(.small)
                    Text("读取中…").font(.callout).foregroundStyle(.secondary)
                } else if !snapshot.entries.isEmpty {
                    Text("\(list.groups.count) 个项目 · \(selected + 1) / \(snapshot.entries.count)")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if snapshot.entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: snapshot.error == nil ? "text.bubble" : "exclamationmark.bubble")
                        .font(.system(size: 30)).foregroundStyle(.secondary)
                    Text(snapshot.isLoading ? "正在读取会话…"
                         : snapshot.error == nil ? "没有可打开的会话" : "无法读取会话")
                        .font(.body)
                }
                .frame(maxWidth: .infinity).frame(height: 150)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 4, pinnedViews: [.sectionHeaders]) {
                            ForEach(list.groups) { group in
                                Section {
                                    ForEach(Array(group.entries.enumerated()), id: \.element.identityKey) { offset, entry in
                                        row(entry, selected: group.startIndex + offset == selected).id(entry.identityKey)
                                    }
                                } header: {
                                    sectionHeader(group)
                                }
                            }
                        }
                        .padding(.horizontal, 4).padding(.vertical, 5)
                    }
                    .frame(height: 360)
                    .onAppear { scroll(proxy) }
                    .onChange(of: selected) { _, _ in scroll(proxy) }
                    .onChange(of: snapshot.entries.map(\.identityKey)) { _, _ in scroll(proxy) }
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
        .frame(width: 660)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.overlay))
        .overlay(RoundedRectangle(cornerRadius: Radius.overlay)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        .shadow(radius: 24, y: 8)
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard snapshot.entries.indices.contains(selected) else { return }
        withAnimation(Motion.select) {
            proxy.scrollTo(snapshot.entries[selected].identityKey, anchor: .center)
        }
    }

    private func sectionHeader(_ group: CodexSessionList.Group) -> some View {
        HStack(spacing: 8) {
            Image(systemName: group.isRemote ? "network" : "folder")
            Text(group.title).fontWeight(.semibold).lineLimit(1)
            Text("\(group.entries.count)").monospacedDigit()
            Spacer()
            Text(group.isRemote ? "远程 · \(group.hostTitle)" : group.hostTitle)
                .lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.secondary.opacity(0.10), in: Capsule())
        }
        .font(.callout).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(.regularMaterial)
        .accessibilityElement(children: .combine)
    }

    private func row(_ entry: CodexSessions.Entry, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isRemote ? "network" : "bubble.left")
                .font(.body).foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .frame(width: 24)
            Text(entry.title)
                .font(.body.weight(selected ? .semibold : .regular))
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
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
