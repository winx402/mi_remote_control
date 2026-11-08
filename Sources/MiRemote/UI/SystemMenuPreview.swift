import AppKit
import SwiftUI

/// Offscreen layout proof; no windows, keyboard events, BLE, or HID mapping.
@MainActor
enum SystemMenuPreview {
    static func render(to url: URL) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let ids = ConfigStore.loadIfExists(at: nil)?.menuFavoriteApps
        let available = ids.map { $0.compactMap { DockApplications.resolve($0) } } ?? DockApplications.pinned()
        let apps = Array(available.prefix(6))
        let view = SystemMenuDashboardView(apps: apps, selected: 0, confirming: false,
            onSelect: { _ in }, onActivate: { _ in })
            .padding(32)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cgImage = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "MiRemotePreview", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "菜单预览渲染失败"])
        }
        try png.write(to: url, options: .atomic)
    }
}
