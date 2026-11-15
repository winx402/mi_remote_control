import AppKit
import ApplicationServices
import CoreGraphics

/// The live client's labelled settings panel is the authority for available settings.
/// Checked class markers are verified against each shipped switch implementation.
@MainActor
enum DouyinDanmakuOptions {
    private typealias Controls = DouyinControls
    private typealias Snapshot = DouyinControls.Snapshot
    private typealias Failure = DouyinControls.Failure

    private enum Kind: String, CaseIterable {
        case visibility, opacity, area, font, speed, gifts, lottery, reset
        var label: String {
            switch self {
            case .visibility: return "弹幕开关"
            case .opacity: return "不透明度"
            case .area: return "显示区域"
            case .font: return "字体大小"
            case .speed: return "移动速度"
            case .gifts: return "送礼信息"
            case .lottery: return "福袋口令"
            case .reset: return "恢复默认"
            }
        }
        var id: String { rawValue }
        var isSlider: Bool { [.opacity, .area, .font, .speed].contains(self) }
        var symbol: String {
            switch self {
            case .visibility: return "text.bubble"
            case .opacity: return "circle.lefthalf.filled"
            case .area: return "rectangle.topthird.inset.filled"
            case .font: return "textformat.size"
            case .speed: return "speedometer"
            case .gifts: return "gift"
            case .lottery: return "bag"
            case .reset: return "arrow.counterclockwise"
            }
        }
    }
    private struct Setting {
        let kind: Kind
        let index: Int
        let value: String
        let boolean: Bool?
        let rail: CGRect?
        let thumb: CGRect?
        var title: String {
            if kind == .reset { return kind.label }
            let state = kind.isSlider ? value : boolean.map { $0 ? "开启" : "关闭" } ?? "状态未知"
            return "\(kind.label) · \(state)"
        }
    }

    static func descriptors(in snapshot: DouyinControls.Snapshot, panel: Int) throws
        -> [(id: String, title: String, symbol: String)] {
        try settings(in: snapshot, panel: panel).map { ($0.kind.id, $0.title, $0.kind.symbol) }
    }

    static func options(in groupID: String, snapshot: DouyinControls.Snapshot, panel: Int) throws
        -> [DouyinLiveOptions.Option] {
        let setting = try selected(groupID, in: snapshot, panel: panel)
        if setting.kind == .reset {
            return [.init(id: "reset", title: "恢复弹幕默认设置", isSelected: false)]
        }
        if setting.kind.isSlider {
            if setting.kind == .opacity {
                return [
                    .init(id: "decrease", title: "降低 1%（当前：\(setting.value)）", isSelected: false),
                    .init(id: "increase", title: "提高 1%（当前：\(setting.value)）", isSelected: false),
                ] + Set([20, 40, 60, 80, 100, Int(setting.value.dropLast()) ?? 80]).sorted().map {
                    .init(id: "value.\($0)", title: "\($0)%", isSelected: setting.value == "\($0)%")
                }
            }
            return labels(for: setting.kind).enumerated().map {
                .init(id: "value.\($0.offset)", title: $0.element, isSelected: setting.value == $0.element)
            }
        }
        guard let state = setting.boolean else { throw Failure("无法读取\(setting.kind.label)的开关状态") }
        return [
            .init(id: "on", title: "开启", isSelected: state),
            .init(id: "off", title: "关闭", isSelected: !state),
        ]
    }

    static func execute(_ optionID: String, in groupID: String,
                        snapshot: DouyinControls.Snapshot, panel: Int) throws {
        let previous = try selected(groupID, in: snapshot, panel: panel)
        try Controls.validate(snapshot)
        if previous.kind.isSlider {
            let target: Int
            if previous.kind == .opacity, ["decrease", "increase"].contains(optionID),
               let value = Int(previous.value.dropLast()) {
                target = min(100, max(20, value + (optionID == "increase" ? 1 : -1)))
            } else if optionID.hasPrefix("value."), let value = Int(optionID.dropFirst(6)) {
                target = value
            } else { throw Failure("弹幕设置选项已失效") }
            try setSlider(previous, to: target, in: snapshot, panel: panel)
        } else if previous.kind == .reset {
            guard optionID == "reset" else { throw Failure("弹幕设置选项已失效") }
            try Controls.press(previous.index, in: snapshot)
            try awaitChange("抖音未确认已恢复弹幕默认设置", snapshot: snapshot, panel: panel) { updated, updatedPanel in
                let after = try settings(in: updated, panel: updatedPanel)
                let defaults: [Kind: String] = [.opacity: "80%", .area: "50%", .font: "小号", .speed: "适中"]
                return defaults.allSatisfy { kind, value in after.first { $0.kind == kind }?.value == value }
                    && [.gifts, .lottery].allSatisfy { kind in after.first { $0.kind == kind }?.boolean == true }
            }
        } else {
            guard ["on", "off"].contains(optionID), let old = previous.boolean else {
                throw Failure("无法确认弹幕开关设置")
            }
            let target = optionID == "on"
            if old == target { return }
            try Controls.press(previous.index, in: snapshot)
            try awaitChange("抖音未确认\(previous.kind.label)已切换", snapshot: snapshot, panel: panel) { updated, updatedPanel in
                try selected(groupID, in: updated, panel: updatedPanel).boolean == target
            }
        }
    }

    // Verified against the client's shipped constants modules 218824 / 512418
    // and slider modules 317431 / 936729. Clicks require the actual labelled
    // rail and thumb geometry and verify the resulting displayed value.
    private static func labels(for kind: Kind) -> [String] {
        switch kind {
        case .area: return ["一行", "两行", "25%", "50%", "80%"]
        case .font: return ["超小", "小号", "适中", "大号", "超大"]
        case .speed: return ["较慢", "适中", "较快"]
        default: return []
        }
    }

    static func switchState(label: String, in snapshot: DouyinControls.Snapshot, panel: Int) -> Bool? {
        guard let index = try? switchControl(label: label, in: snapshot, panel: panel) else { return nil }
        return booleanState(snapshot.nodes[index].element)
    }

    static func setSwitch(label: String, enabled: Bool, snapshot: DouyinControls.Snapshot, panel: Int) throws {
        let index = try switchControl(label: label, in: snapshot, panel: panel)
        guard let previous = booleanState(snapshot.nodes[index].element) else { throw Failure("无法读取\(label)开关状态") }
        if previous == enabled { return }
        try Controls.press(index, in: snapshot)
        try awaitChange("抖音未确认\(label)已切换", snapshot: snapshot, panel: panel) { updated, updatedPanel in
            switchState(label: label, in: updated, panel: updatedPanel) == enabled
        }
    }

    private static func switchControl(label: String, in snapshot: Snapshot, panel: Int) throws -> Int {
        guard snapshot.nodes.indices.contains(panel) else { throw Failure("设置面板已关闭") }
        let descendants = Controls.descendants(of: panel, in: snapshot)
        let labels = descendants.filter { snapshot.nodes[$0].role == kAXStaticTextRole && text(snapshot.nodes[$0]) == label }
        guard labels.count == 1, let row = labels.first else { throw Failure("没有找到唯一的\(label)设置") }
        let rect = snapshot.nodes[row].rect
        let matches = descendants.filter {
            let node = snapshot.nodes[$0]
            return node.role == kAXGroupRole && node.rect.minX > rect.maxX
                && (20...50).contains(node.rect.width) && (14...30).contains(node.rect.height)
                && abs(node.rect.midY - rect.midY) <= max(node.rect.height, rect.height) / 2
                && Controls.hasPress(node.element)
        }
        guard matches.count == 1, let index = matches.first else { throw Failure("无法安全识别\(label)开关") }
        return index
    }

    private static func selected(_ id: String, in snapshot: Snapshot, panel: Int) throws -> Setting {
        let available = try settings(in: snapshot, panel: panel)
        let matches = available.filter { $0.kind.id == id }
        guard matches.count == 1, let setting = matches.first else { throw Failure("当前弹幕设置项不可用，请重新打开菜单") }
        if setting.kind.isSlider {
            let valid: Bool
            if setting.kind == .opacity {
                valid = setting.value.hasSuffix("%") && Int(setting.value.dropLast()).map { (20...100).contains($0) } == true
            } else { valid = labels(for: setting.kind).contains(setting.value) }
            guard valid else { throw Failure("当前\(setting.kind.label)档位无法确认，请重新打开菜单") }
        }
        if setting.kind != .visibility, available.first(where: { $0.kind == .visibility })?.boolean == false {
            throw Failure("请先开启弹幕，再调整弹幕设置")
        }
        return setting
    }

    private static func text(_ node: Controls.Node) -> String {
        guard [kAXStaticTextRole, kAXButtonRole].contains(node.role) else { return "" }
        let values = Controls.attributes(node.element, [kAXValueAttribute, kAXTitleAttribute])
        return ((values[0] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? values[1] as? String ?? node.label).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func settings(in snapshot: Snapshot, panel: Int) throws -> [Setting] {
        guard snapshot.nodes.indices.contains(panel), Controls.visible(snapshot.nodes[panel].rect, in: snapshot) else {
            throw Failure("弹幕设置面板已关闭，请重新打开菜单")
        }
        let children = snapshot.nodes.indices.filter { snapshot.nodes[$0].parent == panel }
        var result: [Setting] = []
        for kind in Kind.allCases {
            let labels = Controls.descendants(of: panel, in: snapshot).filter {
                snapshot.nodes[$0].role == kAXStaticTextRole && text(snapshot.nodes[$0]) == kind.label
            }
            guard !labels.isEmpty else { continue }
            guard labels.count == 1, let label = labels.first else { throw Failure("弹幕设置标签重复，无法安全操作") }
            let labelRect = snapshot.nodes[label].rect
            let matches = children.filter { index in
                let node = snapshot.nodes[index]
                if kind == .reset { return node.role == kAXButtonRole && text(node) == kind.label }
                return node.role == kAXGroupRole && node.rect.minX > labelRect.maxX
                    && abs(node.rect.midY - labelRect.midY) <= max(labelRect.height, node.rect.height) / 2
                    && Controls.hasPress(node.element)
            }
            guard matches.count == 1, let control = matches.first else { continue }
            let node = snapshot.nodes[control]
            let descendants = Controls.descendants(of: control, in: snapshot)
            let values = descendants.filter { snapshot.nodes[$0].role == kAXStaticTextRole }.map { text(snapshot.nodes[$0]) }.filter { !$0.isEmpty }
            if kind.isSlider && values.count != 1 { continue }
            // A rail is the widest thin descendant; duplicate track/fill wrappers are
            // intentionally collapsed by geometry instead of generated class names.
            let rails = descendants.map { snapshot.nodes[$0].rect }.filter {
                $0.width >= node.rect.width / 2 && (1...6).contains($0.height)
            }.sorted { $0.width > $1.width }
            let rail = rails.first
            var thumbs: [CGRect] = []
            if let track = rail {
                for child in descendants {
                    let rect = snapshot.nodes[child].rect
                    guard (7.0...24.0).contains(rect.width), abs(rect.width - rect.height) <= 2,
                          abs(rect.midY - track.midY) <= 2,
                          rect.minX >= track.minX - rect.width / 2,
                          rect.maxX <= track.maxX + rect.width / 2 else { continue }
                    thumbs.append(rect)
                }
            }
            let thumb = thumbs.count == 1 ? thumbs.first : nil
            let boolean = kind.isSlider || kind == .reset ? nil : booleanState(node.element)
            result.append(Setting(kind: kind, index: control, value: values.first ?? "",
                                  boolean: boolean, rail: rail, thumb: thumb))
        }
        guard !result.isEmpty else { throw Failure("没有找到可确认的弹幕设置") }
        return result
    }

    private static func booleanState(_ element: AXUIElement) -> Bool? {
        for name in [kAXValueAttribute, "AXChecked"] {
            guard let value = Controls.attribute(element, name) else { continue }
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return (value as! CFBoolean) == kCFBooleanTrue }
            if let number = value as? NSNumber, number == 0 || number == 1 { return number.boolValue }
            if let string = value as? String {
                if ["true", "checked", "on"].contains(string.lowercased()) { return true }
                if ["false", "unchecked", "off"].contains(string.lowercased()) { return false }
            }
        }
        let classes = Set(Controls.attribute(element, "AXDOMClassList") as? [String] ?? [])
        // Preview CSS module 331310 and live CSS module 871516 use different
        // hashes. The live active token was also verified by AXPress -> removal
        // -> AXPress -> exact original class-vector restoration.
        if classes.contains("_h3OuAw5") || classes.contains("RFBp6ss9") {
            return classes.contains("G9q7tTop")
        }
        if classes.contains("dNuSIvAp") || classes.contains("oFlJmF9S") {
            return classes.contains("SpsbqNUm")
        }
        return nil
    }

    private static func awaitChange(_ message: String, snapshot: Snapshot, panel: Int,
                                    condition: (Snapshot, Int) throws -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        repeat {
            try Controls.validate(snapshot)
            let current = try Controls.snapshot()
            guard current.pid == snapshot.pid, CFEqual(current.window, snapshot.window),
                  let currentPanel = current.nodes.indices.first(where: {
                      CFEqual(current.nodes[$0].element, snapshot.nodes[panel].element)
                  }) else {
                throw Failure("弹幕设置界面已改变，请重新打开菜单")
            }
            if try condition(current, currentPanel) { return }
            Controls.yieldForAX(until: deadline)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw Failure(message)
    }

    private static func setSlider(_ previous: Setting, to target: Int, in snapshot: Snapshot, panel: Int) throws {
        let minimum = previous.kind == .opacity ? 20 : 0
        let maximum = previous.kind == .opacity ? 100 : labels(for: previous.kind).count - 1
        guard (minimum...maximum).contains(target), let rail = previous.rail, previous.thumb != nil else {
            throw Failure("无法安全识别\(previous.kind.label)滑轨")
        }
        let expected = previous.kind == .opacity ? "\(target)%" : labels(for: previous.kind)[target]
        if previous.value == expected { return }
        let ratio = CGFloat(target - minimum) / CGFloat(maximum - minimum)
        // Chromium rounds mouse positions to CSS pixels. The right edge belongs
        // to the encompassing slider row; the pixel before it can select 99%.
        let point = CGPoint(x: (rail.minX + ratio * rail.width).rounded(), y: rail.midY)
        try Controls.click(at: point, inside: snapshot.nodes[previous.index].element, in: snapshot)
        try awaitChange("抖音未确认\(previous.kind.label)已设为\(expected)", snapshot: snapshot, panel: panel) { updated, updatedPanel in
            try selected(previous.kind.id, in: updated, panel: updatedPanel).value == expected
        }
    }

}
