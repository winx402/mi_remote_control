import AppKit
import CoreGraphics

enum NavigationFocusOverlayGeometry {
    /// AX/Quartz use the primary display's top-left origin; AppKit uses its bottom-left.
    /// A single global transform also handles displays left of or above the primary display.
    static func appKitRect(_ rect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }

    static func selfCheck() -> Bool {
        let primaryTop: CGFloat = 900
        let rect = CGRect(x: -1200, y: -600, width: 300, height: 180)
        let converted = appKitRect(rect, primaryTop: primaryTop)
        return converted == CGRect(x: -1200, y: 1320, width: 300, height: 180)
            && appKitRect(converted, primaryTop: primaryTop) == rect
    }
}

/// Visual selection only: never becomes key/main, activates an app, or receives mouse events.
@MainActor
final class NavigationFocusOverlay {
    private var panel: NavigationHighlightPanel?
    private var drawing: NavigationHighlightView?

    static var axScreenFrames: [CGRect] {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return NSScreen.screens.map { NavigationFocusOverlayGeometry.appKitRect($0.frame, primaryTop: top) }
    }

    func show(node: AppNavigationNode?, region: AppNavigationRegion?, editing: Bool = false) {
        guard node != nil || region != nil,
              let primary = NSScreen.screens.first else { hide(); return }
        let transform: (CGRect) -> CGRect = {
            NavigationFocusOverlayGeometry.appKitRect($0, primaryTop: primary.frame.maxY)
        }
        let nodeRect = node.map { transform($0.frame) }
        let regionRect = region.map { transform($0.frame) }
        let target = nodeRect ?? regionRect ?? .zero
        guard target.width >= 3, target.height >= 3 else { hide(); return }
        let title: String
        if let node {
            let prefix = region.map { "\($0.title) · " } ?? ""
            title = prefix + node.label + (editing ? " · 编辑中 · 返回退出" : " · OK 确认")
        } else if let region {
            let hint: String
            switch region.vertical {
            case .buttons: hint = "上下选择 · 左右切换区域"
            case .scroll: hint = "上下滚动 · 左右切换区域"
            case .native: hint = "上下使用原生控制 · 左右切换区域"
            }
            title = "\(region.title) · \(hint)"
        } else { title = "" }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let badgeWidth = min(640, max(180, (title as NSString).size(withAttributes: attributes).width + 28))
        let screen = NSScreen.screens.max {
            $0.frame.intersection(target).area < $1.frame.intersection(target).area
        } ?? primary
        let safe = screen.visibleFrame.insetBy(dx: 6, dy: 6)
        let badgeX = min(max(target.minX, safe.minX), max(safe.minX, safe.maxX - badgeWidth))
        let preferredY = target.maxY + 6
        let badgeY = preferredY + 36 <= safe.maxY ? preferredY : max(safe.minY, target.minY - 42)
        let badge = CGRect(x: badgeX, y: badgeY, width: min(badgeWidth, safe.width), height: 36)
        var frame = (regionRect ?? target).union(target).union(badge).insetBy(dx: -8, dy: -8)
        frame = frame.integral
        if panel == nil {
            let panel = NavigationHighlightPanel(contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
            let drawing = NavigationHighlightView(frame: CGRect(origin: .zero, size: frame.size))
            panel.contentView = drawing
            self.panel = panel
            self.drawing = drawing
        }
        guard let panel, let drawing else { return }
        panel.setFrame(frame, display: false)
        drawing.frame = CGRect(origin: .zero, size: frame.size)
        drawing.nodeRect = nodeRect?.offsetBy(dx: -frame.minX, dy: -frame.minY)
        drawing.regionRect = regionRect?.offsetBy(dx: -frame.minX, dy: -frame.minY)
        drawing.badgeRect = badge.offsetBy(dx: -frame.minX, dy: -frame.minY)
        drawing.title = title
        drawing.needsDisplay = true
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    func stop() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        drawing = nil
    }

    nonisolated static func selfCheck() -> Bool { NavigationFocusOverlayGeometry.selfCheck() }
}

@MainActor
private final class NavigationHighlightPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class NavigationHighlightView: NSView {
    var nodeRect: CGRect?
    var regionRect: CGRect?
    var badgeRect = CGRect.zero
    var title = ""

    override func draw(_ dirtyRect: NSRect) {
        if let regionRect {
            let path = NSBezierPath(roundedRect: regionRect.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
            NSColor.systemBlue.withAlphaComponent(0.65).setStroke()
            path.lineWidth = 3
            path.setLineDash([9, 5], count: 2, phase: 0)
            path.stroke()
        }
        if let nodeRect {
            let path = NSBezierPath(roundedRect: nodeRect.insetBy(dx: -2, dy: -2), xRadius: 7, yRadius: 7)
            NSColor.white.withAlphaComponent(0.95).setStroke()
            path.lineWidth = 7
            path.stroke()
            NSColor.systemBlue.setStroke()
            path.lineWidth = 4
            path.stroke()
        }
        NSColor(calibratedRed: 0.04, green: 0.18, blue: 0.44, alpha: 0.96).setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: 9, yRadius: 9).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(in: badgeRect.insetBy(dx: 13, dy: 7), withAttributes: [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ])
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : max(0, width) * max(0, height) }
}
