import AppKit
import ApplicationServices
import CoreGraphics
import os

/// Ordinary conversation scrolling has no dependency on the transcript's size or
/// the question-card parser. Only the hit element's ancestors are inspected.
enum CodexConversationScroll {
    private static let trace = Logger(subsystem: "com.miremote.controller", category: "CodexScroll")
    @MainActor private static var accessibilityPID: pid_t?

    private struct Part {
        var role: String
        var label = ""
        var rect = CGRect.zero
    }

    @MainActor static func scroll(up: Bool, isCurrent: () -> Bool) {
        guard isCurrent(), let application = NSWorkspace.shared.frontmostApplication,
              application.bundleIdentifier == "com.openai.codex", AXIsProcessTrusted() else { return }
        let pid = application.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.015)
        if accessibilityPID != pid {
            guard isCurrent() else { return }
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            accessibilityPID = pid
        }
        guard isCurrent(), let window = element(app, kAXFocusedWindowAttribute as CFString),
              let bounds = frame(window), bounds.width >= 350, bounds.height >= 250,
              bool(window, "AXModal" as CFString) != true,
              (attribute(window, "AXSheets" as CFString) as? [AXUIElement] ?? []).isEmpty else { return }

        // AX and CGEvent share global top-left screen coordinates, including
        // negative origins on displays above/to the left of the main display.
        let system = AXUIElementCreateSystemWide()
        let deadline = ProcessInfo.processInfo.systemUptime + 0.18
        for point in samplePoints(in: bounds) {
            guard isCurrent(), ProcessInfo.processInfo.systemUptime < deadline,
                  sameWindow(app, window: window, pid: pid) else { return }
            guard let path = hitPath(at: point, system: system, window: window, pid: pid,
                                     deadline: deadline, isCurrent: isCurrent),
                  safeContent(path, point: point, window: bounds) else { continue }
            guard let original = CGEvent(source: nil)?.location,
                  let events = wheelEvents(at: point, restoring: original, up: up),
                  isCurrent(), sameWindow(app, window: window, pid: pid) else { return }
            // Process-queue injection bypasses WindowServer's normal window/hit
            // routing. Deliver an ordered pointer/wheel/restore sequence through
            // the same HID route used by MouseMode. Restoring with a queued event
            // avoids warping back before the asynchronous wheel is dispatched.
            // No mouse button or keyboard event is generated; composer focus stays.
            for event in events { event.post(tap: .cghidEventTap) }
            trace.notice("result=wheel_posted")
            return
        }
        trace.notice("result=no_content_hit")
    }

    private static func samplePoints(in window: CGRect) -> [CGPoint] {
        [(0.66, 0.40), (0.55, 0.32), (0.72, 0.55), (0.48, 0.48), (0.60, 0.65)].map {
            CGPoint(x: window.minX + window.width * $0.0, y: window.minY + window.height * $0.1)
        }
    }

    /// The nearest scrolling surface must be a substantial main-content pane.
    /// Anonymous WebAreas get a bounded central hit fallback when the leaf and
    /// ancestor roles are safe. Generic "history" never vetoes a conversation.
    private static func safeContent(_ path: [Part], point: CGPoint, window: CGRect) -> Bool {
        guard path.last?.role == "AXWindow", window.contains(point) else { return false }
        if path.first?.role == "AXButton" { return false }
        let inputRoles: Set<String> = ["AXTextArea", "AXTextField", "AXSearchField", "AXComboBox", "AXTextView"]
        let blockingRoles: Set<String> = ["AXDialog", "AXSheet", "AXMenu", "AXMenuItem", "AXToolbar", "AXOutline",
                                           "AXRadioGroup", "AXRadioButton", "AXCheckBox", "AXListBox"]
        var semanticViewport: CGRect?
        var nearestScroll: CGRect?
        var hasWebArea = false
        for part in path.dropLast() {
            if inputRoles.contains(part.role) || blockingRoles.contains(part.role) { return false }
            let label = part.label.lowercased()
            if ["sidebar", "side bar", "navigation", "composer", "prompt-input", "message-input",
                "terminal", "code editor", "diff-view", "diff view", "search-results", "search results",
                "request-user-input", "request_user_input", "requestuserinput", "question-form", "question-card",
                "ask-user-question", "askuserquestion", "user-input-form",
                "侧栏", "侧边栏", "側邊欄", "导航", "導覽", "输入框", "輸入框", "终端", "終端", "差异视图"]
                .contains(where: label.contains) { return false }
            // An unqualified history pane is the chat selector; the conversation
            // history label is the transcript and must remain scrollable.
            let chat = ["conversation", "transcript", "messages", "chat-content", "chat content",
                        "thread-content", "thread content", "对话内容", "会话内容", "對話內容", "訊息"]
                .contains(where: label.contains)
            if !chat && ["history", "历史", "歷史"].contains(where: label.contains) { return false }
            if chat && part.rect.contains(point) { semanticViewport = part.rect }
            if part.role == "AXScrollArea", nearestScroll == nil { nearestScroll = part.rect }
            if part.role == "AXWebArea" { hasWebArea = true }
        }
        // Do not send wheel events into embedded code/editor scroll areas, even
        // when a safe conversation ancestor exists outside that inner scroller.
        if let nearestScroll { return suitableViewport(nearestScroll, point: point, window: window) }
        guard hasWebArea else { return false }
        if let semanticViewport { return suitableViewport(semanticViewport, point: point, window: window) }
        // Some Chromium versions expose only an anonymous WebArea and text/group
        // ancestors. Requiring a labelled scroller makes every press a no-op in
        // that case. A fresh system-wide hit owned by this exact focused window
        // in the upper/middle main column is sufficient after the exclusions.
        let safeLeaves: Set<String> = ["AXStaticText", "AXHeading", "AXLink", "AXGroup", "AXParagraph", "AXLayoutArea"]
        let central = CGRect(x: window.minX + window.width * 0.48, y: window.minY + window.height * 0.24,
                             width: window.width * 0.30, height: window.height * 0.44)
        return path.first.map { safeLeaves.contains($0.role) } == true && central.contains(point)
    }

    private static func suitableViewport(_ bounds: CGRect, point: CGPoint, window: CGRect) -> Bool {
        let visible = bounds.intersection(window)
        return !visible.isNull && visible.contains(point)
            && visible.width >= window.width * 0.30 && visible.height >= window.height * 0.24
            && visible.midX >= window.minX + window.width * 0.43
            && point.y >= visible.minY + 12 && point.y <= visible.maxY - 12
    }

    @MainActor private static func hitPath(at point: CGPoint, system: AXUIElement, window: AXUIElement,
                                           pid: pid_t, deadline: TimeInterval,
                                           isCurrent: () -> Bool) -> [Part]? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              var current = hit else { return nil }
        var owner: pid_t = 0
        guard AXUIElementGetPid(current, &owner) == .success, owner == pid else { return nil }
        var path: [Part] = []
        var seen = Set<AXUIElement>()
        for _ in 0..<72 {
            guard isCurrent(), ProcessInfo.processInfo.systemUptime < deadline,
                  seen.insert(current).inserted else { return nil }
            if CFEqual(current, window) { return path + [Part(role: "AXWindow")] }
            let values = attributes(current, [kAXRoleAttribute as CFString, kAXParentAttribute as CFString,
                kAXPositionAttribute as CFString, kAXSizeAttribute as CFString])
            let role = values[0] as? String ?? ""
            // Titles/descriptions of text/links/buttons may contain message prose.
            // Only container identifiers and structural container labels are used;
            // AXValue, children and message text are never requested.
            let structural = ["AXGroup", "AXScrollArea", "AXWebArea", "AXList", "AXOutline", "AXSplitGroup"].contains(role)
            let label = structural ? attributes(current, [kAXIdentifierAttribute as CFString,
                kAXTitleAttribute as CFString, kAXDescriptionAttribute as CFString])
                .compactMap { $0 as? String }.joined(separator: "\n") : ""
            path.append(Part(role: role, label: label, rect: frame(position: values[2], size: values[3]) ?? .zero))
            guard let parent = values[1], CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            current = parent as! AXUIElement
        }
        return nil
    }

    /// Creation only. The offline self-check never calls post or any AX API.
    private static func wheelEvents(at point: CGPoint, restoring original: CGPoint, up: Bool) -> [CGEvent]? {
        guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                 mouseCursorPosition: point, mouseButton: .left),
              let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: up ? 100 : -100, wheel2: 0, wheel3: 0),
              let restore = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                    mouseCursorPosition: original, mouseButton: .left) else { return nil }
        wheel.location = point
        for event in [move, wheel, restore] { event.flags = [] }
        return [move, wheel, restore]
    }

    @MainActor private static func sameWindow(_ app: AXUIElement, window: AXUIElement, pid: pid_t) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let current = element(app, kAXFocusedWindowAttribute as CFString) else { return false }
        return CFEqual(current, window)
    }

    private static func attributes(_ node: AXUIElement, _ names: [CFString]) -> [CFTypeRef?] {
        var result: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(node, names as CFArray, [], &result) == .success,
              let values = result as? [CFTypeRef], values.count == names.count else { return names.map { _ in nil } }
        return values.map { $0 }
    }
    private static func attribute(_ node: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(node, name, &result) == .success ? result : nil
    }
    private static func bool(_ node: AXUIElement, _ name: CFString) -> Bool? { attribute(node, name) as? Bool }
    private static func element(_ node: AXUIElement, _ name: CFString) -> AXUIElement? {
        guard let result = attribute(node, name), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }
    private static func frame(_ node: AXUIElement) -> CGRect? {
        let values = attributes(node, [kAXPositionAttribute as CFString, kAXSizeAttribute as CFString])
        return frame(position: values[0], size: values[1])
    }
    private static func frame(position: CFTypeRef?, size: CFTypeRef?) -> CGRect? {
        guard let position, let size, CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    static func selfCheck() -> Bool {
        let window = CGRect(x: -1440, y: -300, width: 1200, height: 900)
        let content = CGRect(x: -1140, y: -230, width: 880, height: 670)
        let point = CGPoint(x: content.midX, y: content.midY)
        let transcript = [Part(role: "AXStaticText"), Part(role: "AXScrollArea", label: "conversation history", rect: content),
                          Part(role: "AXWebArea", rect: window), Part(role: "AXWindow")]
        guard safeContent(transcript, point: point, window: window) else { return false }
        var path = transcript
        path[1].label = "" // Anonymous Chromium scroll viewport is also valid.
        guard safeContent(path, point: point, window: window) else { return false }
        for label in ["sidebar history", "composer", "terminal", "search results", "diff view", "history", "request-user-input", "question-card"] {
            path[1].label = label
            guard !safeContent(path, point: point, window: window) else { return false }
        }
        for role in ["AXTextArea", "AXTextField", "AXSearchField", "AXDialog", "AXSheet", "AXMenu", "AXOutline", "AXButton", "AXRadioGroup"] {
            path = transcript; path[0].role = role
            guard !safeContent(path, point: point, window: window) else { return false }
        }
        path = transcript
        path.insert(Part(role: "AXScrollArea", rect: CGRect(x: point.x - 50, y: point.y - 50, width: 100, height: 100)), at: 1)
        guard !safeContent(path, point: point, window: window) else { return false }
        let anonymous = [Part(role: "AXStaticText"), Part(role: "AXGroup"), Part(role: "AXWebArea", rect: window), Part(role: "AXWindow")]
        guard safeContent(anonymous, point: point, window: window),
              !safeContent(anonymous, point: CGPoint(x: window.minX + 100, y: point.y), window: window),
              !safeContent(anonymous, point: CGPoint(x: point.x, y: window.maxY - 60), window: window),
              !safeContent([Part(role: "AXWebArea", rect: window), Part(role: "AXWindow")], point: point, window: window),
              !safeContent(Array(transcript.dropLast()), point: point, window: window),
              samplePoints(in: window).allSatisfy(window.contains) else { return false }
        let original = CGPoint(x: -1500, y: 200)
        for up in [true, false] {
            guard let events = wheelEvents(at: point, restoring: original, up: up), events.count == 3,
                  events[0].type == .mouseMoved, events[0].location == point,
                  events[1].type == .scrollWheel, events[1].location == point,
                  events[1].getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == (up ? 100 : -100),
                  events[2].type == .mouseMoved, events[2].location == original,
                  events.allSatisfy({ $0.flags.isEmpty }) else { return false }
        }
        return true
    }
}
