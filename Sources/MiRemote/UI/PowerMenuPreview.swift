import AppKit
import SwiftUI

/// Synthetic layout proof; no TV connection, real applications, or power requests.
@MainActor
enum PowerMenuPreview {
    static func render(to url: URL) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let light = ProcessInfo.processInfo.environment["MIREMOTE_PREVIEW_LIGHT"] == "1"
        NSApp.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        var state = PowerMenuState()
        let base = ["com.apple.Safari", "com.apple.Terminal", "com.apple.finder", "com.apple.systempreferences",
                    "com.apple.Preview", "com.apple.Music", "com.apple.Notes", "com.apple.Maps"]
            .compactMap { DockApplications.resolve($0) }
        let dense = ProcessInfo.processInfo.environment["MIREMOTE_PREVIEW_DENSE"] == "1"
        let apps = dense && !base.isEmpty ? (0..<18).map { index in
            let item = base[index % base.count]
            return DockApplications.Entry(id: "preview.app.\(index)", name: item.name,
                                          url: item.url, icon: item.icon)
        } : base
        let running = Set(apps.prefix(dense ? 13 : 3).map { $0.id.lowercased() })
        state.open(choices: PowerMenuCatalog.choices(televisionConfigured: true,
            currentAppName: "示例应用", douyinRunning: true, apps: apps.map { (id: $0.id, title: $0.name) }))
        if let section = ProcessInfo.processInfo.environment["MIREMOTE_PREVIEW_SECTION"] {
            state.focusSection(section)
        }
        let compact = ProcessInfo.processInfo.environment["MIREMOTE_PREVIEW_COMPACT"] == "1"
        let view = PowerMenuView(state: state, onSelect: { _ in }, favoriteApps: apps,
                                runningAppIDs: running,
                                availableSize: CGSize(width: 1280, height: compact ? 720 : 960))
            .padding(32).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, light ? .light : .dark)
        // A macOS ScrollView is AppKit-backed and ImageRenderer omits its content.
        // Lay out and cache the native hierarchy instead of producing a blank list.
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw NSError(domain: "MiRemotePreview", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "电源面板预览渲染失败"])
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "MiRemotePreview", code: 3)
        }
        try png.write(to: url, options: .atomic)
    }
}
