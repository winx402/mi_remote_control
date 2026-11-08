import AppKit
import SwiftUI

/// `nil` follows the Dock; an empty custom list deliberately hides the app row.
@MainActor
struct MenuFavoriteAppsSettingsView: View {
    let available: [DockApplications.Entry]
    @Binding var selectedIDs: [String]?

    @State private var searchText = ""

    private var custom: Bool { selectedIDs != nil }
    private var chosenIDs: [String] { selectedIDs ?? [] }
    private var matchingApps: [DockApplications.Entry] {
        available.filter {
            searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.bundleID.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("自定义常用 App", isOn: Binding(
                    get: { custom },
                    set: { enabled in
                        selectedIDs = enabled ? Array(DockApplications.pinned().prefix(6).map(\.id)) : nil
                    }
                ))
                .toggleStyle(.switch)
                Spacer()
                if custom {
                    Button("恢复默认") { selectedIDs = nil }
                        .controlSize(.small)
                }
            }

            Text(custom ? "最多选择 6 个 App；取消全部选择可隐藏常用区。" : "默认显示 Dock 中固定的 App，最多 6 个。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if custom {
                if !chosenIDs.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(chosenIDs.enumerated()), id: \.element) { index, id in
                            chosenRow(id: id, index: index)
                            if index < chosenIDs.count - 1 { Divider() }
                        }
                    }
                    .padding(.horizontal, 10)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                }

                HStack {
                    TextField("搜索应用", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                    Text("\(chosenIDs.count) / 6")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        ForEach(matchingApps, id: \.id) { app in
                            Toggle(isOn: selectionBinding(for: app.id)) {
                                HStack(spacing: 7) {
                                    Image(nsImage: app.icon)
                                        .resizable().scaledToFit()
                                        .frame(width: 22, height: 22)
                                    Text(app.name).lineLimit(1)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .disabled(!chosenIDs.contains(app.id) && chosenIDs.count >= 6)
                            .help(app.name)
                        }
                        if matchingApps.isEmpty {
                            Text("没有匹配的应用")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(3)
                }
                .frame(height: 170)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chosenRow(id: String, index: Int) -> some View {
        let app = available.first { $0.id == id } ?? DockApplications.resolve(id)
        return HStack(spacing: 8) {
            if let app {
                Image(nsImage: app.icon)
                    .resizable().scaledToFit()
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.secondary)
            }
            Text(app?.name ?? "无法找到的应用")
                .lineLimit(1)
            Spacer()
            Button { move(from: index, by: -1) } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(index == 0)
            .help("上移")
            .accessibilityLabel("上移 \(app?.name ?? id)")
            Button { move(from: index, by: 1) } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(index == chosenIDs.count - 1)
            .help("下移")
            .accessibilityLabel("下移 \(app?.name ?? id)")
            Button {
                selectedIDs = chosenIDs.filter { $0 != id }
            } label: {
                Image(systemName: "minus")
            }
            .help("移除")
            .accessibilityLabel("移除 \(app?.name ?? id)")
        }
        .controlSize(.small)
        .padding(.vertical, 7)
    }

    private func selectionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { chosenIDs.contains(id) },
            set: { enabled in
                var ids = chosenIDs
                if enabled {
                    guard !ids.contains(id), ids.count < 6 else { return }
                    ids.append(id)
                } else {
                    ids.removeAll { $0 == id }
                }
                selectedIDs = ids
            }
        )
    }

    private func move(from index: Int, by offset: Int) {
        var ids = chosenIDs
        let destination = index + offset
        guard ids.indices.contains(index), ids.indices.contains(destination) else { return }
        ids.swapAt(index, destination)
        selectedIDs = ids
    }
}
