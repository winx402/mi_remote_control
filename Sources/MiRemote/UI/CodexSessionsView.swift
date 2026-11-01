import SwiftUI

/// 只呈现用户设置的会话名和更新时间，不把提示词预览或完整路径带进浮层。
struct CodexSessionsView: View {
    let snapshot: CodexSessions.Snapshot
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
                    Text("\(selected + 1) / \(snapshot.entries.count)")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if snapshot.entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: snapshot.error == nil ? "text.bubble" : "exclamationmark.bubble")
                        .font(.system(size: 30)).foregroundStyle(.secondary)
                    Text(snapshot.isLoading ? "正在读取本地会话…"
                         : snapshot.error == nil ? "没有可打开的本地会话" : "无法读取会话")
                        .font(.body)
                }
                .frame(maxWidth: .infinity).frame(height: 150)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(snapshot.entries.enumerated()), id: \.element.id) { index, entry in
                                row(entry, selected: index == selected).id(entry.id)
                            }
                        }
                        .padding(.horizontal, 4).padding(.vertical, 5)
                    }
                    .frame(height: 360)
                    .onAppear { scroll(proxy) }
                    .onChange(of: selected) { _, _ in scroll(proxy) }
                    .onChange(of: snapshot.entries.map(\.id)) { _, _ in scroll(proxy) }
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
            Text("↑↓ 选择 · 按住连续移动 · ←→ 翻页 · OK 打开 · 返回 / Home / TV 取消")
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
            proxy.scrollTo(snapshot.entries[selected].id, anchor: .center)
        }
    }

    private func row(_ entry: CodexSessions.Entry, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left")
                .font(.body).foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .frame(width: 24)
            Text(entry.title)
                .font(.body.weight(selected ? .semibold : .regular))
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
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
