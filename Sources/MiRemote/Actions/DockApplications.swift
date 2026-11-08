import AppKit
import Foundation

/// 程序坞固定 App 的只读目录；不修改 Dock 偏好，也不把最近使用的 App 混入固定区。
@MainActor
enum DockApplications {
    struct Entry: Identifiable {
        let id: String
        let name: String
        let url: URL
        let icon: NSImage
        var bundleID: String { id }
    }

    static func pinned() -> [Entry] {
        let tiles = UserDefaults(suiteName: "com.apple.dock")?
            .array(forKey: "persistent-apps") as? [[String: Any]] ?? []
        var seen = Set<String>()
        return tiles.compactMap { tile in
            guard let data = tile["tile-data"] as? [String: Any],
                  let file = data["file-data"] as? [String: Any],
                  let value = file["_CFURLString"] as? String,
                  let url = fileURL(value),
                  let item = entry(at: url),
                  seen.insert(item.id.lowercased()).inserted else { return nil }
            let label = (data["file-label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Entry(id: item.id, name: label?.isEmpty == false ? label! : item.name,
                         url: item.url, icon: item.icon)
        }
    }

    static func resolve(_ bundleID: String) -> Entry? {
        guard !bundleID.isEmpty else { return nil }
        if let pinned = pinned().first(where: { $0.id.caseInsensitiveCompare(bundleID) == .orderedSame }) {
            return pinned
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let item = entry(at: url),
           item.id.caseInsensitiveCompare(bundleID) == .orderedSame {
            return item
        }
        return nil
    }

    /// NSWorkspace 正常启动/激活，保留 App 自己的打开窗口行为。
    static func launch(_ entry: Entry) {
        guard let current = self.entry(at: entry.url), current.id == entry.id else { return }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: entry.id)
            .first(where: { !$0.isTerminated }) {
            WindowSwitcher.activateApplication(running)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.allowsRunningApplicationSubstitution = true
        NSWorkspace.shared.openApplication(at: current.url, configuration: configuration) { _, error in
            if error != nil { log("程序坞应用启动失败") }
        }
    }

    private static func entry(at candidate: URL) -> Entry? {
        guard candidate.isFileURL else { return nil }
        let url = candidate.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory = ObjCBool(false)
        guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier, !bundleID.isEmpty,
              bundle.executableURL != nil else { return nil }
        let name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.localizedInfoDictionary?["CFBundleName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return Entry(id: bundleID, name: name, url: url,
                     icon: NSWorkspace.shared.icon(forFile: url.path))
    }

    private static func fileURL(_ value: String) -> URL? {
        if let url = URL(string: value), url.isFileURL { return url }
        return value.hasPrefix("/") ? URL(fileURLWithPath: value) : nil
    }
}
