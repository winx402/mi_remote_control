import AppKit
import SwiftUI

/// Offscreen layout proof; no windows, keyboard events, BLE, or HID mapping.
@MainActor
enum SystemMenuPreview {
    static func render(to url: URL) throws {
        try PowerMenuPreview.render(to: url)
    }
}
