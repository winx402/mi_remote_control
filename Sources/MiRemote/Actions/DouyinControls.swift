import AppKit
import ApplicationServices
import CoreGraphics

/// Controls the foreground desktop client through Chromium's accessibility metadata.
/// Player classes are semantic DOM classes, not screen coordinates or generated CSS names.
@MainActor
enum DouyinControls {
    private static let bundleID = "com.bytedance.douyin.desktop"

    static func isLiveRoom() -> Bool {
        guard let context = try? context(), let page = primaryPage(context.window) else { return false }
        return isLivePage(page)
    }

    static func goHome(shouldCancel: (() -> Bool)? = nil) -> String? {
        let previousCancellation = operationCancellation
        if let shouldCancel {
            operationCancellation = { previousCancellation?() == true || shouldCancel() }
        }
        defer { operationCancellation = previousCancellation }
        return perform {
            var current = try navigateToSidebarPage("推荐", matches: isHomeURL,
                                                   failure: "抖音尚未返回推荐首页")
            // The route is published before Chromium restores sidebar AX nodes.
            // A second Home can open categories immediately only once this link exists.
            let deadline = ProcessInfo.processInfo.systemUptime + 1.2
            while sidebarLink("推荐", matches: isHomeURL, in: current) == nil {
                try checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw Failure("已返回抖音推荐页，侧栏尚未加载完成，请稍候重试")
                }
                yieldForAX(until: deadline)
                current = try readySnapshot(timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime),
                                            navigationOnly: true, expectedPID: current.pid)
                guard primaryPage(current.window).map({ isHomeURL($0.url) }) == true else {
                    throw Failure("抖音页面已改变，请重新返回首页")
                }
            }
            try validate(current)
        }
    }

    static func togglePlayback() -> String? {
        perform {
            let current = try snapshot()
            guard livePage(in: current) != nil else { throw Failure("请先进入抖音直播间") }
            let player = try player(in: current)
            // AXPress targets the semantic control even while Chromium autohides its bar.
            // Revealing the whole player first can hit an unrelated floating overlay.
            let control = try uniqueControl(["douyin-player-play", "xgplayer-play"], player: player,
                                            in: current, requireVisible: false)
            let element = current.nodes[control].element
            guard let playing = playbackState(element) else { throw Failure("无法确认抖音当前播放状态") }
            try pressControl(control, in: current)
            try wait("抖音未确认播放状态已切换", in: current) {
                playbackState(element) == !playing
            }
        }
    }

    /// Idempotent: inspect the client's mute state first; never blindly toggle M/volume.
    static func enableSound() -> String? {
        perform {
            let current = try snapshot()
            guard livePage(in: current) != nil else { throw Failure("请先进入抖音直播间") }
            let player = try player(in: current)
            let volume = try uniqueControl(["douyin-player-volume", "xgplayer-volume"], player: player,
                                           in: current, requireVisible: false)
            let element = current.nodes[volume].element
            var restorePointer: (() -> Void)?
            defer { restorePointer?() }
            // Live volume state is exposed only while its AX-derived bounds are hovered.
            if soundState(element) == nil {
                restorePointer = try hoverControl(volume, player: player, in: current)
                try wait("无法读取抖音播放器的静音状态", in: current) { soundState(element) != nil }
            }
            guard let audible = soundState(element) else { throw Failure("无法确认抖音声音状态") }
            if audible { return }
            try pressControl(volume, in: current)
            try wait("抖音未确认已开启声音", in: current, timeout: 2) {
                guard let fresh = try? snapshot(), let activePlayer = try? Self.player(in: fresh),
                      let volume = try? uniqueControl(["douyin-player-volume", "xgplayer-volume"],
                                                       player: activePlayer, in: fresh, requireVisible: false) else { return false }
                return soundState(fresh.nodes[volume].element) == true
            }
        }
    }

    /// Enter through the live player's own fullscreen action, never the window's
    /// green button. Check the resulting player layout as well as native fullscreen:
    /// a maximized window and the always-present __playerIsFull class are not proof.
    static func enterFullscreen() -> String? {
        perform { _ = try setLiveFullscreen(true, in: readySnapshot()) }
    }

    private static func setLiveFullscreen(_ fullscreen: Bool, in current: Snapshot) throws -> Snapshot {
        guard let page = primaryPage(current.window), isLivePage(page) else {
            throw Failure("请先进入抖音直播间")
        }
        let player = try player(in: current)
        let control = try uniqueControl(["douyin-player-fullscreen", "xgplayer-fullscreen"],
                                        player: player, in: current, requireVisible: false)
        guard let previous = liveFullscreenState(player: player, in: current) else {
            throw Failure("无法确认抖音直播播放器的全屏状态")
        }
        if previous == fullscreen { return current }
        try pressControl(control, in: current)
        // Native fullscreen changes Spaces and may replace the AX window or briefly
        // clear focus. Re-resolve only this process's current focused window; never
        // act on an old AX reference or pick an unrelated AXWindows entry.
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        repeat {
            try checkCancellation()
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == current.pid,
               let updated = try? snapshot(), updated.pid == current.pid,
               let updatedPage = primaryPage(updated.window), updatedPage.url == page.url,
               isLivePage(updatedPage), let player = try? Self.player(in: updated),
               liveFullscreenState(player: player, in: updated) == fullscreen,
               fullscreen || (try? liveBack(in: updated)) != nil {
                try validate(updated)
                return updated
            }
            yieldForAX(until: deadline)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw Failure(fullscreen ? "抖音尚未确认直播播放器已全屏" : "抖音尚未确认已退出直播播放器全屏")
    }

    static func readLiveRooms() -> Result<[String], Failure> {
        do {
            return .success(try withOperation {
                let current = try followSnapshot()
                return try liveRows(in: current).map(\.name)
            })
        } catch let failure as Failure { return .failure(failure) }
        catch { return .failure(Failure("读取抖音直播列表失败：\(error.localizedDescription)")) }
    }

    static func enterLiveRoom(named name: String) -> String? {
        perform {
            guard !name.isEmpty else { throw Failure("没有选择直播间") }
            let current = try followSnapshot()
            let matches = try liveRows(in: current).filter { $0.name == name }
            guard !matches.isEmpty else { throw Failure("该主播已不在正在直播列表中，直播可能已结束") }
            guard matches.count == 1, let row = matches.first else {
                throw Failure("存在同名直播间，请在抖音客户端中选择")
            }
            try press(row.index, in: current)
            // Chromium publishes the selected room's URL before its title finishes
            // loading. The exact ID on a known live route is the stronger identity;
            // requiring the asynchronously updated title produces false failures.
            try waitForPage("未能确认进入所选直播间，直播可能已结束", in: current, timeout: 3) {
                liveRoomID($0.url) == row.roomID
            }
        }
    }

    struct Failure: LocalizedError {
        let message: String
        let retryableSnapshot: Bool
        let pendingFocusedWindow: Bool
        let changedFocusedWindow: Bool
        init(_ message: String, retryableSnapshot: Bool = false, pendingFocusedWindow: Bool = false,
             changedFocusedWindow: Bool = false) {
            self.message = message
            self.retryableSnapshot = retryableSnapshot
            self.pendingFocusedWindow = pendingFocusedWindow
            self.changedFocusedWindow = changedFocusedWindow
        }
        var errorDescription: String? { message }
    }
    struct Node {
        let element: AXUIElement
        let parent: Int?
        let role: String
        let classes: Set<String>
        let rect: CGRect
        let label: String
        let url: URL?
    }
    struct Snapshot {
        let pid: pid_t
        let app: AXUIElement
        let window: AXUIElement
        let bounds: CGRect
        let nodes: [Node]
    }

    private static var operationInFlight = false

    /// A settings owner may cancel its scoped AX operation when Home supersedes it.
    /// Ordinary navigation has no owner and does not inherit a previous cancellation.
    static var operationCancellation: (() -> Bool)?

    static func checkCancellation() throws {
        if operationCancellation?() == true { throw Failure("抖音操作已取消") }
    }

    /// AX polling pumps the main run loop so Chromium window notifications can arrive.
    /// Reject a second remote action dispatched by that nested loop until this one ends.
    /// Feed controls share this guard when they use the internal AX primitives directly.
    static func withOperation<T>(_ operation: () throws -> T) throws -> T {
        try checkCancellation()
        guard !operationInFlight else { throw Failure("抖音操作正在进行，请稍候重试") }
        operationInFlight = true
        defer { operationInFlight = false }
        return try operation()
    }

    private static func perform(_ operation: () throws -> Void) -> String? {
        do { try withOperation(operation); return nil }
        catch let problem as Failure { return problem.message }
        catch { return "抖音操作失败：\(error.localizedDescription)" }
    }

    private static var accessibilityPID: pid_t?

    static func context() throws -> (pid: pid_t, app: AXUIElement, window: AXUIElement) {
        try checkCancellation()
        guard let running = NSWorkspace.shared.frontmostApplication, running.bundleIdentifier == bundleID else {
            throw Failure("请先切换到抖音")
        }
        guard AXIsProcessTrusted() else { throw Failure("控制抖音需要辅助功能权限") }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.04)
        if accessibilityPID != running.processIdentifier {
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            accessibilityPID = running.processIdentifier
        }
        guard let rawWindow = attribute(app, kAXFocusedWindowAttribute),
              CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else { throw Failure("没有找到抖音前台窗口", pendingFocusedWindow: true) }
        return (running.processIdentifier, app, rawWindow as! AXUIElement)
    }

    static func snapshot(navigationOnly: Bool = false) throws -> Snapshot {
        try snapshot(context: context(), navigationOnly: navigationOnly)
    }

    private static func snapshot(context: (pid: pid_t, app: AXUIElement, window: AXUIElement),
                                 navigationOnly: Bool) throws -> Snapshot {
        let bounds = frame(context.window)
        guard bounds.width >= 320, bounds.height >= 200,
              attribute(context.window, kAXMinimizedAttribute) as? Bool != true else { throw Failure("抖音窗口当前不可用") }
        var nodes: [Node] = []
        var seen: [UInt: [AXUIElement]] = [:]
        var complete = true
        var navigationRoot: Int?
        var navigationComplete = false
        let deadline = ProcessInfo.processInfo.systemUptime + 0.45
        func visit(_ element: AXUIElement, parent: Int?, depth: Int) {
            if navigationComplete { return }
            guard nodes.count < 2_000, depth < 64, ProcessInfo.processInfo.systemUptime < deadline else {
                complete = false; return
            }
            let hash = CFHash(element)
            guard !(seen[hash] ?? []).contains(where: { CFEqual($0, element) }) else { return }
            seen[hash, default: []].append(element)
            let values = attributes(element, [kAXRoleAttribute, "AXDOMClassList", kAXPositionAttribute,
                                              kAXSizeAttribute, kAXChildrenAttribute])
            let role = values[0] as? String ?? ""
            let classes = Set(values[1] as? [String] ?? [])
            // Never read feed text, chat messages, search values, or account data.
            let labelled = role == "AXLink" || role == "AXWebArea"
            let labelValues = labelled ? attributes(element, [kAXTitleAttribute, kAXDescriptionAttribute, kAXURLAttribute]) : []
            let label = labelled ? ((labelValues[0] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? labelValues[1] as? String ?? "") : ""
            let url = labelled ? parseURL(labelValues[2]) : nil
            let index = nodes.count
            nodes.append(Node(element: element, parent: parent, role: role, classes: classes,
                              rect: frame(position: values[2], size: values[3]), label: label, url: url))
            if navigationOnly, navigationRoot == nil, role == kAXGroupRole {
                let rect = nodes[index].rect
                if abs(rect.minX - bounds.minX) < 3, (100...220).contains(rect.width),
                   rect.height >= bounds.height * 0.7 {
                    navigationRoot = index
                }
            }
            // Embedded activity/gift web views are unrelated to player or navigation controls.
            if role == "AXWebArea", let url, !isDouyin(url), url.absoluteString != "about:blank" { return }
            for child in values[4] as? [AXUIElement] ?? [] { visit(child, parent: index, depth: depth + 1) }
            if navigationRoot == index {
                // Finish the entire semantic sidebar to retain uniqueness checks,
                // then skip the live directory's potentially huge card grid.
                navigationComplete = nodes[index...].contains {
                    !$0.classes.isDisjoint(with: ["tab-follow", "tab-recommend"])
                }
                if !navigationComplete { navigationRoot = nil }
            }
        }
        visit(context.window, parent: nil, depth: 0)
        guard complete else { throw Failure("抖音界面繁忙，无法安全确认操作目标，请重试", retryableSnapshot: true) }
        return Snapshot(pid: context.pid, app: context.app, window: context.window, bounds: bounds, nodes: nodes)
    }

    /// Navigation follows the original foreground process's actual focused window
    /// while Chromium replaces it. Player/list reads keep a fixed window instead.
    /// No other AXWindows entry is consulted, and every returned snapshot is current.
    private static func readySnapshot(timeout: TimeInterval = 1, navigationOnly: Bool = false,
                                      expectedPID: pid_t? = nil) throws -> Snapshot {
        guard let running = NSWorkspace.shared.frontmostApplication, running.bundleIdentifier == bundleID else {
            throw Failure("请先切换到抖音")
        }
        let pid = expectedPID ?? running.processIdentifier
        guard running.processIdentifier == pid else { throw Failure("抖音前台窗口已改变，请重试") }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var anchor: Snapshot?
        while true {
            try checkCancellation()
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                throw Failure("抖音前台窗口已改变，请重试")
            }
            do {
                if anchor == nil || navigationOnly {
                    let focused = try context()
                    anchor = Snapshot(pid: focused.pid, app: focused.app, window: focused.window,
                                      bounds: frame(focused.window), nodes: [])
                }
                guard let anchor else { throw Failure("没有找到抖音前台窗口") }
                try validate(anchor)
                let current = try snapshot(navigationOnly: navigationOnly)
                guard current.pid == pid else { throw Failure("抖音前台窗口已改变，请重试") }
                if !navigationOnly, !CFEqual(current.window, anchor.window) {
                    throw Failure("抖音前台窗口已改变，请重试", changedFocusedWindow: true)
                }
                try validate(current)
                return current
            } catch let failure as Failure {
                let transient = failure.retryableSnapshot || failure.pendingFocusedWindow
                    || (navigationOnly && failure.changedFocusedWindow)
                guard transient, ProcessInfo.processInfo.systemUptime < deadline else { throw failure }
            }
            yieldForAX(until: deadline)
        }
    }

    struct Page { let title: String; let url: URL }

    /// Menu visibility uses this bounded walk, not the full player tree. Chromium's main
    /// web area appears before the feed/room descendants; do not enter that web area.
    static func primaryPage(_ window: AXUIElement) -> Page? {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var offset = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 0.12
        while offset < queue.count, offset < 64, ProcessInfo.processInfo.systemUptime < deadline {
            let (element, depth) = queue[offset]
            offset += 1
            let values = attributes(element, [kAXRoleAttribute, kAXChildrenAttribute])
            if values[0] as? String == "AXWebArea" {
                let info = attributes(element, [kAXTitleAttribute, kAXURLAttribute])
                if let url = parseURL(info[1]), isDouyin(url) {
                    return Page(title: info[0] as? String ?? "", url: url)
                }
                continue
            }
            if depth < 12 { queue += (values[1] as? [AXUIElement] ?? []).prefix(32).map { ($0, depth + 1) } }
        }
        return nil
    }

    private static func parseURL(_ value: CFTypeRef?) -> URL? {
        (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
    }

    nonisolated private static func isDouyin(_ url: URL) -> Bool {
        ["douyin.com", "www.douyin.com", "live.douyin.com"].contains(url.host ?? "")
    }

    static func isLivePage(_ page: Page) -> Bool {
        let suffix = "的抖音直播间 - 抖音直播"
        return page.title.hasSuffix(suffix) && page.title.count > suffix.count
            && liveRoomID(page.url) != nil
    }

    private static func livePage(in snapshot: Snapshot) -> Int? {
        snapshot.nodes.indices.first {
            let node = snapshot.nodes[$0]
            guard node.role == "AXWebArea", let url = node.url else { return false }
            return isLivePage(Page(title: node.label, url: url)) && visible(node.rect, in: snapshot)
        }
    }

    nonisolated static func liveRoomID(_ url: URL) -> String? {
        guard isDouyin(url) else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        let room: String?
        if url.host == "live.douyin.com", components.count == 1 {
            room = components.first
        } else if ["douyin.com", "www.douyin.com"].contains(url.host ?? ""),
                  let live = components.firstIndex(of: "live"), live + 2 == components.count {
            // Client room prefixes vary with their origin: /root/live/<id>,
            // /follow/live/<id>, /recommend/live/<id>, and /live/<id>.
            room = components[live + 1]
        } else { room = nil }
        guard let room, !room.isEmpty, room.allSatisfy(\.isNumber) else { return nil }
        return room
    }

    private static func isHomeURL(_ url: URL) -> Bool {
        ["douyin.com", "www.douyin.com"].contains(url.host ?? "")
            && (url.path == "/" || url.path.isEmpty)
            && URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .contains(where: { $0.name == "recommend" && $0.value == "1" }) == true
    }

    private static func isHome(_ snapshot: Snapshot) -> Bool {
        snapshot.nodes.contains { $0.role == "AXWebArea" && $0.url.map(isHomeURL) == true && visible($0.rect, in: snapshot) }
    }

    private static func sidebarLink(_ label: String, matches: (URL) -> Bool, in snapshot: Snapshot) -> Int? {
        let links = snapshot.nodes.indices.filter { index in
            let node = snapshot.nodes[index]
            return node.role == "AXLink" && node.label.split(whereSeparator: \.isWhitespace).first.map(String.init) == label
                && node.url.map(matches) == true && visible(node.rect, in: snapshot)
                && node.rect.midX < snapshot.bounds.minX + min(220, snapshot.bounds.width * 0.2)
        }
        return links.count == 1 ? links.first : nil
    }

    /// Live rooms can originate from follow, recommendation, or the separate live
    /// directory window. Follow only the client's actual focused window after Back;
    /// never choose another window from AXWindows based on its route or ordering.
    private static func navigateToSidebarPage(_ label: String, matches: (URL) -> Bool,
                                              failure: String) throws -> Snapshot {
        var current = try readySnapshot(navigationOnly: true)
        let foregroundPID = current.pid
        let pageDeadline = ProcessInfo.processInfo.systemUptime + 3
        while primaryPage(current.window) == nil, ProcessInfo.processInfo.systemUptime < pageDeadline {
            yieldForAX(until: pageDeadline)
            current = try readySnapshot(navigationOnly: true, expectedPID: foregroundPID)
        }
        func reached(_ snapshot: Snapshot) -> Bool {
            snapshot.nodes.contains { $0.role == "AXWebArea" && $0.url.map(matches) == true
                && visible($0.rect, in: snapshot) }
        }
        if reached(current) { return current }
        // Embedded rooms may retain the real sidebar. Prefer its verified link
        // before requiring a separate room header or changing fullscreen state.
        if let link = sidebarLink(label, matches: matches, in: current) {
            try press(link, in: current)
            try waitForPage(failure, in: current, timeout: 2) { matches($0.url) }
            return try readySnapshot(navigationOnly: true, expectedPID: foregroundPID)
        }
        let standaloneRoom = primaryPage(current.window).map {
            $0.url.host == "live.douyin.com" && liveRoomID($0.url) != nil
        } == true
        let roomRoute = primaryPage(current.window).flatMap { liveRoomID($0.url) } != nil
        if livePage(in: current) != nil || roomRoute {
            let closedStandalone = try standaloneRoom && closeStandaloneRoom(in: current, label: label, matches: matches)
            if !closedStandalone {
                if attribute(current.window, "AXFullScreen") as? Bool == true {
                    current = try setLiveFullscreen(false, in: current)
                }
                try press(try liveBack(in: current), in: current)
            }
            let roomWindow = current.window
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while true {
                try checkCancellation()
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == foregroundPID else {
                    throw Failure("抖音前台窗口已改变，请重试")
                }
                if let focused = try? context(), let page = primaryPage(focused.window), !isLivePage(page),
                   liveRoomID(page.url) == nil {
                    current = try readySnapshot(navigationOnly: true, expectedPID: foregroundPID)
                    break
                }
                // A closed standalone room may not restore AX focus itself.
                // Only after that window disappears may we raise an existing,
                // uniquely verified main window from this same foreground process.
                if let restored = try restoreSidebarWindow(afterClosing: roomWindow, in: current,
                                                           label: label, matches: matches) {
                    current = restored
                    break
                }
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw Failure("抖音尚未退出直播间")
                }
                yieldForAX(until: deadline)
            }
        }
        // Search opens a separate client route without the sidebar. A room
        // entered from search first returns there; unwind only these known
        // official search routes, with a fresh semantic header and URL check
        // after each Back. Never traverse arbitrary history or guess a click.
        var visitedSearchRoutes: Set<URL> = []
        while visitedSearchRoutes.count < 4 {
            guard sidebarLink(label, matches: matches, in: current) == nil,
                  let page = primaryPage(current.window),
                  ["douyin.com", "www.douyin.com"].contains(page.url.host ?? ""),
                  page.url.pathComponents.contains("search"),
                  visitedSearchRoutes.insert(page.url).inserted,
                  let root = current.nodes.indices.first(where: {
                      current.nodes[$0].role == "AXWebArea" && current.nodes[$0].url == page.url
                          && visible(current.nodes[$0].rect, in: current)
                  }), let back = try desktopBack(page: root, in: current) else { break }
            try press(back, in: current)
            try waitForPage("抖音尚未返回主页面", in: current, timeout: 5) { $0.url != page.url }
            current = try readySnapshot(navigationOnly: true, expectedPID: foregroundPID)
        }
        // Page URL changes precede sidebar AX nodes, particularly after a live
        // directory room returns to its originating window.
        let deadline = ProcessInfo.processInfo.systemUptime + 1.2
        var link = sidebarLink(label, matches: matches, in: current)
        while !reached(current), link == nil, ProcessInfo.processInfo.systemUptime < deadline {
            yieldForAX(until: deadline)
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == foregroundPID else {
                throw Failure("抖音前台窗口已改变，请重试")
            }
            current = try readySnapshot(navigationOnly: true, expectedPID: foregroundPID)
            link = sidebarLink(label, matches: matches, in: current)
        }
        if reached(current) { return current }
        guard let link else { throw Failure("没有找到抖音\(label)页入口，请等待侧栏加载后重试") }
        try press(link, in: current)
        try waitForPage(failure, in: current, timeout: 2) { matches($0.url) }
        return try readySnapshot(navigationOnly: true, expectedPID: foregroundPID)
    }

    /// A standalone room can have its own native window. Close that window
    /// only when a distinct, unique official main window has the requested sidebar
    /// link. This also handles loading/changed room headers without leaving the
    /// previous live player audible behind the recommendation feed.
    private static func closeStandaloneRoom(in current: Snapshot, label: String,
                                            matches: (URL) -> Bool) throws -> Bool {
        guard sidebarWindow(excluding: current.window, in: current, label: label, matches: matches) != nil,
              let raw = attribute(current.window, kAXCloseButtonAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
        let close = raw as! AXUIElement
        guard hasPress(close), attribute(close, kAXEnabledAttribute) as? Bool != false else { return false }
        try validate(current)
        return AXUIElementPerformAction(close, kAXPressAction as CFString) == .success
    }

    private static func sidebarWindow(excluding excluded: AXUIElement, in previous: Snapshot,
                                      label: String, matches: (URL) -> Bool) -> Snapshot? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == previous.pid,
              let windows = attribute(previous.app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        let candidates = windows.compactMap { window -> Snapshot? in
            guard !CFEqual(window, excluded), let page = primaryPage(window), !isLivePage(page),
                  liveRoomID(page.url) == nil,
                  ["douyin.com", "www.douyin.com"].contains(page.url.host ?? ""),
                  let candidate = try? snapshot(context: (previous.pid, previous.app, window), navigationOnly: true),
                  sidebarLink(label, matches: matches, in: candidate) != nil else { return nil }
            return candidate
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    private static func restoreSidebarWindow(afterClosing roomWindow: AXUIElement, in previous: Snapshot,
                                             label: String, matches: (URL) -> Bool) throws -> Snapshot? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == previous.pid else {
            throw Failure("抖音前台窗口已改变，请重试")
        }
        guard let windows = attribute(previous.app, kAXWindowsAttribute) as? [AXUIElement],
              !windows.contains(where: { CFEqual($0, roomWindow) }) else { return nil }
        guard let target = sidebarWindow(excluding: roomWindow, in: previous, label: label, matches: matches) else {
            return nil
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == previous.pid else {
            throw Failure("抖音前台窗口已改变，请重试")
        }
        try checkCancellation()
        guard AXUIElementPerformAction(target.window, kAXRaiseAction as CFString) == .success else { return nil }
        let focused = try readySnapshot(navigationOnly: true, expectedPID: previous.pid)
        guard CFEqual(focused.window, target.window) else { return nil }
        return focused
    }

    private struct LiveRow { let name: String; let index: Int; let roomID: String }

    private static func isFollowURL(_ url: URL) -> Bool {
        ["douyin.com", "www.douyin.com"].contains(url.host ?? "") && url.path == "/follow"
    }

    private static func followSnapshot() throws -> Snapshot {
        var current = try navigateToSidebarPage("关注", matches: isFollowURL,
                                                failure: "抖音尚未打开关注页")
        // Cross-origin live-directory navigation can expose /follow before its
        // asynchronously fetched section exists. A route match alone is not ready:
        // require the anchored list and its complete advertised number of rooms.
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while true {
            try validate(current)
            do {
                _ = try liveRows(in: current)
                return current
            } catch let failure as Failure {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw failure }
            }
            yieldForAX(until: deadline)
            try validate(current)
            current = try readySnapshot(timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime))
        }
    }

    /// Only enumerate a list anchored by its preceding 正在直播(n) section heading.
    /// Other followed users, feed previews, recommendations, and chat links are excluded.
    private static func liveRows(in snapshot: Snapshot) throws -> [LiveRow] {
        guard snapshot.nodes.contains(where: { $0.role == "AXWebArea" && $0.url.map(isFollowURL) == true }) else {
            throw Failure("请先打开抖音关注页")
        }
        let lists = snapshot.nodes.indices.compactMap { index -> (Int, Int)? in
            guard snapshot.nodes[index].role == kAXListRole,
                  let count = precedingLiveCount(index, in: snapshot) else { return nil }
            return (index, count)
        }
        guard lists.count == 1, let (list, expected) = lists.first else {
            throw Failure("没有找到关注页的正在直播列表，请在抖音展开关注列表")
        }
        let links = descendants(of: list, in: snapshot).filter {
            let node = snapshot.nodes[$0]
            return node.role == "AXLink" && node.url?.host == "live.douyin.com"
                && node.url?.pathComponents.last?.allSatisfy(\.isNumber) == true
        }
        var rows: [LiveRow] = []
        for index in links {
            let node = snapshot.nodes[index]
            guard node.label.hasSuffix(" LiveIcon"), let roomID = node.url?.pathComponents.last else {
                throw Failure("抖音直播列表的名称格式已变化，请在客户端中选择")
            }
            let name = String(node.label.dropLast(" LiveIcon".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw Failure("直播间名称尚未加载，请重试") }
            rows.append(LiveRow(name: name, index: index, roomID: roomID))
        }
        guard rows.count == expected else { throw Failure("正在直播列表尚未完整加载，请在抖音展开列表后重试") }
        return rows
    }

    private static func precedingLiveCount(_ list: Int, in snapshot: Snapshot) -> Int? {
        var current = list
        for _ in 0..<3 {
            guard let parent = snapshot.nodes[current].parent else { return nil }
            let siblings = snapshot.nodes.indices.filter { snapshot.nodes[$0].parent == parent }
            if let previous = siblings.last(where: { $0 < current }) {
                let texts = ([previous] + descendants(of: previous, in: snapshot)).filter {
                    snapshot.nodes[$0].role == kAXStaticTextRole
                }
                if texts.count == 1,
                   let heading = attribute(snapshot.nodes[texts[0]].element, kAXValueAttribute) as? String {
                    guard heading.hasPrefix("正在直播("), heading.hasSuffix(")"),
                          let count = Int(heading.dropFirst("正在直播(".count).dropLast()), count >= 0 else { return nil }
                    return count
                }
            }
            current = parent
        }
        return nil
    }

    private static func desktopBack(page: Int, in snapshot: Snapshot) throws -> Int? {
        // Exiting player fullscreen can restore the regular desktop header rather
        // than the theater header below. Its leading Back is the only actionable
        // 40 pt group containing a single 32×24 arrow; the adjacent popout icon is
        // 32×32. The standalone live.douyin.com room uses live-header, while
        // embedded desktop rooms use header-ui. Both are client semantic markers;
        // generated classes and absolute screen coordinates are never selectors.
        let desktopHeaders = descendants(of: page, in: snapshot).filter {
            !snapshot.nodes[$0].classes.isDisjoint(with: ["header-ui", "live-header"])
        }
        let desktopBack = Set(desktopHeaders.flatMap { header in
            descendants(of: header, in: snapshot).filter { index in
                let n = snapshot.nodes[index]
                guard n.role == kAXGroupRole, (36...44).contains(n.rect.width),
                      (36...44).contains(n.rect.height),
                      n.rect.minX < snapshot.bounds.minX + 150,
                      n.rect.minY >= snapshot.bounds.minY, n.rect.maxY < snapshot.bounds.minY + 60,
                      visible(n.rect, in: snapshot), hasPress(n.element) else { return false }
                let children = snapshot.nodes.indices.filter { snapshot.nodes[$0].parent == index }
                return children.count == 1 && children.allSatisfy {
                    let image = snapshot.nodes[$0]
                    return image.role == kAXImageRole && (30...34).contains(image.rect.width)
                        && (22...26).contains(image.rect.height)
                }
            }
        })
        guard desktopBack.count <= 1 else { throw Failure("无法安全识别抖音桌面返回按钮") }
        return desktopBack.first
    }

    static func liveBack(in snapshot: Snapshot) throws -> Int {
        guard let page = livePage(in: snapshot) ?? snapshot.nodes.indices.first(where: {
            let node = snapshot.nodes[$0]
            return node.role == "AXWebArea" && node.url.flatMap(liveRoomID) != nil
                && visible(node.rect, in: snapshot)
        }) else { throw Failure("当前不是可识别的抖音直播间") }
        if let back = try desktopBack(page: page, in: snapshot) { return back }
        let headers = descendants(of: page, in: snapshot).filter {
            let n = snapshot.nodes[$0]
            return n.classes.contains("__isFullPlayer") && (40...80).contains(n.rect.height)
                && abs(n.rect.minY - snapshot.bounds.minY) < 40
        }
        guard headers.count == 1, let header = headers.first else { throw Failure("没有找到直播间返回栏") }
        let h = snapshot.nodes[header].rect
        // Validated client layout: the leading 36 pt control contains only a 24 pt arrow.
        // Use its AXPress action, never click an estimated location near paid/live controls.
        let candidates = descendants(of: header, in: snapshot).filter { index in
            let n = snapshot.nodes[index]
            guard n.role == kAXGroupRole, (30...44).contains(n.rect.width),
                  (30...44).contains(n.rect.height), n.rect.minX < h.minX + 150,
                  n.rect.minY >= h.minY, n.rect.maxY <= h.maxY,
                  hasPress(n.element) else { return false }
            let children = snapshot.nodes.indices.filter { snapshot.nodes[$0].parent == index }
            return children.count == 1 && children.allSatisfy {
                let image = snapshot.nodes[$0]
                return image.role == kAXImageRole && (20...28).contains(image.rect.width)
                    && (20...28).contains(image.rect.height)
            }
        }
        guard candidates.count == 1, let back = candidates.first else { throw Failure("无法安全识别直播间返回按钮") }
        return back
    }

    static func player(in snapshot: Snapshot) throws -> Int {
        let candidates = snapshot.nodes.indices.filter {
            let n = snapshot.nodes[$0]
            let area = n.rect.intersection(snapshot.bounds)
            return !n.classes.isDisjoint(with: ["douyin-player", "xgplayer"])
                && area.width >= 250 && area.height >= 150
        }.sorted {
            let a = snapshot.nodes[$0].rect.intersection(snapshot.bounds)
            let b = snapshot.nodes[$1].rect.intersection(snapshot.bounds)
            return a.width * a.height > b.width * b.height
        }
        guard let first = candidates.first else { throw Failure("没有找到可见的抖音播放器") }
        if candidates.count > 1 {
            let a = snapshot.nodes[first].rect.intersection(snapshot.bounds)
            let b = snapshot.nodes[candidates[1]].rect.intersection(snapshot.bounds)
            guard a.width * a.height > b.width * b.height * 1.5 else { throw Failure("存在多个抖音播放器，无法确认操作目标") }
        }
        return first
    }

    private static func liveFullscreenState(player: Int, in snapshot: Snapshot) -> Bool? {
        guard let nativeFullscreen = attribute(snapshot.window, "AXFullScreen") as? Bool else { return nil }
        let rect = frame(snapshot.nodes[player].element)
        // The validated live client keeps chat beside the video in fullscreen, so
        // width need not fill the window. Its video and own header span full height.
        let spansHeight = abs(rect.minY - snapshot.bounds.minY) < 3
            && abs(rect.maxY - snapshot.bounds.maxY) < 3
        let hasPlayerHeader = descendants(of: player, in: snapshot).contains {
            snapshot.nodes[$0].classes.contains("douyin-player-top-bar")
                && descendants(of: $0, in: snapshot).contains {
                    snapshot.nodes[$0].classes.contains("__isFullPlayer")
                }
        }
        if nativeFullscreen { return spansHeight && hasPlayerHeader ? true : nil }
        // During the native transition the flag can clear before Chromium restores
        // its windowed header. Wait for that layout before navigating away.
        return hasPlayerHeader ? nil : false
    }

    static func uniqueControl(_ classes: Set<String>, player: Int, in snapshot: Snapshot,
                                      requireVisible: Bool = true) throws -> Int {
        let matches = descendants(of: player, in: snapshot).filter {
            !snapshot.nodes[$0].classes.isDisjoint(with: classes)
                && (!requireVisible || visible(frame(snapshot.nodes[$0].element), in: snapshot))
        }
        guard matches.count == 1, let control = matches.first else { throw Failure("没有找到可确认的抖音播放器控件") }
        return control
    }

    /// Hover the semantic volume target, revealing its own bar only when necessary.
    /// Never use the large video center, which may contain an unrelated floating window.
    static func hoverControl(_ control: Int, player: Int, in snapshot: Snapshot) throws -> () -> Void {
        if visible(frame(snapshot.nodes[control].element), in: snapshot) {
            return try hover(control, in: snapshot)
        }
        let bars = descendants(of: player, in: snapshot).filter {
            !snapshot.nodes[$0].classes.isDisjoint(with: ["douyin-player-controls", "xgplayer-controls"])
                && visible(frame(snapshot.nodes[$0].element), in: snapshot)
        }
        let restoreBar: () -> Void
        if bars.count == 1, let bar = bars.first {
            restoreBar = try hover(bar, in: snapshot)
        } else {
            // Autohide can zero both the bar and volume AX frames. The player's
            // verified visible bounds remain stable: hover inside its lower edge,
            // away from the central remote overlay, then resolve volume bounds again.
            let rect = frame(snapshot.nodes[player].element)
            let point = CGPoint(x: rect.midX, y: rect.maxY - min(24, rect.height / 4))
            restoreBar = try hover(player, at: point, in: snapshot)
        }
        do {
            try wait("无法显示抖音播放器控件", in: snapshot) {
                visible(frame(snapshot.nodes[control].element), in: snapshot)
            }
            let restoreControl = try hover(control, in: snapshot)
            return { restoreControl(); restoreBar() }
        } catch { restoreBar(); throw error }
    }

    private static func controlMetadata(_ element: AXUIElement) -> (classes: Set<String>, numbers: [Int]) {
        var classes: Set<String> = []
        var numbers: [Int] = []
        var remaining = 32
        func visit(_ element: AXUIElement, depth: Int) {
            guard remaining > 0, depth < 8 else { return }
            remaining -= 1
            let values = attributes(element, [kAXRoleAttribute, "AXDOMClassList", kAXChildrenAttribute])
            classes.formUnion(values[1] as? [String] ?? [])
            if values[0] as? String == kAXStaticTextRole,
               let text = attribute(element, kAXValueAttribute) as? String, let value = Int(text), (0...100).contains(value) {
                numbers.append(value)
            }
            for child in values[2] as? [AXUIElement] ?? [] { visit(child, depth: depth + 1) }
        }
        visit(element, depth: 0)
        return (classes, numbers)
    }

    private static func playbackState(_ element: AXUIElement) -> Bool? {
        let classes = controlMetadata(element).classes
        if !classes.isDisjoint(with: ["douyin-player-icon-pause", "xg-icon-pause"]) { return true }
        if !classes.isDisjoint(with: ["douyin-player-icon-play", "xg-icon-play"]) { return false }
        return nil
    }

    private static func soundState(_ element: AXUIElement) -> Bool? {
        let metadata = controlMetadata(element)
        if !metadata.classes.isDisjoint(with: ["douyin-player-muted", "xg-volume-mute"]) { return false }
        if !metadata.classes.isDisjoint(with: ["xg-volume", "xg-volume-small"]) { return true }
        guard metadata.classes.contains("douyin-player-volume-slider"), metadata.numbers.count == 1 else { return nil }
        return metadata.numbers[0] > 0
    }

    static func pressControl(_ control: Int, in snapshot: Snapshot) throws {
        guard let page = primaryPage(snapshot.window), isLivePage(page) else { throw Failure("请先进入抖音直播间") }
        if hasPress(snapshot.nodes[control].element) { try press(control, in: snapshot, requireVisible: false); return }
        let children = descendants(of: control, in: snapshot).filter {
            snapshot.nodes[$0].role == kAXImageRole && hasPress(snapshot.nodes[$0].element)
        }
        guard children.count == 1, let image = children.first else { throw Failure("抖音控件未提供可用的按下操作") }
        try press(image, in: snapshot, requireVisible: false)
    }

    static func press(_ index: Int, in snapshot: Snapshot, requireVisible: Bool = true) throws {
        try validate(snapshot)
        let node = snapshot.nodes[index]
        guard (!requireVisible || visible(frame(node.element), in: snapshot)),
              attribute(node.element, kAXEnabledAttribute) as? Bool != false,
              AXUIElementPerformAction(node.element, kAXPressAction as CFString) == .success else {
            throw Failure("抖音控件当前无法操作")
        }
    }

    static func hover(_ index: Int, at target: CGPoint? = nil, in snapshot: Snapshot) throws -> () -> Void {
        try validate(snapshot)
        let element = snapshot.nodes[index].element
        let rect = frame(element)
        guard visible(rect, in: snapshot), let original = CGEvent(source: nil)?.location else { throw Failure("无法显示抖音播放器控件") }
        let point = target ?? CGPoint(x: rect.midX, y: rect.midY)
        guard rect.contains(point) else { throw Failure("无法确认抖音悬停目标的位置") }
        // A just-dismissed nonactivating remote overlay may remain in the system AX
        // hit cache briefly. Recheck the same target, never move through another window.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        var unobstructed = false
        repeat {
            try validate(snapshot)
            var hit: AXUIElement?
            if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
               let hit {
                var pid: pid_t = 0
                AXUIElementGetPid(hit, &pid)
                let hitWindow = attribute(hit, kAXWindowAttribute)
                unobstructed = pid == snapshot.pid && (belongs(hit, to: snapshot.window)
                    || hitWindow.map { CFEqual($0, snapshot.window) } == true)
            }
            if unobstructed { break }
            yieldForAX(until: deadline)
        } while ProcessInfo.processInfo.systemUptime < deadline
        guard unobstructed,
              let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        else { throw Failure("抖音播放器控件被其他窗口遮挡") }
        move.post(tap: .cghidEventTap)
        return {
            // Do not override a pointer move the user made while the operation was running.
            guard let current = CGEvent(source: nil)?.location,
                  abs(current.x - point.x) < 3, abs(current.y - point.y) < 3 else { return }
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: original, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }

    static func validate(_ snapshot: Snapshot) throws {
        try checkCancellation()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid else {
            throw Failure("抖音前台窗口已改变，请重试")
        }
        guard let current = attribute(snapshot.app, kAXFocusedWindowAttribute),
              CFGetTypeID(current) == AXUIElementGetTypeID(), CFEqual(current, snapshot.window) else {
            throw Failure("抖音前台窗口已改变，请重试", changedFocusedWindow: true)
        }
    }

    /// Client navigation may replace its AX window; follow the same foreground process.
    static func waitForPage(_ failure: String, in snapshot: Snapshot, timeout: TimeInterval = 0.8,
                                    condition: (Page) -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            try checkCancellation()
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid else {
                throw Failure("抖音前台窗口已改变，请重试")
            }
            // Enter/exit animation briefly has no focused AX window at all.
            if let next = try? context(), let page = primaryPage(next.window), condition(page) { return }
            yieldForAX(until: deadline)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw Failure(failure)
    }

    static func wait(_ failure: String, in snapshot: Snapshot, timeout: TimeInterval = 0.8, condition: () -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            try validate(snapshot)
            if condition() { return }
            yieldForAX(until: deadline)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw Failure(failure)
    }

    /// Service AX/AppKit notifications without exceeding the monotonic polling deadline.
    /// Callers revalidate their foreground/window context before reading or acting again.
    static func yieldForAX(until deadline: TimeInterval) {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: min(0.025, remaining)))
    }

    static func descendants(of root: Int, in snapshot: Snapshot) -> [Int] {
        snapshot.nodes.indices.filter { index in
            var parent = snapshot.nodes[index].parent
            while let value = parent {
                if value == root { return true }
                parent = snapshot.nodes[value].parent
            }
            return false
        }
    }

    static func visible(_ rect: CGRect, in snapshot: Snapshot) -> Bool {
        rect.width >= 4 && rect.height >= 4 && snapshot.bounds.contains(CGPoint(x: rect.midX, y: rect.midY))
    }

    static func belongs(_ element: AXUIElement, to target: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<64 {
            guard let node = current else { return false }
            if CFEqual(node, target) { return true }
            guard let parent = attribute(node, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            current = (parent as! AXUIElement)
        }
        return false
    }

    static func hasPress(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        return AXUIElementCopyActionNames(element, &names) == .success && (names as? [String] ?? []).contains(kAXPressAction)
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    static func attributes(_ element: AXUIElement, _ names: [String]) -> [CFTypeRef?] {
        AXUIElementSetMessagingTimeout(element, 0.035)
        var result: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &result) == .success,
              let values = result as? [CFTypeRef], values.count == names.count else { return names.map { _ in nil } }
        return values.map { $0 }
    }

    static func frame(_ element: AXUIElement) -> CGRect {
        let values = attributes(element, [kAXPositionAttribute, kAXSizeAttribute])
        return frame(position: values[0], size: values[1])
    }

    static func frame(position rawPosition: CFTypeRef?, size rawSize: CFTypeRef?) -> CGRect {
        guard let rawPosition, CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              let rawSize, CFGetTypeID(rawSize) == AXValueGetTypeID() else { return .zero }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &position),
              AXValueGetValue(rawSize as! AXValue, .cgSize, &size),
              position.x.isFinite, position.y.isFinite, size.width.isFinite, size.height.isFinite else { return .zero }
        return CGRect(origin: position, size: size)
    }
}
