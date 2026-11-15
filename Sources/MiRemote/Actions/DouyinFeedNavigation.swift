import AppKit
import ApplicationServices
import CoreGraphics

/// Remote navigation for the foreground Douyin desktop client. Content actions remain
/// native; category and live-preview actions use the client's accessibility metadata.
@MainActor
enum DouyinFeedNavigation {
    private typealias Controls = DouyinControls
    private typealias Snapshot = DouyinControls.Snapshot
    private static let bundleID = "com.bytedance.douyin.desktop"

    private static var handling = false

    /// Returning false preserves the configured action (including OK on ordinary videos).
    static func handle(_ key: RemoteKey) -> Bool {
        guard [.up, .down, .ok].contains(key),
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID else { return false }
        guard !handling else { return true }
        handling = true
        defer { handling = false }
        do {
            var current = try Controls.snapshot()
            guard let page = Controls.primaryPage(current.window) else {
                throw Controls.Failure("没有找到抖音内容页面")
            }
            guard !isEditing(current) else { resetSelection(); return false }
            if !isCardGrid(page, in: current) { resetSelection() }
            switch key {
            case .up, .down:
                if Controls.isLivePage(page) {
                    resetSelection()
                    try moveLiveRoom(key == .down ? 1 : -1, page: page)
                } else {
                    if isCardGrid(page, in: current) {
                        try Controls.withOperation { try moveCard(key == .down ? 1 : -1, in: current) }
                        return true
                    }
                    try Controls.withOperation { try postKey(key == .up ? 126 : 125, in: current) }
                }
            case .ok:
                guard !Controls.isLivePage(page) else { return false }
                let preview: Int?
                if isCardGrid(page, in: current) {
                    current = try Controls.withOperation { try readyCardSnapshot(in: current) }
                    guard let selected = selectedCard(in: current) else {
                        throw Controls.Failure("所选卡片已变化，请按上下重新选择")
                    }
                    preview = selected
                } else { preview = livePreview(in: current) }
                guard let preview else { return false }
                resetSelection()
                try Controls.withOperation {
                    if isFeaturedGrid(page, in: current) { try openFeaturedCard(preview, in: current) }
                    else { try enterPreview(preview, in: current) }
                }
            default: return false
            }
        } catch {
            // Missing preview is intentionally not an error; failed recognized actions are.
            if key == .ok {
                CodexNavigation.showNotice(error.localizedDescription)
                return true
            }
            CodexNavigation.showNotice(error.localizedDescription)
        }
        return true
    }

    private static func moveLiveRoom(_ direction: Int, page: Controls.Page) throws {
        let suffix = "的抖音直播间 - 抖音直播"
        let currentName = String(page.title.dropLast(suffix.count))
        let rooms: [String]
        switch Controls.readLiveRooms() {
        case .success(let names): rooms = names
        case .failure(let error): throw error
        }
        guard !rooms.isEmpty else { throw Controls.Failure("关注列表中暂时没有正在直播的主播") }
        guard rooms.count > 1 || rooms.first != currentName else {
            // readLiveRooms returned to the follow page; restore the sole live room.
            if let error = Controls.enterLiveRoom(named: currentName) { throw Controls.Failure(error) }
            return
        }
        let next: Int
        if let index = rooms.firstIndex(of: currentName) {
            next = (index + direction + rooms.count) % rooms.count
        } else {
            next = direction > 0 ? 0 : rooms.count - 1
        }
        if let error = Controls.enterLiveRoom(named: rooms[next]) { throw Controls.Failure(error) }
    }

    enum ShortcutPage {
        case category(String), liveRoom, other
    }

    static func shortcutPage(timeout: TimeInterval = 0) -> ShortcutPage? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == bundleID else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return nil }
            if let context = try? Controls.context(), let page = Controls.primaryPage(context.window) {
                if Controls.isLivePage(page) || liveRoomID(page.url) != nil { return .liveRoom }
                if isCategoryPage(page), let category = categoryNames.first(where: { categoryRouteMatches($0, page.url) }) {
                    return .category(category)
                }
                return .other
            }
            Controls.yieldForAX(until: deadline)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return nil
    }

    static func currentCategoryName() -> String? {
        guard case .category(let name) = shortcutPage() else { return nil }
        return name
    }

    /// Jump directly through the requested visible sidebar link. No intermediary route
    /// is visited. The caller owns presentation of a returned user-facing error.
    static func openCategory(named name: String) async -> String? {
        guard categoryNames.contains(name) else { return "没有找到所选抖音分类" }
        guard !handling else { return "抖音正在处理上一项操作，请稍后重试" }
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == bundleID else {
            return "请先切换到抖音"
        }
        let pid = app.processIdentifier
        handling = true
        defer { handling = false }
        resetSelection()
        let deadline = ProcessInfo.processInfo.systemUptime + 9
        do {
            let targetDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 2)
            var target: (Snapshot, Int)?
            var alreadySelected = false
            repeat {
                try validateCategoryRequest(pid: pid)
                if let current = try? Controls.snapshot(navigationOnly: true),
                   let page = Controls.primaryPage(current.window) {
                    guard isCategoryPage(page) else { throw Controls.Failure("请先退出直播间再选择分类") }
                    if categoryRouteMatches(name, page.url) {
                        alreadySelected = true
                        break
                    }
                    let matches = sidebarCategories(in: current).filter {
                        categoryName(current.nodes[$0].label) == name
                            && current.nodes[$0].url.map { categoryRouteMatches(name, $0) } == true
                    }
                    if matches.count == 1, let index = matches.first { target = (current, index); break }
                }
                try await Task.sleep(for: .milliseconds(50))
            } while ProcessInfo.processInfo.systemUptime < targetDeadline

            if !alreadySelected {
                guard let (current, index) = target else { throw Controls.Failure("没有找到可见的抖音\(name)分类入口") }
                // The shared synchronous lock protects only the verified press. It is
                // released before any suspension so AppKit can deliver navigation updates.
                try Controls.withOperation {
                    try validateCategoryRequest(pid: pid)
                    try Controls.press(index, in: current)
                }
            }

            var confirmed = false
            repeat {
                try validateCategoryRequest(pid: pid)
                if let context = try? Controls.context(), let page = Controls.primaryPage(context.window),
                   isCategoryPage(page), categoryRouteMatches(name, page.url) {
                    confirmed = true
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            } while ProcessInfo.processInfo.systemUptime < deadline
            guard confirmed else { throw Controls.Failure("抖音尚未切换到\(name)，请重试") }

            if name == "直播" || name == "精选" {
                let cardsDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 2)
                repeat {
                    try validateCategoryRequest(pid: pid)
                    if let loaded = try? Controls.snapshot(), let page = Controls.primaryPage(loaded.window) {
                        guard isCategoryPage(page), categoryRouteMatches(name, page.url) else {
                            throw Controls.Failure("抖音页面已改变，请重新选择")
                        }
                        if isCardGrid(page, in: loaded), let first = browseCards(in: loaded).first {
                            try Controls.validate(loaded)
                            selectCard(first, in: loaded)
                            break
                        }
                        // Choosing the already active featured player is idempotent.
                        if !isCardGrid(page, in: loaded) { break }
                    }
                    try await Task.sleep(for: .milliseconds(50))
                } while ProcessInfo.processInfo.systemUptime < cardsDeadline
            }
            return nil
        } catch is CancellationError {
            return "抖音分类选择已取消"
        } catch { return error.localizedDescription }
    }

    private static func validateCategoryRequest(pid: pid_t) throws {
        try Task.checkCancellation()
        let app = NSWorkspace.shared.frontmostApplication
        guard app?.bundleIdentifier == bundleID, app?.processIdentifier == pid else {
            throw Controls.Failure("抖音前台应用已改变，请重新选择")
        }
    }

    private static func isCategoryPage(_ page: Controls.Page) -> Bool {
        ["douyin.com", "www.douyin.com", "live.douyin.com"].contains(page.url.host ?? "")
            && !Controls.isLivePage(page) && liveRoomID(page.url) == nil
    }

    private static func categoryRouteMatches(_ name: String, _ url: URL) -> Bool {
        let desktop = ["douyin.com", "www.douyin.com"].contains(url.host ?? "")
        switch name {
        case "精选": return desktop && url.path == "/jingxuan"
        case "推荐": return desktop && (url.path.isEmpty || url.path == "/")
        case "关注": return desktop && url.path == "/follow"
        case "直播": return url.host == "live.douyin.com" && liveRoomID(url) == nil
        default: return false
        }
    }

    /// Share room identity with Home, including client-origin routes such as /root/live/<id>.
    private static func liveRoomID(_ url: URL) -> String? { Controls.liveRoomID(url) }

    // Skip AI search, social/profile pages, and film/drama catalogs.
    private static let categoryNames: Set<String> = ["精选", "推荐", "关注", "直播"]

    private static func sidebarCategories(in snapshot: Snapshot) -> [Int] {
        snapshot.nodes.indices.filter { index in
            let node = snapshot.nodes[index]
            guard node.role == "AXLink", let url = node.url,
                  ["douyin.com", "www.douyin.com", "live.douyin.com"].contains(url.host ?? ""),
                  categoryNames.contains(categoryName(node.label)),
                  Controls.visible(node.rect, in: snapshot) else { return false }
            // Sidebar membership must agree with the actual window's leading column.
            return node.rect.midX < snapshot.bounds.minX + min(220, snapshot.bounds.width * 0.2)
        }.sorted { snapshot.nodes[$0].rect.midY < snapshot.nodes[$1].rect.midY }
    }

    private static func categoryName(_ label: String) -> String {
        label.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? label
    }

    private static func isEditing(_ snapshot: Snapshot) -> Bool {
        guard let raw = Controls.attribute(snapshot.app, kAXFocusedUIElementAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
        let role = Controls.attribute(raw as! AXUIElement, kAXRoleAttribute) as? String ?? ""
        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"].contains(role)
    }

    private static func postKey(_ code: CGKeyCode, in snapshot: Snapshot) throws {
        try Controls.validate(snapshot)
        // Desktop navigation can leave focus in its about:blank shell web view.
        // Focus the identified content document without clicking/pause-toggling video.
        if let page = Controls.primaryPage(snapshot.window),
           let document = snapshot.nodes.first(where: { $0.role == "AXWebArea" && $0.url == page.url }) {
            AXUIElementSetAttributeValue(document.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            throw Controls.Failure("无法发送抖音导航按键")
        }
        down.flags = [.maskSecondaryFn, .maskNumericPad]
        up.flags = down.flags
        try Controls.validate(snapshot)
        down.postToPid(snapshot.pid)
        up.postToPid(snapshot.pid)
    }

    private struct CardSelection {
        let pid: pid_t
        let window: AXUIElement
        let identity: String
    }
    private static var cardSelection: CardSelection?
    private static let focusOverlay = NavigationFocusOverlay()
    private static var overlayGeneration: UInt64 = 0

    private static func isLiveDirectory(_ page: Controls.Page) -> Bool {
        page.url.host == "live.douyin.com" && !Controls.isLivePage(page)
    }

    private static func isFeaturedGrid(_ page: Controls.Page, in snapshot: Snapshot? = nil) -> Bool {
        guard page.url.path == "/jingxuan",
              URLComponents(url: page.url, resolvingAgainstBaseURL: false)?.queryItems?
                .contains(where: { $0.name == "modal_id" }) != true else { return false }
        // The featured player opens over the grid without changing the page URL.
        return snapshot.map { current in
            !current.nodes.contains {
                $0.classes.contains("sliderVideo") && $0.rect.height >= 250
                    && Controls.visible($0.rect, in: current)
            }
        } ?? true
    }

    private static func isCardGrid(_ page: Controls.Page, in snapshot: Snapshot) -> Bool {
        isLiveDirectory(page) || isFeaturedGrid(page, in: snapshot)
    }

    private static func browseCards(in snapshot: Snapshot) -> [Int] {
        snapshot.nodes.indices.filter { index in
            let node = snapshot.nodes[index]
            guard Controls.visible(node.rect, in: snapshot), node.rect.width >= 150,
                  node.rect.height >= 100, node.rect.intersection(snapshot.bounds).height >= 100 else { return false }
            if node.classes.contains("jingxuanVideoCard") {
                return Controls.hasPress(node.element)
            }
            guard node.role == "AXLink", node.classes.contains("LiveLinkA"),
                  let url = node.url, url.host == "live.douyin.com",
                  let room = url.pathComponents.last else { return false }
            return !room.isEmpty && room.allSatisfy(\.isNumber)
        }.sorted {
            let a = snapshot.nodes[$0].rect, b = snapshot.nodes[$1].rect
            if abs(a.minY - b.minY) > 20 { return a.minY < b.minY }
            return a.minX < b.minX
        }
    }

    private static func cardIdentity(_ index: Int, in snapshot: Snapshot) -> String? {
        let node = snapshot.nodes[index]
        if let url = node.url { return "live:" + url.path }
        guard node.classes.contains("jingxuanVideoCard"),
              let cover = Controls.descendants(of: index, in: snapshot).first(where: {
                  snapshot.nodes[$0].classes.contains("discover-video-card-img")
              }), let raw = Controls.attribute(snapshot.nodes[cover].element, kAXURLAttribute),
              let url = (raw as? URL) ?? (raw as? String).flatMap(URL.init(string:)) else { return nil }
        return "featured:" + url.path
    }

    private static func selectedCard(in snapshot: Snapshot) -> Int? {
        let cards = browseCards(in: snapshot)
        guard let selected = cardSelection, selected.pid == snapshot.pid,
              CFEqual(selected.window, snapshot.window) else { return cards.first }
        return cards.first { cardIdentity($0, in: snapshot) == selected.identity }
    }

    private static func readyCardSnapshot(in snapshot: Snapshot) throws -> Snapshot {
        var current = snapshot
        let deadline = ProcessInfo.processInfo.systemUptime + 1.2
        repeat {
            guard let page = Controls.primaryPage(current.window), isCardGrid(page, in: current) else {
                throw Controls.Failure("抖音页面已改变，请重新选择")
            }
            if !browseCards(in: current).isEmpty { return current }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.025))
            current = try Controls.snapshot()
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw Controls.Failure("视频卡片尚未加载，请重试")
    }

    private static func moveCard(_ direction: Int, in snapshot: Snapshot) throws {
        let current = try readyCardSnapshot(in: snapshot)
        let cards = browseCards(in: current)
        let selected = selectedCard(in: current).flatMap { cards.firstIndex(of: $0) } ?? 0
        let next = (selected + direction + cards.count) % cards.count
        try Controls.validate(current)
        selectCard(cards[next], in: current)
    }

    private static func selectCard(_ index: Int, in snapshot: Snapshot) {
        guard let identity = cardIdentity(index, in: snapshot) else { return }
        cardSelection = CardSelection(pid: snapshot.pid, window: snapshot.window, identity: identity)
        let number = (browseCards(in: snapshot).firstIndex(of: index) ?? 0) + 1
        focusOverlay.showTarget(snapshot.nodes[index].rect.intersection(snapshot.bounds),
                                title: "\(identity.hasPrefix("featured:") ? "精选" : "直播") \(number) · 上下选择 · OK 进入")
        overlayGeneration &+= 1
        let generation = overlayGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if overlayGeneration == generation { focusOverlay.hide() }
        }
    }

    static func resetSelection() {
        overlayGeneration &+= 1
        focusOverlay.hide()
        cardSelection = nil
    }

    private static func livePreview(in snapshot: Snapshot) -> Int? {
        let links = snapshot.nodes.indices.filter { index in
            let node = snapshot.nodes[index]
            guard node.role == "AXLink",
                  node.classes.contains("LiveLinkA"), node.label.contains("进入直播间"),
                  Controls.visible(node.rect, in: snapshot) else { return false }
            guard node.rect.width >= 250, node.rect.height >= 24 else { return false }
            var ancestor = node.parent
            while let parent = ancestor {
                let player = snapshot.nodes[parent]
                if player.classes.contains("LivePlayer_Preview") {
                    let area = player.rect.intersection(snapshot.bounds)
                    return area.width >= 250 && area.height >= min(300, snapshot.bounds.height * 0.5)
                }
                ancestor = player.parent
            }
            return false
        }
        return links.count == 1 ? links.first : nil
    }

    private static func openFeaturedCard(_ index: Int, in snapshot: Snapshot) throws {
        try Controls.press(index, in: snapshot)
        try Controls.waitForPage("抖音尚未打开所选视频，请重试", in: snapshot, timeout: 3) {
            $0.url.path.hasPrefix("/video/") || !isFeaturedGrid($0, in: try? Controls.snapshot())
        }
    }

    private static func enterPreview(_ index: Int, in snapshot: Snapshot) throws {
        let expectedRoom = snapshot.nodes[index].url.flatMap(liveRoomID)
        try Controls.press(index, in: snapshot)
        try Controls.waitForPage("抖音尚未进入直播间，请重试", in: snapshot, timeout: 3) { page in
            if let expectedRoom { return liveRoomID(page.url) == expectedRoom }
            return Controls.isLivePage(page)
        }
    }
}
