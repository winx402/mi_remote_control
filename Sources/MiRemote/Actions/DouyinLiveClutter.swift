import AppKit
import ApplicationServices

/// Dismisses individually identified live-room overlays. New targets belong here,
/// with their own identity checks and postconditions rather than a generic click.
@MainActor
enum DouyinLiveClutter {
    private typealias Snapshot = DouyinControls.Snapshot
    private typealias Failure = DouyinControls.Failure
    private static let exhibitionTitle = "点亮展馆帮主播集星"
    private struct ExhibitionTarget { let close: Int; let content: Int }

    static func clear() -> String? {
        do {
            try DouyinControls.withOperation {
                let initial = try DouyinControls.snapshot()
                guard let page = DouyinControls.primaryPage(initial.window),
                      DouyinControls.isLivePage(page) else {
                    throw Failure("请先进入抖音直播间")
                }
                try dismissExhibition(in: initial, page: page)
            }
            return nil
        } catch let error as Failure { return error.message }
        catch { return "清理抖音直播杂项失败：\(error.localizedDescription)" }
    }

    private static func dismissExhibition(in initial: Snapshot, page: DouyinControls.Page) throws {
        guard let original = try exhibitionClose(in: initial, page: page) else {
            try DouyinControls.validate(initial)
            return
        }
        // Re-resolve immediately before acting. Chromium may replace the popup or
        // navigate while AX metadata is being read; an old X must never be pressed.
        let current = try boundSnapshot(initial, page: page)
        guard let confirmed = try exhibitionClose(in: current, page: page) else { return }
        guard CFEqual(initial.nodes[original.close].element, current.nodes[confirmed.close].element) else {
            throw Failure("抖音展馆提示已改变，请重试")
        }
        // The top bar can hide above the player while this tooltip's gift rows
        // remain visible. AXPress still addresses the exact X; never click a point
        // or use the outer popup, whose own press handler can open the gift wall.
        let content = current.nodes[confirmed.content].element
        try DouyinControls.press(confirmed.close, in: current, requireVisible: false)
        let deadline = ProcessInfo.processInfo.systemUptime + 1.2
        repeat {
            let fresh = try boundSnapshot(initial, page: page)
            let oldCardStillVisible = fresh.nodes.contains {
                CFEqual($0.element, content) && DouyinControls.visible($0.rect, in: fresh)
            }
            if try exhibitionClose(in: fresh, page: page) == nil, !oldCardStillVisible { return }
            DouyinControls.yieldForAX(until: deadline)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw Failure("抖音尚未确认已关闭展馆提示，请重试")
    }

    private static func boundSnapshot(_ initial: Snapshot, page: DouyinControls.Page) throws -> Snapshot {
        try DouyinControls.validate(initial)
        let fresh = try DouyinControls.snapshot()
        guard fresh.pid == initial.pid, CFEqual(fresh.window, initial.window),
              let currentPage = DouyinControls.primaryPage(fresh.window),
              DouyinControls.isLivePage(currentPage), currentPage.url == page.url else {
            throw Failure("抖音直播间已改变，请重试")
        }
        try DouyinControls.validate(fresh)
        return fresh
    }

    private static func exhibitionClose(in snapshot: Snapshot, page: DouyinControls.Page) throws -> ExhibitionTarget? {
        // The room header can sit beside the player or move inside it in fullscreen.
        let pages = snapshot.nodes.indices.filter {
            snapshot.nodes[$0].role == "AXWebArea" && snapshot.nodes[$0].url == page.url
        }
        guard pages.count == 1, let root = pages.first else { throw Failure("无法确认当前直播间页面") }
        let tooltips = DouyinControls.descendants(of: root, in: snapshot).filter {
            snapshot.nodes[$0].classes.contains("dylive-tooltip")
        }
        var matches: [ExhibitionTarget] = []
        for tooltip in tooltips {
            let descendants = DouyinControls.descendants(of: tooltip, in: snapshot)
            // Read only small tooltip subtrees, never the room's chat or feed text.
            guard descendants.count <= 80 else { continue }
            let headings = descendants.filter {
                snapshot.nodes[$0].role == kAXStaticTextRole
                    && DouyinControls.attribute(snapshot.nodes[$0].element, kAXValueAttribute) as? String == exhibitionTitle
            }
            guard !headings.isEmpty else { continue }
            guard headings.count == 1, let heading = headings.first,
                  let title = snapshot.nodes[heading].parent,
                  let header = snapshot.nodes[title].parent,
                  let content = snapshot.nodes[header].parent,
                  snapshot.nodes[content].parent == tooltip,
                  snapshot.nodes[title].classes.contains("gQmBIy9q"),
                  snapshot.nodes[header].classes.contains("rgmoj9nR"),
                  snapshot.nodes[content].classes.contains("C98GAVty") else {
                throw Failure("无法安全识别抖音展馆提示的关闭按钮")
            }
            guard DouyinControls.visible(snapshot.nodes[content].rect, in: snapshot) else { continue }
            // Verified against the client's RoomInfoBar markup: close is the X
            // SVG with its own handler; OcF5f9jf gift actions are outside header.
            let actions = DouyinControls.descendants(of: header, in: snapshot).filter {
                DouyinControls.hasPress(snapshot.nodes[$0].element)
            }
            guard actions.count == 1, let close = actions.first,
                  snapshot.nodes[close].parent == header,
                  snapshot.nodes[close].role == kAXImageRole,
                  snapshot.nodes[close].classes.contains("rQqHZQqi") else {
                throw Failure("无法安全识别抖音展馆提示的关闭按钮")
            }
            matches.append(ExhibitionTarget(close: close, content: content))
        }
        guard matches.count <= 1 else { throw Failure("抖音存在多个展馆提示，无法安全关闭") }
        return matches.first
    }
}
