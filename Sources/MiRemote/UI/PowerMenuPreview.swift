import AppKit
import SwiftUI

/// Synthetic layout proof; no TV connection, real applications, or power requests.
@MainActor
enum PowerMenuPreview {
    static func render(to url: URL) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        var state = PowerMenuState()
        let apps = ["com.apple.Safari", "com.apple.Terminal", "com.apple.finder"].compactMap { DockApplications.resolve($0) }
        state.open(choices: PowerMenuCatalog.choices(televisionConfigured: true,
            currentAppName: "示例应用", douyinRunning: true, apps: apps.map { (id: $0.id, title: $0.name) }))
        if let section = ProcessInfo.processInfo.environment["MIREMOTE_PREVIEW_SECTION"] {
            state.focusSection(section)
        }
        let view = PowerMenuView(state: state, onSelect: { _ in }, favoriteApps: apps)
            .padding(32).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
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
