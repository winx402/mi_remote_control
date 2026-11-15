import AppKit
import ApplicationServices

/// Live chat is a separate target scope over the existing guarded voice engine.
/// Only the live page's semantic editable controls are eligible; no Return/send.
@MainActor
enum DouyinLiveDictation {
    static let bundleID = "com.bytedance.douyin.desktop"
    static var isActive: Bool { CodexDictation.isActive && CodexDictation.activeBundleID == bundleID }

    private static var accessibilityPID: pid_t?
    private static var cachedField: (element: AXUIElement, window: AXUIElement, room: String)?

    static func canHandleVoice() -> Bool {
        prepareAccessibility()
        return contextID() != nil
    }

    private static func prepareAccessibility() {
        guard AXIsProcessTrusted(), let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == bundleID, accessibilityPID != front.processIdentifier else { return }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        // The initial Chromium AX handshake can exceed the normal 40 ms reads.
        // Warm only this process once, bounded; never activate another app.
        AXUIElementSetMessagingTimeout(app, 0.25)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var window: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success {
            accessibilityPID = front.processIdentifier
        }
    }
    static func configure(triggerConfig: VoiceTriggerConfig) { CodexDictation.configureDouyin(triggerConfig: triggerConfig) }
    static func beginPhysicalHold() { CodexDictation.beginPhysicalHold(scope: .douyinLive) }
    static func endPhysicalHold() { if isActive { CodexDictation.endPhysicalHold() } }
    static func cancel(reason: String = "直播输入上下文改变") {
        if isActive { CodexDictation.cancelCurrent(reason: reason) }
    }

    static func contextID() -> String? {
        guard let current = try? DouyinControls.context(),
              let page = DouyinControls.primaryPage(current.window) else { return nil }
        return DouyinControls.liveRoomID(page.url)
    }

    static func targetMatches(_ element: AXUIElement, window: AXUIElement, contextID expected: String?) -> Bool {
        targetObservation(element, window: window, contextID: expected) == .matched
    }

    static func targetObservation(_ element: AXUIElement, window: AXUIElement,
                                  contextID expected: String?) -> RemoteDictationContextGuard.Observation {
        guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == bundleID else {
            return .changed("frontmost-application")
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return .unavailable("live-input-process") }
        guard pid == front.processIdentifier else { return .changed("live-input-process") }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.04)
        guard let currentWindow = DouyinControls.attribute(app, kAXFocusedWindowAttribute),
              CFGetTypeID(currentWindow) == AXUIElementGetTypeID() else { return .unavailable("live-focused-window") }
        guard CFEqual(currentWindow, window) else { return .changed("live-focused-window") }
        guard let page = DouyinControls.primaryPage(window) else { return .unavailable("live-page") }
        guard let expected else { return .unavailable("live-original-room") }
        guard DouyinControls.liveRoomID(page.url) == expected else { return .changed("live-room") }
        guard let role = DouyinControls.attribute(element, kAXRoleAttribute) as? String else { return .unavailable("live-input-role") }
        guard [kAXTextAreaRole, kAXTextFieldRole].contains(role),
              DouyinControls.attribute(element, kAXEnabledAttribute) as? Bool != false else { return .changed("live-input-editability") }
        guard DouyinControls.attribute(element, kAXPositionAttribute) != nil,
              DouyinControls.attribute(element, kAXSizeAttribute) != nil else { return .unavailable("live-input-frame") }
        let rect = DouyinControls.frame(element)
        let bounds = DouyinControls.frame(window)
        guard !bounds.isEmpty else { return .unavailable("live-window-frame") }
        return rect.width >= 8 && rect.height >= 8 && bounds.contains(CGPoint(x: rect.midX, y: rect.midY))
            ? .matched : .changed("live-input-visibility")
    }

    static func resolvedDictationField() -> AXUIElement? {
        prepareAccessibility()
        if let cachedField, targetMatches(cachedField.element, window: cachedField.window, contextID: cachedField.room) {
            return cachedField.element
        }
        guard let snapshot = try? DouyinControls.snapshot(),
              let page = DouyinControls.primaryPage(snapshot.window), DouyinControls.liveRoomID(page.url) != nil else { return nil }
        // 7.8 exposes both the player input (说点什么) and right chat
        // (与大家互动一下...). Prefer the visible chat input; fullscreen layouts
        // may expose only the player input. Never pick an arbitrary text field.
        let candidates = snapshot.nodes.indices.filter { index in
            let node = snapshot.nodes[index]
            guard [kAXTextAreaRole, kAXTextFieldRole].contains(node.role),
                  DouyinControls.visible(node.rect, in: snapshot),
                  DouyinControls.attribute(node.element, kAXEnabledAttribute) as? Bool != false else { return false }
            return inputKind(node.element) != nil
        }
        let chat = candidates.filter { inputKind(snapshot.nodes[$0].element) == .chat }
        let chosen = chat.isEmpty ? candidates : chat
        guard chosen.count == 1, let index = chosen.first else { return nil }
        let element = snapshot.nodes[index].element
        guard let room = DouyinControls.liveRoomID(page.url) else { return nil }
        cachedField = (element, snapshot.window, room)
        return element
    }

    static func focusForDictation() -> Bool {
        do {
            return try DouyinControls.withOperation {
                guard let current = try? DouyinControls.context(), let target = resolvedDictationField(),
                      DouyinControls.belongs(target, to: current.window) else { return false }
                guard AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else { return false }
                let deadline = ProcessInfo.processInfo.systemUptime + 0.4
                repeat {
                    guard let fresh = try? DouyinControls.context(), CFEqual(fresh.window, current.window) else { return false }
                    if let focused = DouyinControls.attribute(fresh.app, kAXFocusedUIElementAttribute),
                       CFGetTypeID(focused) == AXUIElementGetTypeID(), CFEqual(focused, target) { return true }
                    DouyinControls.yieldForAX(until: deadline)
                } while ProcessInfo.processInfo.systemUptime < deadline
                return false
            }
        } catch { return false }
    }

    private enum InputKind { case chat, player }
    private static func inputKind(_ element: AXUIElement) -> InputKind? {
        // Placeholder metadata is stable when text is entered. Do not read chat
        // histories or infer the editor from the user's current draft value.
        let classes = Set(DouyinControls.attribute(element, "AXDOMClassList") as? [String] ?? [])
        if classes.contains("editor-kit-container") {
            var current = element
            for _ in 0..<5 {
                let parentClasses = Set(DouyinControls.attribute(current, "AXDOMClassList") as? [String] ?? [])
                if parentClasses.contains("webcast-chatroom___input-container") { return .chat }
                guard let raw = DouyinControls.attribute(current, kAXParentAttribute),
                      CFGetTypeID(raw) == AXUIElementGetTypeID() else { break }
                current = raw as! AXUIElement
            }
        }
        let labels = [kAXPlaceholderValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].compactMap {
            DouyinControls.attribute(element, $0) as? String
        }
        if labels.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("与大家互动一下") }) { return .chat }
        if labels.contains("说点什么") { return .player }
        return nil
    }
}
