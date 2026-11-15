import AppKit
import ApplicationServices

/// Read-only AX inventory for the menu's first paint. This deliberately never
/// reveals a toolbar, hovers an icon, sets AX attributes, or takes the action lock.
/// All AX IPC runs on a detached task; cancellation is checked between messages.
enum DouyinLiveDiscovery {
    /// Immutable AX references are compared by CFEqual on the worker only; no
    /// mutable Swift state crosses actors and the AX objects are never mutated.
    struct Anchors: @unchecked Sendable {
        let pid: pid_t
        let room: String
        let window: AXUIElement
        let player: AXUIElement
        let toolbar: AXUIElement
        let groups: [String: AXUIElement]

        func validGroupIDs(pid: pid_t, room: String?, window: AXUIElement,
                           player: AXUIElement, toolbar: AXUIElement, elements: [AXUIElement]) -> Set<String> {
            guard self.pid == pid, self.room == room, CFEqual(self.window, window),
                  CFEqual(self.player, player), CFEqual(self.toolbar, toolbar) else { return [] }
            return Set(groups.compactMap { id, anchor in
                elements.contains { CFEqual($0, anchor) } ? id : nil
            })
        }
    }
    struct Reading: Sendable {
        let pid: pid_t
        let room: String?
        let mediaURL: String?
        let isMiniWindow: Bool
        let quality: Bool
        let volume: Bool
        let rotation: Bool
        let nativeToolbar: Bool
        let needsRetry: Bool
        let cachedGroupIDs: Set<String>
    }
    struct Problem: Error, Sendable { let message: String }
    private struct Node {
        let element: AXUIElement
        let parent: Int?
        let role: String
        let classes: Set<String>
        let rect: CGRect
        let title: String
        let url: URL?
    }

    static func read(pid: pid_t, cache: Anchors? = nil) async throws -> Reading {
        let worker = Task.detached(priority: .userInitiated) { try scan(pid: pid, cache: cache) }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    private static func scan(pid: pid_t, cache: Anchors?) throws -> Reading {
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else { throw Problem(message: "控制抖音需要辅助功能权限") }
        let app = AXUIElementCreateApplication(pid)
        guard let window = try attribute(app, kAXFocusedWindowAttribute),
              CFGetTypeID(window) == AXUIElementGetTypeID() else {
            throw Problem(message: "没有找到抖音前台窗口")
        }
        let focusedWindow = window as! AXUIElement
        let geometry = try values(focusedWindow, [kAXPositionAttribute, kAXSizeAttribute, kAXMinimizedAttribute])
        let bounds = frame(geometry[0], geometry[1])
        guard bounds.width >= 320, bounds.height >= 200, geometry[2] as? Bool != true else {
            throw Problem(message: "抖音窗口当前不可用")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.45
        let sourcePage = try primaryPage(focusedWindow, deadline: min(deadline, ProcessInfo.processInfo.systemUptime + 0.12))
        var complete = true
        var nodes: [Node] = []
        var seen: [UInt: [AXUIElement]] = [:]
        func visit(_ element: AXUIElement, parent: Int?, depth: Int) throws {
            try Task.checkCancellation()
            guard nodes.count < 2_000, depth < 64, ProcessInfo.processInfo.systemUptime < deadline else {
                complete = false
                return
            }
            let hash = CFHash(element)
            guard !(seen[hash] ?? []).contains(where: { CFEqual($0, element) }) else { return }
            seen[hash, default: []].append(element)
            let info = try values(element, [kAXRoleAttribute, "AXDOMClassList", kAXPositionAttribute,
                                            kAXSizeAttribute, kAXChildrenAttribute])
            let role = info[0] as? String ?? ""
            let metadata = ["AXWebArea", "AXLink"].contains(role) ? try values(element, [kAXTitleAttribute, kAXURLAttribute]) : []
            let url = metadata.count == 2 ? parseURL(metadata[1]) : nil
            let index = nodes.count
            nodes.append(Node(element: element, parent: parent, role: role,
                              classes: Set(info[1] as? [String] ?? []), rect: frame(info[2], info[3]),
                              title: metadata.first.flatMap { $0 as? String } ?? "", url: url))
            if role == "AXWebArea", let url, !isDouyin(url), url.absoluteString != "about:blank",
               url.scheme != "blob" { return }
            for child in info[4] as? [AXUIElement] ?? [] {
                if !complete { break }
                try visit(child, parent: index, depth: depth + 1)
            }
        }
        try visit(focusedWindow, parent: nil, depth: 0)
        let pages = nodes.filter { $0.role == "AXWebArea" && $0.url.map(isDouyin) == true }
        let livePages = pages.filter { liveRoom($0) != nil }
        let boundPage = sourcePage.flatMap { liveRoom($0) != nil ? $0 : nil }
            ?? (livePages.count == 1 ? livePages.first : nil)
        let players = nodes.indices.filter {
            let area = nodes[$0].rect.intersection(bounds)
            return !nodes[$0].classes.isDisjoint(with: ["douyin-player", "xgplayer"])
                && area.width >= 250 && area.height >= 150
        }.sorted { area(nodes[$0].rect.intersection(bounds)) > area(nodes[$1].rect.intersection(bounds)) }
        let player = players.first
        if let player, players.count > 1, area(nodes[player].rect.intersection(bounds)) <= area(nodes[players[1]].rect.intersection(bounds)) * 1.5 {
            throw Problem(message: "存在多个抖音播放器，无法确认操作目标")
        }
        func belongs(_ index: Int) -> Bool {
            guard let player else { return false }
            var ancestor = nodes[index].parent
            while let current = ancestor {
                if current == player { return true }
                ancestor = nodes[current].parent
            }
            return false
        }
        let controls = nodes.indices.filter(belongs)
        func count(_ semantic: String) -> Int { controls.filter { nodes[$0].classes.contains(semantic) }.count }
        let media = nodes.compactMap(\.url).first {
            $0.scheme == "blob" && $0.absoluteString.contains("douyin.com/")
        }?.absoluteString
        let mini = complete && nodes.contains { $0.classes.contains("livingPipBackground") }
            && nodes.contains { $0.classes.contains("pip-anchor") } && media != nil && player != nil
        guard mini || boundPage != nil else { throw Problem(message: "请先进入抖音直播间") }
        // Recheck the exact focused window and source web area's live route after
        // the inventory. Same-window navigation must not publish the previous room.
        guard let latestWindow = try attribute(app, kAXFocusedWindowAttribute), CFEqual(latestWindow, focusedWindow) else {
            throw Problem(message: "抖音前台窗口已改变，请重试")
        }
        if !mini, let page = boundPage {
            let latest = try values(page.element, [kAXTitleAttribute, kAXURLAttribute])
            guard parseURL(latest[1]).flatMap(DouyinControls.liveRoomID) == liveRoom(page) else {
                throw Problem(message: "直播间已改变，请重新打开播放器设置")
            }
        }
        var cachedGroupIDs: Set<String> = []
        let toolbars = controls.filter { nodes[$0].classes.contains("douyin-player-controls") }
        if complete, !mini, let cache, let player, toolbars.count == 1 {
            cachedGroupIDs = cache.validGroupIDs(pid: pid, room: boundPage.flatMap(liveRoom), window: focusedWindow,
                                                player: nodes[player].element, toolbar: nodes[toolbars[0]].element,
                                                elements: controls.map { nodes[$0].element })
        }
        try Task.checkCancellation()
        return Reading(pid: pid, room: mini ? nil : boundPage.flatMap(liveRoom), mediaURL: media,
                       isMiniWindow: mini, quality: complete && count("QualitySwitchNewPlugin") == 1,
                       volume: complete && count("douyin-player-volume") == 1, rotation: complete && count("douyin-player-rotate") == 1,
                       nativeToolbar: !mini && boundPage != nil, needsRetry: !complete, cachedGroupIDs: cachedGroupIDs)
    }

    /// A small breadth-first route read provides the lazy native-inspection
    /// entry even if a large chat tree consumes the subsequent inventory budget.
    private static func primaryPage(_ window: AXUIElement, deadline: TimeInterval) throws -> Node? {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var offset = 0
        while offset < queue.count, offset < 64, ProcessInfo.processInfo.systemUptime < deadline {
            let (element, depth) = queue[offset]
            offset += 1
            let info = try values(element, [kAXRoleAttribute, kAXChildrenAttribute])
            if info[0] as? String == "AXWebArea" {
                let metadata = try values(element, [kAXTitleAttribute, kAXURLAttribute])
                if let url = parseURL(metadata[1]), isDouyin(url) {
                    return Node(element: element, parent: nil, role: "AXWebArea", classes: [], rect: .zero,
                                title: metadata[0] as? String ?? "", url: url)
                }
                continue
            }
            if depth < 12 { queue += (info[1] as? [AXUIElement] ?? []).prefix(32).map { ($0, depth + 1) } }
        }
        return nil
    }

    private static func isDouyin(_ url: URL) -> Bool {
        ["douyin.com", "www.douyin.com", "live.douyin.com"].contains(url.host ?? "")
    }
    private static func liveRoom(_ node: Node) -> String? {
        node.url.flatMap(DouyinControls.liveRoomID)
    }
    private static func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }
    private static func parseURL(_ value: CFTypeRef?) -> URL? {
        (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
    }
    private static func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
        try Task.checkCancellation()
        AXUIElementSetMessagingTimeout(element, 0.025)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private static func values(_ element: AXUIElement, _ names: [String]) throws -> [CFTypeRef?] {
        try Task.checkCancellation()
        AXUIElementSetMessagingTimeout(element, 0.025)
        var result: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &result) == .success,
              let values = result as? [CFTypeRef], values.count == names.count else { return names.map { _ in nil } }
        return values.map { $0 }
    }
    private static func frame(_ position: CFTypeRef?, _ size: CFTypeRef?) -> CGRect {
        guard let position, CFGetTypeID(position) == AXValueGetTypeID(),
              let size, CFGetTypeID(size) == AXValueGetTypeID() else { return .zero }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite else { return .zero }
        return CGRect(origin: point, size: dimensions)
    }
}
