import Foundation
import CoreGraphics

enum AppNavigationMode: String, Codable, CaseIterable, Sendable {
    case native, buttons, regions
}

enum AppNavigationLayout: String, Codable, CaseIterable, Sendable {
    case automatic, chat, video
}

struct AppNavigationProfile: Codable, Equatable, Sendable {
    var mode: AppNavigationMode = .native
    var layout: AppNavigationLayout = .automatic

    init(mode: AppNavigationMode = .native, layout: AppNavigationLayout = .automatic) {
        self.mode = mode; self.layout = layout
    }

    private enum CodingKeys: String, CodingKey { case mode, layout }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(AppNavigationMode.self, forKey: .mode) ?? .native
        layout = try values.decodeIfPresent(AppNavigationLayout.self, forKey: .layout) ?? .automatic
    }
}

struct AppNavigationNode: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case button, input, scrollArea }
    let id: Int
    let label: String
    let role: String
    let frame: CGRect
    let kind: Kind
    var focused: Bool = false
}

struct AppNavigationRegion: Identifiable, Equatable, Sendable {
    enum Vertical: Sendable { case buttons, scroll, native }
    let id: String
    let title: String
    let frame: CGRect
    let nodeIDs: [Int]
    let vertical: Vertical
    var scrollNodeID: Int? = nil
}
