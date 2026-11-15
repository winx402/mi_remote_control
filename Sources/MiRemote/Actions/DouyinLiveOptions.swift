import AppKit
import ApplicationServices

/// Reads the current room's actual viewer controls. Menu values never come from a
/// saved quality list, and a menu opened in one room cannot act on a different room.
@MainActor
enum DouyinLiveOptions {
    typealias Failure = DouyinControls.Failure
    typealias Snapshot = DouyinControls.Snapshot

    struct Group: Hashable, Sendable {
        let id: String
        let title: String
        let symbol: String
        fileprivate let room: String
        fileprivate let pid: pid_t
        fileprivate let mediaURL: String?
        fileprivate init(id: String, title: String, symbol: String, room: String, pid: pid_t, mediaURL: String? = nil) {
            self.id = id; self.title = title; self.symbol = symbol; self.room = room; self.pid = pid; self.mediaURL = mediaURL
        }
    }
    struct Option: Hashable, Sendable {
        let id: String
        let title: String
        let isSelected: Bool
    }

    struct MenuDiscovery: Sendable {
        let groups: [Group]
        let needsRetry: Bool
        let isMiniWindow: Bool

        var compactGroups: [Group] {
            let ids = ["quality", "volume", "toolbar.rotation", "native"]
            return ids.compactMap { id in groups.first { $0.id == id } }
        }
    }

    /// Scoped by the overlay around an explicitly requested native operation.
    /// Its generation changes on Back/Home, including during legacy AX run-loop
    /// polling. The read-only first-paint worker uses normal Task cancellation.
    static var shouldCancelOperation: (() -> Bool)? {
        get { DouyinControls.operationCancellation }
        set { DouyinControls.operationCancellation = newValue }
    }

    static func checkCancellation() throws { try DouyinControls.checkCancellation() }

    static func discoverMenu() async -> Result<MenuDiscovery, Failure> {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == "com.bytedance.douyin.desktop" else {
            return .failure(Failure("请先切换到抖音"))
        }
        let cached = warmRootCache
        do {
            let reading = try await DouyinLiveDiscovery.read(pid: front.processIdentifier, cache: cached?.anchors)
            try Task.checkCancellation()
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == reading.pid else {
                throw Failure("抖音前台窗口已改变，请重试")
            }
            if reading.isMiniWindow {
                return .success(MenuDiscovery(groups: [], needsRetry: false, isMiniWindow: true))
            }
            guard let room = reading.room else { throw Failure("请先进入抖音直播间") }
            var values = (cached?.groups ?? []).filter {
                reading.cachedGroupIDs.contains($0.id)
                    && ($0.id != "toolbar.miniWindow" || $0.mediaURL == reading.mediaURL)
            }
            if reading.quality, !values.contains(where: { $0.id == "quality" }) { values.append(Group(id: "quality", title: "清晰度", symbol: "4k.tv", room: room, pid: reading.pid)) }
            if reading.volume, !values.contains(where: { $0.id == "volume" }) { values.append(Group(id: "volume", title: "声音", symbol: "speaker.wave.2", room: room, pid: reading.pid)) }
            if reading.rotation, !values.contains(where: { $0.id == "toolbar.rotation" }) { values.append(Group(id: "toolbar.rotation", title: "屏幕旋转", symbol: "rotate.right", room: room, pid: reading.pid)) }
            if reading.nativeToolbar {
                values.append(Group(id: "native", title: "更多播放器设置", symbol: "slider.horizontal.3", room: room, pid: reading.pid))
            }
            return .success(MenuDiscovery(groups: values, needsRetry: reading.needsRetry, isMiniWindow: false))
        } catch let failure as Failure { return .failure(failure) }
        catch let problem as DouyinLiveDiscovery.Problem { return .failure(Failure(problem.message)) }
        catch is CancellationError { return .failure(Failure("已取消读取抖音播放器设置")) }
        catch { return .failure(Failure("读取抖音设置失败：\(error.localizedDescription)")) }
    }

    /// Full native inspection is opt-in: the caller hides its covering overlay
    /// before invoking this. Bind both ends so navigation cannot publish a stale
    /// room's conditional settings under the new room.
    static func nativeGroups(in group: Group) -> Result<[Group], Failure> {
        do {
            try checkCancellation()
            _ = try current(room: group.room, pid: group.pid)
            switch groups() {
            case .failure(let failure): return .failure(failure)
            case .success(let groups):
                _ = try current(room: group.room, pid: group.pid)
                try checkCancellation()
                guard groups.allSatisfy({ $0.room == group.room && $0.pid == group.pid }) else {
                    throw Failure("直播间已改变，请重新打开播放器设置")
                }
                return .success(groups)
            }
        } catch let failure as Failure { return .failure(failure) }
        catch { return .failure(Failure("读取抖音设置失败：\(error.localizedDescription)")) }
    }

    private struct WarmRootCache {
        let groups: [Group]
        let anchors: DouyinLiveDiscovery.Anchors
    }
    private static var warmRootCache: WarmRootCache?
    private(set) static var needsRetry = false
    private static var toolbarCache: [String: [Kind: AXUIElement]] = [:]
    private static var cachedToolbarCandidates: [String: [AXUIElement]] = [:]
    private struct PanelGroup { let id: String; let title: String; let symbol: String }
    private struct PanelCache { let anchor: AXUIElement; let groups: [PanelGroup] }
    private static var lastPanelGroups: [String: [Kind: PanelCache]] = [:]

    private struct ToolbarItem { let kind: Kind }
    private enum Kind: String, CaseIterable {
        case danmaku, effects, windowFullscreen, miniWindow, refresh, rotation
        var title: String {
            switch self {
            case .danmaku: "弹幕设置"
            case .effects: "礼物特效"
            case .windowFullscreen: "窗口全屏"
            case .miniWindow: "小窗模式"
            case .rotation: "屏幕旋转"
            case .refresh: "刷新直播"
            }
        }
        var symbol: String {
            switch self {
            case .danmaku: "text.bubble"
            case .effects: "sparkles"
            case .windowFullscreen: "rectangle.expand.vertical"
            case .miniWindow: "pip"
            case .rotation: "rotate.right"
            case .refresh: "arrow.clockwise"
            }
        }
    }

    static func groups() -> Result<[Group], Failure> {
        read {
            needsRetry = false
            try checkCancellation()
            let initial = try current()
            let room = try roomKey(initial)
            let player = try DouyinControls.player(in: initial)
            var result: [Group] = []
            if qualityRoot(in: initial, player: player) != nil {
                result.append(Group(id: "quality", title: "清晰度", symbol: "4k.tv", room: room, pid: initial.pid))
            }
            if DouyinPlayerVolume.isAvailable(in: initial, player: player) {
                result.append(Group(id: "volume", title: "声音", symbol: "speaker.wave.2", room: room, pid: initial.pid))
            }
            let items: [ToolbarItem]
            do { items = try discoverToolbar(in: initial) }
            catch {
                let fresh = try current(room: room, pid: initial.pid)
                let p = try DouyinControls.player(in: fresh)
                let descendants = DouyinControls.descendants(of: p, in: fresh)
                let cached = toolbarCache[cacheKey(room: room, pid: initial.pid)] ?? [:]
                items = Kind.allCases.filter { kind in
                    guard let anchor = cached[kind] else { return false }
                    return descendants.contains { CFEqual(fresh.nodes[$0].element, anchor) }
                }.map { ToolbarItem(kind: $0) }
                needsRetry = true
            }
            for item in items {
                if item.kind == .danmaku || item.kind == .effects {
                    let values = try panelGroups(item.kind, room: room, pid: initial.pid)
                    let prefix = item.kind == .danmaku ? "danmaku." : "gift."
                    result += values.map { Group(id: prefix + $0.id, title: $0.title, symbol: $0.symbol,
                                                 room: room, pid: initial.pid) }
                } else {
                    result.append(Group(id: "toolbar." + item.kind.rawValue, title: item.kind.title,
                                        symbol: item.kind.symbol, room: room, pid: initial.pid,
                                        mediaURL: item.kind == .miniWindow ? streamURL(in: initial) : nil))
                }
            }
            let verified = try current(room: room, pid: initial.pid)
            rememberRootGroups(result, in: verified, room: room)
            return result
        }
    }

    /// Only confirmed selections from a fresh native options read may annotate
    /// the root card. An empty/ambiguous selection clears a previous value.
    static func refreshedGroup(_ group: Group, options: [Option]) -> Group {
        let label = group.title.components(separatedBy: " · ").first ?? group.title
        let selected = options.filter(\.isSelected)
        let title = selected.count == 1 ? label + " · " + selected[0].title : label
        return Group(id: group.id, title: title, symbol: group.symbol,
                     room: group.room, pid: group.pid, mediaURL: group.mediaURL)
    }

    static func options(in group: Group) -> Result<[Option], Failure> {
        read {
            let values = try optionsForGroup(group)
            if group.id == "toolbar.miniWindow", let mini = try? DouyinControls.snapshot(), miniWindow(mini) {
                try validateMiniWindow(mini, group: group)
            } else {
                _ = try current(room: group.room, pid: group.pid)
            }
            try checkCancellation()
            return values
        }
    }

    static func execute(_ option: Option, in group: Group) -> String? {
        do {
            try DouyinControls.withOperation {
                try checkCancellation()
                if group.id == "toolbar.miniWindow", let mini = try? DouyinControls.snapshot(), miniWindow(mini) {
                    try validateMiniWindow(mini, group: group)
                    guard ["on", "off"].contains(option.id) else { throw Failure("无效的小窗设置选项") }
                    if option.id == "off" { try returnFromMiniWindow(mini, expectedRoom: group.room) }
                } else if group.id == "volume" {
                    try checkCancellation()
                    let snapshot = try current(room: group.room, pid: group.pid)
                    try DouyinPlayerVolume.apply(option, in: snapshot, player: DouyinControls.player(in: snapshot))
                } else if group.id == "quality" {
                    try withQuality(group) { snapshot, root in
                        let choices = try qualityChoices(snapshot, root: root)
                        guard let choice = choices.first(where: { $0.title == option.id }) else {
                            throw Failure("该清晰度已不可用，请重新打开清晰度菜单")
                        }
                        if choice.title == (try qualityValue(snapshot, root: root)) { return }
                        try validateBoundRoom(group, in: snapshot)
                        try DouyinControls.press(choice.index, in: snapshot)
                        let deadline = ProcessInfo.processInfo.systemUptime + 2
                        repeat {
                            try checkCancellation()
                            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == group.pid else {
                                throw Failure("抖音前台窗口已改变，请重试")
                            }
                            if let updated = try? current(room: group.room, pid: group.pid),
                               let p = try? DouyinControls.player(in: updated),
                               let r = qualityRoot(in: updated, player: p),
                               (try? qualityValue(updated, root: r)) == choice.title { return }
                            DouyinControls.yieldForAX(until: deadline)
                        } while ProcessInfo.processInfo.systemUptime < deadline
                        throw Failure("抖音尚未确认清晰度已切换")
                    }
                } else if group.id.hasPrefix("gift.") {
                    guard let label = giftLabels[String(group.id.dropFirst(5))], ["on", "off"].contains(option.id) else {
                        throw Failure("礼物显示设置选项已失效")
                    }
                    try withToolbar(.effects, room: group.room, pid: group.pid) { snapshot, _, panel in
                        try DouyinDanmakuOptions.setSwitch(label: label, enabled: option.id == "on", snapshot: snapshot, panel: panel)
                    }
                } else if group.id.hasPrefix("danmaku.") {
                    try withToolbar(.danmaku, room: group.room, pid: group.pid) { snapshot, _, panel in
                        try DouyinDanmakuOptions.execute(option.id, in: String(group.id.dropFirst("danmaku.".count)),
                                                        snapshot: snapshot, panel: panel)
                    }
                } else {
                    guard let kind = Kind(rawValue: String(group.id.dropFirst("toolbar.".count))) else {
                        throw Failure("该播放器设置已不可用，请重新打开菜单")
                    }
                    try executeToolbar(option, kind: kind, group: group)
                }
            }
            return nil
        } catch let failure as Failure { return failure.message }
        catch { return "抖音设置操作失败：\(error.localizedDescription)" }
    }

    private static func optionsForGroup(_ group: Group) throws -> [Option] {
        if group.id == "toolbar.miniWindow", let mini = try? DouyinControls.snapshot(), miniWindow(mini) {
            try validateMiniWindow(mini, group: group)
            return [Option(id: "on", title: "开启", isSelected: true), Option(id: "off", title: "关闭", isSelected: false)]
        }
        if group.id == "volume" {
            try checkCancellation()
            let snapshot = try current(room: group.room, pid: group.pid)
            return try DouyinPlayerVolume.choices(in: snapshot, player: DouyinControls.player(in: snapshot))
        }
        if group.id == "quality" {
            return try withQuality(group) { snapshot, root in
                let selected = try qualityValue(snapshot, root: root)
                let choices = try qualityChoices(snapshot, root: root)
                guard choices.contains(where: { $0.title == selected }) else {
                    throw Failure("无法确认抖音当前清晰度")
                }
                return choices.map { Option(id: $0.title, title: $0.title, isSelected: $0.title == selected) }
            }
        }
        if group.id.hasPrefix("gift.") {
            guard let label = giftLabels[String(group.id.dropFirst(5))] else { throw Failure("礼物显示设置选项已失效") }
            return try withToolbar(.effects, room: group.room, pid: group.pid) { snapshot, _, panel in
                guard let state = DouyinDanmakuOptions.switchState(label: label, in: snapshot, panel: panel) else {
                    throw Failure("无法确认该礼物显示设置的状态")
                }
                return [Option(id: "on", title: "开启", isSelected: state), Option(id: "off", title: "关闭", isSelected: !state)]
            }
        }
        if group.id.hasPrefix("danmaku.") {
            return try withToolbar(.danmaku, room: group.room, pid: group.pid) { snapshot, _, panel in
                try DouyinDanmakuOptions.options(in: String(group.id.dropFirst("danmaku.".count)),
                                                snapshot: snapshot, panel: panel)
            }
        }
        guard let kind = Kind(rawValue: String(group.id.dropFirst("toolbar.".count))) else {
            throw Failure("该播放器设置已不可用，请重新打开菜单")
        }
        return try withToolbar(kind, room: group.room, pid: group.pid) { snapshot, _, root in
            let title = try toolbarTitle(root, in: snapshot, kind: kind)
            if let enabled = enabledState(title, kind: kind) {
                return [Option(id: "on", title: "开启", isSelected: enabled),
                        Option(id: "off", title: "关闭", isSelected: !enabled)]
            }
            return [Option(id: "perform", title: kind.title, isSelected: false)]
        }
    }

    /// A PiP window has no room URL. Recognize its dedicated semantic background
    /// and player tree, rather than treating an arbitrary about:blank window as live.
    static func isMiniWindow() -> Bool {
        guard let snapshot = try? DouyinControls.snapshot() else { return false }
        return miniWindow(snapshot)
    }

    static func returnToLargeWindow() -> String? {
        do {
            try DouyinControls.withOperation {
                try checkCancellation()
                let snapshot = try DouyinControls.snapshot()
                guard miniWindow(snapshot) else { throw Failure("当前不是抖音直播小窗") }
                try returnFromMiniWindow(snapshot, expectedRoom: nil)
            }
            return nil
        } catch let failure as Failure { return failure.message }
        catch { return "返回大窗播放失败：\(error.localizedDescription)" }
    }

    private static func miniWindow(_ snapshot: Snapshot) -> Bool {
        snapshot.nodes.contains { $0.classes.contains("livingPipBackground") }
            && snapshot.nodes.contains { $0.classes.contains("pip-anchor") }
            && (try? DouyinControls.player(in: snapshot)) != nil
            && streamURL(in: snapshot) != nil
    }

    private static func streamURL(in snapshot: Snapshot) -> String? {
        snapshot.nodes.compactMap(\.url).first { $0.scheme == "blob" && $0.absoluteString.contains("douyin.com/") }?.absoluteString
    }

    private static func validateMiniWindow(_ snapshot: Snapshot, group: Group) throws {
        guard snapshot.pid == group.pid, let expected = group.mediaURL, streamURL(in: snapshot) == expected else {
            throw Failure("直播间已改变，请重新打开播放器设置")
        }
        try DouyinControls.validate(snapshot)
    }

    private static func returnFromMiniWindow(_ snapshot: Snapshot, expectedRoom: String?) throws {
        let player = try DouyinControls.player(in: snapshot)
        let top = try DouyinControls.uniqueControl(["douyin-player-top-bar"], player: player, in: snapshot, requireVisible: false)
        let buttons = snapshot.nodes.indices.filter { index in
            let n = snapshot.nodes[index]
            guard n.parent == top, n.role == kAXGroupRole, (28...36).contains(n.rect.width),
                  DouyinControls.hasPress(n.element) else { return false }
            let children = snapshot.nodes.indices.filter { snapshot.nodes[$0].parent == index }
            return children.count == 1 && children.allSatisfy { snapshot.nodes[$0].role == kAXImageRole }
        }.sorted { snapshot.nodes[$0].rect.minX < snapshot.nodes[$1].rect.minX }
        guard buttons.count == 2, let back = buttons.first,
              abs(snapshot.nodes[back].rect.minX - (snapshot.bounds.maxX - 72)) < 4 else {
            throw Failure("无法确认小窗的返回大窗按钮")
        }
        // Shipped living-PiP header: first icon invokes b(true), which focuses
        // the origin window before closing; second icon only closes b(false).
        try DouyinControls.press(back, in: snapshot, requireVisible: false)
        try DouyinControls.waitForPage("抖音尚未确认返回大窗播放", in: snapshot, timeout: 3) { page in
            DouyinControls.isLivePage(page) && (expectedRoom == nil || page.url.pathComponents.last == expectedRoom)
        }
        toolbarCache = [:]
        cachedToolbarCandidates = [:]
        warmRootCache = nil
    }

    private static func read<T>(_ operation: () throws -> T) -> Result<T, Failure> {
        do {
            try checkCancellation()
            return .success(try DouyinControls.withOperation(operation))
        }
        catch let failure as Failure { return .failure(failure) }
        catch { return .failure(Failure("读取抖音设置失败：\(error.localizedDescription)")) }
    }

    private static func current(room: String? = nil, pid: pid_t? = nil) throws -> Snapshot {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.6
        repeat {
            try checkCancellation()
            do { return try currentOnce(room: room, pid: pid) }
            catch let failure as Failure {
                let transient = failure.pendingFocusedWindow || failure.retryableSnapshot
                    || failure.message == "请先进入抖音直播间" || failure.message == "没有找到可见的抖音播放器"
                guard transient, ProcessInfo.processInfo.systemUptime < deadline else { throw failure }
            }
            DouyinControls.yieldForAX(until: deadline)
        } while true
    }

    private static func currentOnce(room: String?, pid: pid_t?) throws -> Snapshot {
        try checkCancellation()
        let snapshot = try DouyinControls.snapshot()
        let key = try roomKey(snapshot)
        guard room == nil || room == key, pid == nil || pid == snapshot.pid else {
            throw Failure("直播间已改变，请重新打开播放器设置")
        }
        let player = try DouyinControls.player(in: snapshot)
        // This is a viewer interruption, not an invitation to take over playback
        // from another device. Never activate the accompanying 继续看播 control.
        if texts(player, in: snapshot).contains("账号已在其他地方进入直播间") {
            throw Failure("账号已在其他地方看播，请先在抖音客户端确认继续看播")
        }
        try DouyinControls.validate(snapshot)
        return snapshot
    }

    private static func roomKey(_ snapshot: Snapshot) throws -> String {
        guard let page = DouyinControls.primaryPage(snapshot.window),
              let roomID = DouyinControls.liveRoomID(page.url) else {
            throw Failure("请先进入抖音直播间")
        }
        return roomID
    }

    private static func qualityRoot(in snapshot: Snapshot, player: Int) -> Int? {
        let matches = DouyinControls.descendants(of: player, in: snapshot).filter {
            snapshot.nodes[$0].classes.contains("QualitySwitchNewPlugin")
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func withQuality<T>(_ group: Group, _ body: (Snapshot, Int) throws -> T) throws -> T {
        try checkCancellation()
        let snapshot = try current(room: group.room, pid: group.pid)
        let player = try DouyinControls.player(in: snapshot)
        guard qualityRoot(in: snapshot, player: player) != nil else { throw Failure("当前直播没有可识别的清晰度选项") }
        var restores: [() -> Void] = []
        defer { for restore in restores.reversed() { restore() } }
        let playerRect = DouyinControls.frame(snapshot.nodes[player].element)
        // Dismissing an opaque remote panel can leave Chromium's hover state stale.
        // Leave the player through a verified point in the same focused window,
        // then enter its lower band; never click the video/sidebar to wake it.
        let outside = [CGPoint(x: snapshot.bounds.maxX - 12, y: snapshot.bounds.midY),
                       CGPoint(x: snapshot.bounds.midX, y: snapshot.bounds.minY + 12)]
            .first { !playerRect.contains($0) }
        if let outside { restores.append(try DouyinControls.hover(0, at: outside, in: snapshot)) }
        let inset = min(48, playerRect.width / 4)
        let left = playerRect.minX + inset, right = playerRect.maxX - inset
        let original = CGEvent(source: nil)?.location ?? .zero
        let reveal = CGPoint(x: abs(original.x - left) > abs(original.x - right) ? left : right,
                             y: playerRect.maxY - min(24, playerRect.height / 4))
        restores.append(try DouyinControls.hover(player, at: reveal, in: snapshot))

        // The autohide animation publishes 1px and intermediate AX frames. A
        // merely nonzero frame can move away from the pointer a moment later.
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var previous: CGRect?
        var stableLabel: (Snapshot, Int)?
        repeat {
            try checkCancellation()
            let shown = try current(room: group.room, pid: group.pid)
            if let p = try? DouyinControls.player(in: shown), let q = qualityRoot(in: shown, player: p),
               let label = qualityLabel(in: shown, root: q) {
                let rect = DouyinControls.frame(shown.nodes[label].element)
                if rect.height >= 12, DouyinControls.visible(rect, in: shown), let previous,
                   abs(rect.midX - previous.midX) < 1, abs(rect.midY - previous.midY) < 1,
                   abs(rect.width - previous.width) < 1, abs(rect.height - previous.height) < 1 {
                    stableLabel = (shown, label)
                    break
                }
                previous = rect
            }
            DouyinControls.yieldForAX(until: deadline)
        } while ProcessInfo.processInfo.systemUptime < deadline
        guard let (shown, label) = stableLabel else { throw Failure("无法显示抖音清晰度控件") }
        restores.append(try DouyinControls.hover(label, in: shown))
        var reenteredAfterBlur = false
        let hoverStart = ProcessInfo.processInfo.systemUptime
        repeat {
            try checkCancellation()
            let updated = try current(room: group.room, pid: group.pid)
            if let p = try? DouyinControls.player(in: updated), let q = qualityRoot(in: updated, player: p) {
                if (try? qualityChoices(updated, root: q).isEmpty) == false { return try body(updated, q) }
                if let label = qualityLabel(in: updated, root: q) {
                    let rect = DouyinControls.frame(updated.nodes[label].element)
                    if rect.height >= 12, DouyinControls.visible(rect, in: updated) {
                        // Follow a final animation displacement. Also permit one
                        // genuine re-entry after the client's 300ms BLUR debounce.
                        if !rect.contains(CGEvent(source: nil)?.location ?? .zero) {
                            restores.append(try DouyinControls.hover(label, in: updated))
                        } else if !reenteredAfterBlur, ProcessInfo.processInfo.systemUptime - hoverStart > 0.35 {
                            restores.append(try DouyinControls.hover(player, at: reveal, in: snapshot))
                            restores.append(try DouyinControls.hover(label, in: updated))
                            reenteredAfterBlur = true
                        }
                    }
                }
            }
            DouyinControls.yieldForAX(until: deadline)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw Failure("抖音清晰度菜单尚未显示")
    }

    private static func qualityLabel(in snapshot: Snapshot, root: Int) -> Int? {
        DouyinControls.descendants(of: root, in: snapshot).first { snapshot.nodes[$0].role == kAXStaticTextRole }
    }

    private static func qualityValue(_ snapshot: Snapshot, root: Int) throws -> String {
        // The control's shallow label remains current when its popup is dismissed.
        let descendants = DouyinControls.descendants(of: root, in: snapshot)
        let labels = descendants.filter { snapshot.nodes[$0].role == kAXStaticTextRole }
        guard let first = labels.first, let value = DouyinControls.attribute(snapshot.nodes[first].element, kAXValueAttribute) as? String,
              !value.isEmpty else { throw Failure("无法读取抖音当前清晰度") }
        return value
    }

    private static func qualityChoices(_ snapshot: Snapshot, root: Int) throws -> [(title: String, index: Int)] {
        let descendants = DouyinControls.descendants(of: root, in: snapshot)
        let rows = descendants.filter { DouyinControls.hasPress(snapshot.nodes[$0].element) }
        var result: [(String, Int)] = []
        for row in rows {
            let values = texts(row, in: snapshot)
            guard values.count == 1, let title = values.first, !title.isEmpty,
                  DouyinControls.visible(DouyinControls.frame(snapshot.nodes[row].element), in: snapshot) else { continue }
            guard !result.contains(where: { $0.0 == title }) else { throw Failure("抖音清晰度菜单包含重复选项，无法安全选择") }
            result.append((title, row))
        }
        guard !result.isEmpty, result.count <= 16 else { throw Failure("无法读取当前直播的清晰度列表") }
        return result
    }

    fileprivate static func texts(_ root: Int, in snapshot: Snapshot) -> [String] {
        ([root] + DouyinControls.descendants(of: root, in: snapshot)).compactMap {
            guard snapshot.nodes[$0].role == kAXStaticTextRole,
                  let text = DouyinControls.attribute(snapshot.nodes[$0].element, kAXValueAttribute) as? String else { return nil }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
    }

    private static func toolbarRoots(_ snapshot: Snapshot, player: Int) throws -> [Int] {
        let bar = try DouyinControls.uniqueControl(["douyin-player-controls"], player: player, in: snapshot, requireVisible: false)
        // Only hover immediate compact controls in the verified player bar. Large
        // video/chat/gift subtrees and empty layout hit regions are never explored.
        return snapshot.nodes.indices.filter { index in
            let node = snapshot.nodes[index]
            return node.parent == bar && (24...64).contains(node.rect.width)
                && !(["QualitySwitchNewPlugin", "douyin-player-play", "douyin-player-volume", "douyin-player-fullscreen", "douyin-player-rotate"]
                    .contains(where: { semantic in ([index] + DouyinControls.descendants(of: index, in: snapshot)).contains { snapshot.nodes[$0].classes.contains(semantic) } }))
        }
    }

    private static func toolbarHoverAnchor(_ root: Int, in snapshot: Snapshot) -> Int {
        let images = DouyinControls.descendants(of: root, in: snapshot).filter {
            snapshot.nodes[$0].role == kAXImageRole && (16...48).contains(snapshot.nodes[$0].rect.width)
        }
        return images.count == 1 ? images[0] : root
    }

    private static func kind(for labels: [String]) -> Kind? {
        if labels.contains("弹幕设置") { return .danmaku }
        let value = labels.joined()
        if value.contains("礼物特效") { return .effects }
        if value.contains("窗口全屏") { return .windowFullscreen }
        if value.contains("小窗模式") || value.contains("返回大窗播放") { return .miniWindow }
        if value.contains("刷新") { return .refresh }
        return nil
    }

    private static func prepareToolbar(_ initial: Snapshot) throws -> (snapshot: Snapshot, player: Int, restore: () -> Void) {
        let player = try DouyinControls.player(in: initial)
        let room = try roomKey(initial)
        let rect = DouyinControls.frame(initial.nodes[player].element)
        var restores: [() -> Void] = []
        func restore() { for action in restores.reversed() { action() } }
        do {
            let bar = try DouyinControls.uniqueControl(["douyin-player-controls"], player: player, in: initial, requireVisible: false)
            if initial.nodes[player].classes.contains("douyin-player-controls-autohide") || DouyinControls.frame(initial.nodes[bar].element).height < 24 {
                let outside = [CGPoint(x: initial.bounds.maxX - 12, y: initial.bounds.midY),
                               CGPoint(x: initial.bounds.midX, y: initial.bounds.minY + 12)].first { !rect.contains($0) }
                if let outside {
                    restores.append(try DouyinControls.hover(0, at: outside, in: initial))
                    DouyinControls.yieldForAX(until: ProcessInfo.processInfo.systemUptime + 0.025)
                }
                let reveal = CGPoint(x: rect.minX + min(48, rect.width / 4), y: rect.maxY - min(24, rect.height / 4))
                restores.append(try DouyinControls.hover(player, at: reveal, in: initial))
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 1.2
            var previous: CGRect?
            repeat {
                try checkCancellation()
                let fresh = try current(room: room, pid: initial.pid)
                let p = try DouyinControls.player(in: fresh)
                let b = try DouyinControls.uniqueControl(["douyin-player-controls"], player: p, in: fresh, requireVisible: false)
                let frame = DouyinControls.frame(fresh.nodes[b].element)
                if frame.height >= 24, let previous,
                   abs(frame.midY - previous.midY) < 1, abs(frame.height - previous.height) < 1 {
                    return (fresh, p, restore)
                }
                previous = frame
                DouyinControls.yieldForAX(until: deadline)
            } while ProcessInfo.processInfo.systemUptime < deadline
            throw Failure("抖音播放器控制栏尚未稳定显示，请重试")
        } catch { restore(); throw error }
    }

    private static func panelGroups(_ kind: Kind, room: String, pid: pid_t) throws -> [PanelGroup] {
        let key = cacheKey(room: room, pid: pid)
        do {
            let values = try withToolbar(kind, room: room, pid: pid) { snapshot, _, panel -> [PanelGroup] in
                if kind == .danmaku {
                    return try DouyinDanmakuOptions.descriptors(in: snapshot, panel: panel).map {
                        PanelGroup(id: $0.id, title: $0.title, symbol: $0.symbol)
                    }
                }
                return try giftOptions(in: snapshot, panel: panel).map { PanelGroup(id: $0.id, title: $0.title, symbol: "gift") }
            }
            if let anchor = toolbarCache[key]?[kind] {
                lastPanelGroups = [key: (lastPanelGroups[key] ?? [:])]
                lastPanelGroups[key, default: [:]][kind] = PanelCache(anchor: anchor, groups: values)
            }
            return values
        } catch {
            try checkCancellation()
            needsRetry = true
            let fresh = try current(room: room, pid: pid)
            let p = try DouyinControls.player(in: fresh)
            if let cached = lastPanelGroups[key]?[kind], DouyinControls.descendants(of: p, in: fresh).contains(where: {
                CFEqual(fresh.nodes[$0].element, cached.anchor)
            }) { return cached.groups }
            return []
        }
    }

    private static func rememberRootGroups(_ groups: [Group], in snapshot: Snapshot, room: String) {
        guard let player = try? DouyinControls.player(in: snapshot),
              let bar = try? DouyinControls.uniqueControl(["douyin-player-controls"], player: player,
                                                          in: snapshot, requireVisible: false) else {
            warmRootCache = nil
            return
        }
        let descendants = DouyinControls.descendants(of: player, in: snapshot)
        let toolbar = toolbarCache[cacheKey(room: room, pid: snapshot.pid)] ?? [:]
        var anchors: [String: AXUIElement] = [:]
        for group in groups {
            let element: AXUIElement?
            if group.id == "quality", let root = qualityRoot(in: snapshot, player: player) {
                element = snapshot.nodes[root].element
            } else if group.id == "volume", let root = try? DouyinControls.uniqueControl(
                ["douyin-player-volume"], player: player, in: snapshot, requireVisible: false) {
                element = snapshot.nodes[root].element
            } else if group.id == "toolbar.rotation", let root = try? DouyinControls.uniqueControl(
                ["douyin-player-rotate"], player: player, in: snapshot, requireVisible: false) {
                element = snapshot.nodes[root].element
            } else if group.id.hasPrefix("danmaku.") { element = toolbar[.danmaku] }
            else if group.id.hasPrefix("gift.") { element = toolbar[.effects] }
            else if group.id.hasPrefix("toolbar."), let kind = Kind(rawValue: String(group.id.dropFirst(8))) {
                element = toolbar[kind]
            } else { element = nil }
            if let element, descendants.contains(where: { CFEqual(snapshot.nodes[$0].element, element) }) {
                anchors[group.id] = element
            }
        }
        let labelsOnly = groups.map { group in
            Group(id: group.id, title: group.title.components(separatedBy: " · ").first ?? group.title,
                  symbol: group.symbol, room: group.room, pid: group.pid, mediaURL: group.mediaURL)
        }
        warmRootCache = WarmRootCache(groups: labelsOnly, anchors: DouyinLiveDiscovery.Anchors(
            pid: snapshot.pid, room: room, window: snapshot.window, player: snapshot.nodes[player].element,
            toolbar: snapshot.nodes[bar].element, groups: anchors))
    }

    private static func cacheKey(room: String, pid: pid_t) -> String { "\(pid):\(room)" }

    private static func discoverToolbar(in initial: Snapshot) throws -> [ToolbarItem] {
        let prepared = try prepareToolbar(initial)
        defer { prepared.restore() }
        let snapshot = prepared.snapshot, player = prepared.player
        var result: [ToolbarItem] = []
        var duplicates: Set<Kind> = []
        let room = try roomKey(snapshot)
        let key = cacheKey(room: room, pid: snapshot.pid)
        let roots = try toolbarRoots(snapshot, player: player)
        if let candidates = cachedToolbarCandidates[key], candidates.count == roots.count,
           roots.allSatisfy({ root in candidates.contains { CFEqual($0, snapshot.nodes[root].element) } }),
           let known = toolbarCache[key], known.count == roots.count {
            let knownItems = Kind.allCases.filter { known[$0] != nil }.map { ToolbarItem(kind: $0) }
            return knownItems + (DouyinControls.descendants(of: player, in: snapshot).contains {
                snapshot.nodes[$0].classes.contains("douyin-player-rotate")
            } ? [ToolbarItem(kind: .rotation)] : [])
        }
        let descendants = Set(DouyinControls.descendants(of: player, in: snapshot))
        let previous = (toolbarCache[key] ?? [:]).filter { _, element in
            snapshot.nodes.indices.contains { descendants.contains($0) && CFEqual(snapshot.nodes[$0].element, element) }
        }
        toolbarCache = [key: previous]
        cachedToolbarCandidates = [:]
        for root in roots {
            try checkCancellation()
            do {
                let anchor = toolbarHoverAnchor(root, in: snapshot)
                let restore = try DouyinControls.hoverControl(anchor, player: player, in: snapshot)
                defer { restore() }
                guard let (updated, updatedRoot, kind) = try hoveredToolbar(root, in: snapshot, room: room, expected: nil) else {
                    needsRetry = true
                    continue
                }
                if result.contains(where: { $0.kind == kind }) {
                    result.removeAll { $0.kind == kind }
                    toolbarCache[key]?[kind] = nil
                    duplicates.insert(kind)
                    continue
                }
                guard !duplicates.contains(kind) else { continue }
                toolbarCache[key, default: [:]][kind] = updated.nodes[updatedRoot].element
                result.append(ToolbarItem(kind: kind))
            } catch {
                try checkCancellation()
                needsRetry = true
                try DouyinControls.validate(snapshot)
                guard (try? roomKey(snapshot)) == room else {
                    throw Failure("直播间已改变，请重新打开播放器设置")
                }
            }
        }
        // A timeout on a different optional icon must not erase an already
        // verified control whose exact AX element is still in this room's player.
        for (kind, element) in previous where !duplicates.contains(kind) && !result.contains(where: { $0.kind == kind }) {
            toolbarCache[key, default: [:]][kind] = element
            result.append(ToolbarItem(kind: kind))
        }
        if result.count == roots.count {
            cachedToolbarCandidates[key] = roots.map { snapshot.nodes[$0].element }
        }
        // Rotation is identified by a semantic class even before its tooltip opens.
        if DouyinControls.descendants(of: player, in: snapshot).contains(where: { snapshot.nodes[$0].classes.contains("douyin-player-rotate") }) {
            result.append(ToolbarItem(kind: .rotation))
        }
        return result.sorted { Kind.allCases.firstIndex(of: $0.kind)! < Kind.allCases.firstIndex(of: $1.kind)! }
    }

    private static func withToolbar<T>(_ kind: Kind, room: String, pid: pid_t,
                                       _ body: (Snapshot, Int, Int) throws -> T) throws -> T {
        let prepared = try prepareToolbar(current(room: room, pid: pid))
        defer { prepared.restore() }
        let snapshot = prepared.snapshot, player = prepared.player
        if kind == .rotation {
            let root = try DouyinControls.uniqueControl(["douyin-player-rotate"], player: player, in: snapshot, requireVisible: false)
            let anchor = toolbarHoverAnchor(root, in: snapshot)
            let restore = try DouyinControls.hoverControl(anchor, player: player, in: snapshot)
            defer { restore() }
            return try body(snapshot, player, root)
        }
        let roots: [Int]
        let key = cacheKey(room: room, pid: pid)
        if let cached = toolbarCache[key]?[kind],
           let index = snapshot.nodes.indices.first(where: { CFEqual(snapshot.nodes[$0].element, cached) }),
           DouyinControls.descendants(of: player, in: snapshot).contains(index) {
            // Moving the video into/out of PiP may retain the outer AX wrapper
            // while replacing its button. Fall back to the other current branches
            // if the cached branch no longer exposes the expected tooltip.
            roots = [index] + (try toolbarRoots(snapshot, player: player)).filter { $0 != index }
        } else {
            roots = try toolbarRoots(snapshot, player: player)
        }
        for root in roots {
            try checkCancellation()
            let anchor = toolbarHoverAnchor(root, in: snapshot)
            let restore = try DouyinControls.hoverControl(anchor, player: player, in: snapshot)
            defer { restore() }
            guard let (updated, index, _) = try hoveredToolbar(root, in: snapshot, room: room, expected: kind) else { continue }
            toolbarCache[key, default: [:]][kind] = updated.nodes[index].element
            if kind == .danmaku || kind == .effects {
                let headingTitle = kind == .danmaku ? "弹幕设置" : "礼物设置"
                let headings = DouyinControls.descendants(of: index, in: updated).filter {
                    updated.nodes[$0].role == kAXStaticTextRole && texts($0, in: updated) == [headingTitle]
                }
                guard headings.count == 1, let heading = headings.first else {
                    throw Failure("无法确认抖音\(headingTitle)面板")
                }
                let rowLabel = kind == .danmaku ? "不透明度" : "屏蔽礼物特效"
                var panel = updated.nodes[heading].parent
                while let candidate = panel, candidate != index {
                    if texts(candidate, in: updated).contains(rowLabel) {
                        return try body(updated, try DouyinControls.player(in: updated), candidate)
                    }
                    panel = updated.nodes[candidate].parent
                }
                throw Failure("无法确认抖音\(headingTitle)选项")
            }
            return try body(updated, try DouyinControls.player(in: updated), index)
        }
        throw Failure("当前直播已没有该播放器选项，请重新打开设置菜单")
    }

    private static func hoveredToolbar(_ root: Int, in snapshot: Snapshot, room: String, expected: Kind?) throws -> (Snapshot, Int, Kind)? {
        let element = snapshot.nodes[root].element
        let deadline = ProcessInfo.processInfo.systemUptime + 0.7
        repeat {
            try checkCancellation()
            try DouyinControls.validate(snapshot)
            let updated: Snapshot
            do { updated = try current(room: room, pid: snapshot.pid) }
            catch let failure as Failure {
                if failure.message == "直播间已改变，请重新打开播放器设置" { throw failure }
                DouyinControls.yieldForAX(until: deadline)
                continue
            }
            if let index = updated.nodes.indices.first(where: { CFEqual(updated.nodes[$0].element, element) }),
               let found = kind(for: texts(index, in: updated)), expected == nil || found == expected {
                return (updated, index, found)
            }
            DouyinControls.yieldForAX(until: deadline)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return nil
    }

    private static let giftLabels = ["blockEffects": "屏蔽礼物特效", "sound": "礼物声音", "hotkey": "快捷键送礼"]

    private static func giftOptions(in snapshot: Snapshot, panel: Int) throws -> [(id: String, title: String)] {
        let labels = texts(panel, in: snapshot)
        return ["blockEffects", "sound", "hotkey"].compactMap { id in
            guard let label = giftLabels[id], labels.contains(label),
                  let state = DouyinDanmakuOptions.switchState(label: label, in: snapshot, panel: panel) else { return nil }
            return (id, label + " · " + (state ? "开启" : "关闭"))
        }
    }

    private static func toolbarTitle(_ root: Int, in snapshot: Snapshot, kind: Kind) throws -> String {
        let labels = texts(root, in: snapshot).joined()
        guard kind == .rotation || Self.kind(for: [labels]) == kind else { throw Failure("抖音设置控件的含义已改变") }
        return labels
    }

    private static func enabledState(_ title: String, kind: Kind) -> Bool? {
        guard [.effects, .windowFullscreen, .miniWindow].contains(kind) else { return nil }
        if kind == .windowFullscreen, title.contains("窗口全屏") { return title.contains("退出") }
        if kind == .miniWindow, title.contains("返回大窗播放") { return true }
        if ["退出", "关闭", "隐藏"].contains(where: { title.contains($0) }) { return true }
        if ["进入", "开启", "显示"].contains(where: { title.contains($0) }) { return false }
        return nil
    }

    private static func validateBoundRoom(_ group: Group, in snapshot: Snapshot) throws {
        try checkCancellation()
        try DouyinControls.validate(snapshot)
        guard snapshot.pid == group.pid, try roomKey(snapshot) == group.room else {
            throw Failure("直播间已改变，请重新打开播放器设置")
        }
    }

    private static func pressToolbar(_ root: Int, in snapshot: Snapshot) throws {
        try checkCancellation()
        // Chromium exposes AXPress on some outer hover wrappers as well as the
        // actual inner icon button. Only the icon's nearest actionable ancestor
        // dispatches the client's click handler in the live 7.8 toolbar.
        let anchor = toolbarHoverAnchor(root, in: snapshot)
        var candidate: Int? = anchor
        while let index = candidate {
            if DouyinControls.hasPress(snapshot.nodes[index].element) {
                try DouyinControls.press(index, in: snapshot)
                return
            }
            if index == root { break }
            candidate = snapshot.nodes[index].parent
        }
        throw Failure("抖音播放器图标没有可确认的按下操作")
    }

    private static func executeToolbar(_ option: Option, kind: Kind, group: Group) throws {
        try withToolbar(kind, room: group.room, pid: group.pid) { snapshot, _, root in
            let title = try toolbarTitle(root, in: snapshot, kind: kind)
            if let enabled = enabledState(title, kind: kind) {
                guard ["on", "off"].contains(option.id) else { throw Failure("无效的抖音设置选项") }
                if enabled == (option.id == "on") { return }
            } else {
                guard option.id == "perform" else { throw Failure("无效的抖音设置选项") }
            }
            try validateBoundRoom(group, in: snapshot)
            if kind == .miniWindow, option.id == "on" {
                guard let expected = group.mediaURL, streamURL(in: snapshot) == expected else {
                    throw Failure("播放器已重新加载，请重新打开小窗设置")
                }
            }
            // The exact hovered semantic control must provide AXPress. Never
            // synthesize a blind click in a toolbar whose layout could have changed.
            if kind == .rotation { try DouyinControls.pressControl(root, in: snapshot) }
            else { try pressToolbar(root, in: snapshot) }
            if kind == .miniWindow, option.id == "on" {
                let deadline = ProcessInfo.processInfo.systemUptime + 2
                repeat {
                    try checkCancellation()
                    if let mini = try? DouyinControls.snapshot(), miniWindow(mini) {
                        try validateMiniWindow(mini, group: group)
                        return
                    }
                    DouyinControls.yieldForAX(until: deadline)
                } while ProcessInfo.processInfo.systemUptime < deadline
                throw Failure("抖音尚未确认进入小窗播放")
            }
            if enabledState(title, kind: kind) != nil {
                let deadline = ProcessInfo.processInfo.systemUptime + 2
                repeat {
                    try checkCancellation()
                    if let next = try? current(room: group.room, pid: group.pid),
                       let state = try? withToolbar(kind, room: group.room, pid: next.pid, { s, _, r in
                           enabledState(try toolbarTitle(r, in: s, kind: kind), kind: kind)
                       }), state == (option.id == "on") { return }
                    DouyinControls.yieldForAX(until: deadline)
                } while ProcessInfo.processInfo.systemUptime < deadline
                throw Failure("已按下抖音控件，但尚未确认设置状态，请在客户端检查")
            }
        }
    }
}
