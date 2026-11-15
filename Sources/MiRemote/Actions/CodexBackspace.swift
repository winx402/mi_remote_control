import AppKit
import ApplicationServices
import CoreGraphics

/// Capture a physical press before its release or main-queue dispatch can change focus.
protocol CodexBackspacePreparing: AnyObject {
    func prepareCodexBackspace() -> CodexBackspace.Press?
}

/// Return is an editing key only while Codex actually owns a focused editor.
/// Never focuses a remembered input, reads its value, or changes its selection.
enum CodexBackspace {
    struct Press {
        let editorFocused: Bool
        let perform: () -> Void
        let clear: () -> Void

        init(editorFocused: Bool, perform: @escaping () -> Void, clear: @escaping () -> Void = {}) {
            self.editorFocused = editorFocused
            self.perform = perform
            self.clear = clear
        }
    }

    struct Request: @unchecked Sendable {
        let pid: pid_t
        let editor: AXUIElement?
        let code: CGKeyCode
    }

    private struct Target {
        let pid: pid_t
        let editor: AXUIElement?
    }

    private static func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &result) == .success else { return nil }
        return result
    }

    private static func editable(role: String?, enabled: Bool?, editable: Bool?) -> Bool {
        ["AXTextArea", "AXTextField", "AXComboBox"].contains(role ?? "")
            && enabled != false && editable != false
    }

    private static func target() -> Target? {
        guard AXIsProcessTrusted(), let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == "com.openai.codex" else { return nil }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.025)
        guard let raw = attribute(app, kAXFocusedUIElementAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return Target(pid: front.processIdentifier, editor: nil)
        }
        let focused = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, 0.025)
        let isEditor = editable(role: attribute(focused, kAXRoleAttribute) as? String,
                                enabled: attribute(focused, kAXEnabledAttribute) as? Bool,
                                editable: attribute(focused, "AXEditable") as? Bool)
        return Target(pid: front.processIdentifier, editor: isEditor ? focused : nil)
    }

    private static func keyCode(editorFocused: Bool, allowsEscape: Bool) -> CGKeyCode? {
        editorFocused ? 51 : (allowsEscape ? 53 : nil)
    }

    static func capture(allowsEscape: Bool) -> Request? {
        guard let original = target(),
              let code = keyCode(editorFocused: original.editor != nil, allowsEscape: allowsEscape) else { return nil }
        return Request(pid: original.pid, editor: original.editor, code: code)
    }

    private static func matches(_ request: Request, _ live: Target) -> Bool {
        guard live.pid == request.pid else { return false }
        switch (request.editor, live.editor) {
        case let (editor?, focused?): return CFEqual(editor, focused)
        case (nil, nil): return true
        default: return false
        }
    }

    @MainActor static func perform(_ request: Request, isCurrent: () -> Bool) {
        guard isCurrent(), let live = target(), matches(request, live), isCurrent() else { return }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: request.code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: request.code, keyDown: false) else { return }
        // One native unmodified backspace also deletes an existing selection.
        down.flags = []; up.flags = []
        down.postToPid(request.pid); up.postToPid(request.pid)
    }

    /// Confirm a complete selection before deleting; posting Command-A followed
    /// immediately by Delete races Chromium's asynchronous keyboard handling.
    @MainActor static func clear(_ request: Request, isCurrent: @escaping () -> Bool) {
        guard let editor = request.editor else { return }
        @MainActor func current() -> Bool {
            guard isCurrent(), let live = target(), matches(request, live) else { return false }
            return isCurrent()
        }
        @MainActor func count() -> Int? {
            (attribute(editor, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue
        }
        @MainActor func allSelected(_ length: Int) -> Bool {
            var selection = CFRange()
            guard let value = attribute(editor, kAXSelectedTextRangeAttribute),
                  CFGetTypeID(value) == AXValueGetTypeID(),
                  AXValueGetValue(value as! AXValue, .cfRange, &selection) else { return false }
            return selectionCoversDraft(selection, length: length)
        }
        @MainActor func post(_ code: CGKeyCode, flags: CGEventFlags) {
            guard current(),
                  let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return }
            down.flags = flags; up.flags = flags
            down.postToPid(request.pid); up.postToPid(request.pid)
        }
        Task { @MainActor in
            // Only metadata is read. Draft text and remembered editors are never
            // queried, and missing selection/count metadata leaves the draft intact.
            guard current(), let length = count(), length > 0, current() else { return }
            var all = CFRange(location: 0, length: length)
            if let range = AXValueCreate(.cfRange, &all), current() {
                _ = AXUIElementSetAttributeValue(editor, kAXSelectedTextRangeAttribute as CFString, range)
            }
            if !allSelected(length), current() {
                post(0, flags: .maskCommand)
                for _ in 0..<5 {
                    try? await Task.sleep(for: .milliseconds(30))
                    guard current() else { return }
                    if allSelected(length) { break }
                }
            }
            guard current(), allSelected(length), count() == length, current() else { return }
            post(51, flags: [])
        }
    }

    private static func selectionCoversDraft(_ selection: CFRange, length: Int) -> Bool {
        length > 0 && selection.location == 0 && selection.length == length
    }

    static func selfCheck() -> Bool {
        // Synthetic AX identities exercise the same comparison used after dispatch,
        // without querying permissions, changing focus, or posting real key events.
        let first = AXUIElementCreateApplication(101)
        let second = AXUIElementCreateApplication(102)
        let edit = Request(pid: 100, editor: first, code: 51)
        let escape = Request(pid: 100, editor: nil, code: 53)
        return selectionCoversDraft(CFRange(location: 0, length: 12), length: 12)
            && !selectionCoversDraft(CFRange(location: 1, length: 11), length: 12)
            && !selectionCoversDraft(CFRange(location: 0, length: 11), length: 12)
            && !selectionCoversDraft(CFRange(location: 0, length: 0), length: 0)
            && matches(edit, Target(pid: 100, editor: first))
            && matches(edit, Target(pid: 100, editor: AXUIElementCreateApplication(101)))
            && !matches(edit, Target(pid: 100, editor: second))
            && !matches(edit, Target(pid: 100, editor: nil))
            && !matches(edit, Target(pid: 200, editor: first))
            && matches(escape, Target(pid: 100, editor: nil))
            && !matches(escape, Target(pid: 100, editor: first))
            && editable(role: "AXTextArea", enabled: true, editable: true)
            && editable(role: "AXTextField", enabled: nil, editable: nil)
            && !editable(role: "AXTextArea", enabled: false, editable: true)
            && !editable(role: "AXTextArea", enabled: true, editable: false)
            && !editable(role: "AXButton", enabled: true, editable: true)
            && keyCode(editorFocused: true, allowsEscape: false) == 51
            && keyCode(editorFocused: true, allowsEscape: true) == 51
            && keyCode(editorFocused: false, allowsEscape: true) == 53
            && keyCode(editorFocused: false, allowsEscape: false) == nil
    }
}
