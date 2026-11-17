import AppKit

/// Opens the app's dedicated Your dot destination without selecting a chat or
/// sending a message. The deep link also works while the sidebar is collapsed.
@MainActor
enum CodexDot {
    /// Verified in ChatGPT.app 26.1111.21308 (com.openai.codex), app.asar:
    /// early-bootstrap-631 parses codex://dots as dotsHome;
    /// early-bootstrap-226 navigates dotsHome to /dots;
    /// 757723 redirects /dots to liTb.VS (/dots/home).
    /// The Your dot sidebar entry in 200114 also navigates to liTb.VS.
    /// Success means Launch Services accepted navigation, not that the page
    /// finished loading or that an account has access to the Dot feature.
    static func open() async -> Bool {
        guard !Task.isCancelled,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex"),
              let destination = URL(string: "codex://dots") else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return await withCheckedContinuation { continuation in
            // Target the verified application rather than whichever application
            // currently owns the codex URL scheme in Launch Services.
            NSWorkspace.shared.open([destination], withApplicationAt: appURL,
                                    configuration: configuration) { app, error in
                continuation.resume(returning: app != nil && error == nil)
            }
        }
    }
}
