import AppKit
import ApplicationServices

/// Click a point on a freshly resolved Douyin control. Verify the actual hit
/// after moving the cursor, then restore it to the toolbar so its popup stays open.
extension DouyinControls {
    static func click(at point: CGPoint, inside target: AXUIElement, in snapshot: Snapshot) throws {
        try validate(snapshot)
        func hit(in scope: AXUIElement) -> AXUIElement? {
            var element: AXUIElement?
            guard AXUIElementCopyElementAtPosition(scope, Float(point.x), Float(point.y), &element) == .success else { return nil }
            return element
        }
        guard let source = CGEventSource(stateID: .privateState),
              let origin = CGEvent(source: nil)?.location,
              let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw Failure("无法调整播放器控件")
        }
        func isOnControl() -> Bool {
            guard frame(target).contains(point), let systemHit = hit(in: AXUIElementCreateSystemWide()),
                  belongs(systemHit, to: snapshot.window) ||
                    attribute(systemHit, kAXWindowAttribute).map({ CFEqual($0, snapshot.window) }) == true else { return false }
            // ChangeDynamicBg covers the player with a pointer-events:none element.
            let decoration = (attribute(systemHit, "AXDOMClassList") as? [String])?.contains("yt8P0_rC") == true
            return decoration || belongs(systemHit, to: target)
                || hit(in: snapshot.window).map({ belongs($0, to: target) }) == true
        }
        guard isOnControl() else { throw Failure("播放器控件的位置已改变，请重新选择") }
        move.post(tap: .cghidEventTap)
        defer {
            if let cursor = CGEvent(source: nil)?.location, hypot(cursor.x - point.x, cursor.y - point.y) < 3 {
                CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: origin, mouseButton: .left)?
                    .post(tap: .cghidEventTap)
            }
        }
        yieldForAX(until: ProcessInfo.processInfo.systemUptime + 0.025)
        try validate(snapshot)
        guard isOnControl() else { throw Failure("播放器控件的位置已改变，请重新选择") }
        for event in [down, up] {
            event.flags = []
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.post(tap: .cghidEventTap)
        }
        yieldForAX(until: ProcessInfo.processInfo.systemUptime + 0.025)
    }
}

@MainActor
enum DouyinPlayerVolume {
    private typealias Controls = DouyinControls
    typealias Snapshot = DouyinControls.Snapshot
    typealias Option = DouyinLiveOptions.Option

    static func isAvailable(in snapshot: Snapshot, player: Int) -> Bool {
        (try? control(in: snapshot, player: player)) != nil
    }

    private static func control(in snapshot: Snapshot, player: Int) throws -> Int {
        try Controls.uniqueControl(["douyin-player-volume"], player: player, in: snapshot, requireVisible: false)
    }

    private struct Slider {
        let element: AXUIElement
        let track: AXUIElement
        let value: Int
    }

    private static func slider(in snapshot: Snapshot) -> Slider? {
        guard let player = try? Controls.player(in: snapshot), let volume = try? control(in: snapshot, player: player),
              let popup = try? Controls.uniqueControl(["douyin-player-volume-slider"], player: volume, in: snapshot),
              let track = try? Controls.uniqueControl(["douyin-player-volume-slider-track"], player: popup, in: snapshot) else { return nil }
        let values = Controls.descendants(of: popup, in: snapshot).compactMap { index -> Int? in
            let node = snapshot.nodes[index]
            guard node.role == kAXStaticTextRole, let text = Controls.attribute(node.element, kAXValueAttribute) as? String,
                  let value = Int(text), (0...100).contains(value) else { return nil }
            return value
        }
        guard values.count == 1 else { return nil }
        return Slider(element: snapshot.nodes[popup].element, track: snapshot.nodes[track].element, value: values[0])
    }

    private static func withSlider<T>(in snapshot: Snapshot, player: Int, _ action: (Slider) throws -> T) throws -> T {
        let volume = try control(in: snapshot, player: player)
        let restore = try Controls.hoverControl(volume, player: player, in: snapshot)
        defer { restore() }
        var active: Slider?
        try Controls.wait("未能读取当前播放器音量", in: snapshot, timeout: 1.5) {
            if let fresh = try? Controls.snapshot() { active = slider(in: fresh) }
            return active != nil
        }
        guard let active else { throw Controls.Failure("音量控件已关闭，请重试") }
        return try action(active)
    }

    static func choices(in snapshot: Snapshot, player: Int) throws -> [Option] {
        try withSlider(in: snapshot, player: player) { slider in
            // Common levels plus the exact current value and its nearest neighbors.
            // Every whole percentage is reachable without a hundred-row menu.
            var values = Set(stride(from: 0, through: 100, by: 10))
            values.formUnion([slider.value, max(0, slider.value - 1), min(100, slider.value + 1)])
            return values.sorted().map {
                Option(id: String($0), title: $0 == 0 ? "静音" : "\($0)%", isSelected: $0 == slider.value)
            }
        }
    }

    static func apply(_ option: Option, in snapshot: Snapshot, player: Int) throws {
        guard let percent = Int(option.id), (0...100).contains(percent) else {
            throw Controls.Failure("请选择有效的播放器音量")
        }
        try withSlider(in: snapshot, player: player) { slider in
            guard percent != slider.value else { return }
            if percent == 0 {
                try Controls.pressControl(try control(in: snapshot, player: player), in: snapshot)
            } else {
                let track = Controls.frame(slider.track)
                guard track.height >= 50, track.width > 0, track.height > track.width else {
                    throw Controls.Failure("没有找到可调节的播放器音量条")
                }
                let y = track.maxY - track.height * CGFloat(percent) / 100
                try Controls.click(at: CGPoint(x: track.midX, y: y), inside: slider.element, in: snapshot)
            }
            try Controls.wait("抖音尚未确认音量已调整", in: snapshot, timeout: 2) {
                guard let fresh = try? Controls.snapshot() else { return false }
                return Self.slider(in: fresh)?.value == percent
            }
        }
    }
}
