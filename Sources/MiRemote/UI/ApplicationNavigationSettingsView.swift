import AppKit
import SwiftUI

/// App-specific overrides; an absent rule keeps the application's native keys.
@MainActor
struct ApplicationNavigationSettingsView: View {
    let availableApps: [DockApplications.Entry]
    @Binding var profiles: [String: AppNavigationProfile]?
    let status: String

    @State private var selectedAppID = ""

    private struct AppChoice: Identifiable {
        let id: String
        let entry: DockApplications.Entry?
        let configured: Bool

        var name: String { entry?.name ?? id }
    }

    private var appChoices: [AppChoice] {
        let configuredIDs = Set((profiles ?? [:]).keys)
        var entries: [String: DockApplications.Entry] = [:]
        for app in availableApps where entries[app.id] == nil {
            entries[app.id] = app
        }
        let ids = configuredIDs.union(entries.keys)
        return ids.map { id in
            AppChoice(id: id, entry: entries[id] ?? DockApplications.resolve(id),
                      configured: configuredIDs.contains(id))
        }.sorted { lhs, rhs in
            if lhs.configured != rhs.configured { return lhs.configured }
            let comparison = lhs.name.localizedStandardCompare(rhs.name)
            return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
        }
    }

    private var currentAppID: String {
        let choices = appChoices
        return choices.contains(where: { $0.id == selectedAppID })
            ? selectedAppID : choices.first?.id ?? ""
    }

    private var currentProfile: AppNavigationProfile {
        profiles?[currentAppID] ?? AppNavigationProfile()
    }

    var body: some View {
        let choices = appChoices
        let currentID = currentAppID
        let selected = choices.first { $0.id == currentID }

        VStack(alignment: .leading, spacing: 12) {
            Text("仅在已配置的 App 中启用；其他 App 保留原有按键。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let selected {
                Picker("应用", selection: Binding(
                    get: { currentAppID },
                    set: { selectedAppID = $0 }
                )) {
                    ForEach(choices) { app in
                        Text(app.configured ? "\(app.name) · 已配置" : app.name)
                            .tag(app.id)
                    }
                }
                .pickerStyle(.menu)

                HStack(spacing: 8) {
                    if let entry = selected.entry {
                        Image(nsImage: entry.icon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 26, height: 26)
                    } else {
                        Image(systemName: "app.dashed")
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 26)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selected.name).lineLimit(1)
                        Text(selected.entry == nil ? "未找到此应用，规则已保留。" : selected.id)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if selected.configured {
                        Button("恢复原有按键") { removeProfile(for: currentID) }
                            .controlSize(.small)
                            .help("删除此 App 的导航规则")
                            .accessibilityLabel("恢复 \(selected.name) 的原有按键")
                    }
                }

                Picker("导航方式", selection: modeBinding) {
                    Text("保留原有按键").tag(AppNavigationMode.native)
                    Text("按钮导航").tag(AppNavigationMode.buttons)
                    Text("分区导航").tag(AppNavigationMode.regions)
                }
                .pickerStyle(.menu)

                if currentProfile.mode == .regions {
                    Picker("区域行为", selection: layoutBinding) {
                        Text("自动识别").tag(AppNavigationLayout.automatic)
                        Text("聊天界面").tag(AppNavigationLayout.chat)
                        Text("视频界面").tag(AppNavigationLayout.video)
                    }
                    .pickerStyle(.menu)
                }
            } else {
                Text("暂无可配置的应用。打开应用或将它固定到 Dock 后，可在此选择。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("按钮导航：方向单按选中并高亮按钮，OK 激活。")
                Text("分区导航：左右切换区域，上下选择区域内菜单或滚动。")
                Text("区域来自当前控件层级；聊天／视频只补充操作行为，不预设区域位置。")
                Text("输入框：OK 进入输入，返回回到导航。全局长按和双击仍保留。")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Divider()
            Text(status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 ? "等待在已配置的 App 中使用导航。" : status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("当前导航状态")
                .accessibilityValue(status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? "等待在已配置的 App 中使用导航。" : status)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modeBinding: Binding<AppNavigationMode> {
        Binding(
            get: { currentProfile.mode },
            set: { mode in
                let id = currentAppID
                guard !id.isEmpty else { return }
                if mode == .native {
                    removeProfile(for: id)
                } else {
                    var updated = profiles ?? [:]
                    var profile = updated[id] ?? AppNavigationProfile()
                    profile.mode = mode
                    updated[id] = profile
                    profiles = updated
                }
            }
        )
    }

    private var layoutBinding: Binding<AppNavigationLayout> {
        Binding(
            get: { currentProfile.layout },
            set: { layout in
                let id = currentAppID
                guard !id.isEmpty, currentProfile.mode == .regions else { return }
                var updated = profiles ?? [:]
                var profile = updated[id] ?? AppNavigationProfile()
                profile.layout = layout
                updated[id] = profile
                profiles = updated
            }
        )
    }

    private func removeProfile(for id: String) {
        var updated = profiles ?? [:]
        updated.removeValue(forKey: id)
        profiles = updated.isEmpty ? nil : updated
    }
}
