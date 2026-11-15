import AppKit
import ApplicationServices
import CoreGraphics

/// Return is an editing key only while Codex actually owns a focused editor.
/// Never focuses a remembered input, reads its value, or changes its selection.
enum CodexBackspace {
    private struct Target {
        let pid: pid_t
        let app: AXUIElement
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
            return Target(pid: front.processIdentifier, app: app, editor: nil)
        }
        let focused = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, 0.025)
        let isEditor = editable(role: attribute(focused, kAXRoleAttribute) as? String,
                                enabled: attribute(focused, kAXEnabledAttribute) as? Bool,
                                editable: attribute(focused, "AXEditable") as? Bool)
        return Target(pid: front.processIdentifier, app: app, editor: isEditor ? focused : nil)
    }

    static func hasFocusedEditor() -> Bool { target()?.editor != nil }

    private static func keyCode(editorFocused: Bool, allowsEscape: Bool) -> CGKeyCode? {
        editorFocused ? 51 : (allowsEscape ? 53 : nil)
    }

    @MainActor static func perform(allowsEscape: Bool, isCurrent: () -> Bool) {
        guard isCurrent(), let original = target(),
              let code = keyCode(editorFocused: original.editor != nil, allowsEscape: allowsEscape),
              let live = target(), live.pid == original.pid, isCurrent() else { return }
        if let editor = original.editor {
            guard let focused = live.editor, CFEqual(editor, focused) else { return }
        } else if live.editor != nil { return }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return }
        // One native unmodified backspace also deletes an existing selection.
        down.flags = []; up.flags = []
        down.postToPid(original.pid); up.postToPid(original.pid)
    }

    static func selfCheck() -> Bool {
        editable(role: "AXTextArea", enabled: true, editable: true)
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
