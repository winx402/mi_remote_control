import AppKit
import ApplicationServices
import CoreGraphics
import OSLog

@MainActor
enum CodexSessionSettings {
    enum Field { case model, effort, plugins }

    struct Context {
        fileprivate let pid: pid_t
        fileprivate let window: AXUIElement
        fileprivate let title: String
        fileprivate let web: AXUIElement
        fileprivate let editor: AXUIElement
        fileprivate let picker: AXUIElement
    }

    struct Snapshot {
        let context: Context
        let model: String
        let effort: String
    }

    struct Option: Identifiable, Equatable {
        let id: String
        let label: String
        let isSelected: Bool
        let isEnabled: Bool
    }

    private enum Failure: LocalizedError {
        case access, context, composer, menu, effort, effortControl, effortNotApplied, option, verification

        var errorDescription: String? {
            switch self {
            case .access: "需要辅助功能权限才能操作 Codex。"
            case .context: "当前 Codex 会话已切换，请重新打开会话设置。"
            case .composer: "当前 Codex 输入区没有可操作的模型设置。"
            case .menu: "无法读取当前 Codex 菜单，请关闭菜单后重试。"
            case .effort: "无法确认该模型当前可用的推理强度，请在 Codex 中调整。"
            case .effortControl: "Codex 模型菜单没有显示可用的强度滑块，请在 Codex 输入栏检查。"
            case .effortNotApplied: "Codex 没有确认新的思考强度。请重新打开强度列表再试。"
            case .option: "所选项目已不可用，请重新打开下拉菜单。"
            case .verification: "Codex 未确认所选项目，请核对当前会话。"
            }
        }
    }

    private struct Composer {
        let picker: AXUIElement
        let add: AXUIElement

        func trigger(_ field: Field) -> AXUIElement { field == .plugins ? add : picker }
    }

    private struct Row {
        let option: Option
        let element: AXUIElement
    }

    private struct Power {
        let item: AXUIElement
        let reading: PowerReading?
    }

    private struct PowerReading {
        let effort: Effort
        let index: Int
        let count: Int
    }

    private enum Effort: String, CaseIterable, Sendable {
        case none, minimal, low, medium, high, xhigh, max, ultra, persistent

        var labels: [String] {
            switch self {
            case .none: ["无", "None", "無"]
            case .minimal: ["极低", "Minimal", "極低"]
            case .low: ["轻度", "Low", "低", "輕度", "Light"]
            case .medium: ["中", "Medium", "标准", "標準", "Standard"]
            case .high: ["高", "High"]
            case .xhigh: ["极高", "Extra High", "極高", "Extra high", "Very High"]
            case .max: ["Max", "Maximum", "最高"]
            case .ultra: ["Ultra"]
            case .persistent: ["持续", "Persistent", "持續"]
            }
        }

        func label(matching current: String) -> String {
            current.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) })
                ? labels[0] : labels.first(where: { $0.unicodeScalars.allSatisfy(\.isASCII) }) ?? labels[0]
        }
    }

    private static let addLabels: Set<String> = ["添加文件等内容", "加入檔案等內容", "新增檔案等內容", "Add files and more"]
    private static let modelLabels: Set<String> = ["选择模型", "選擇模型", "選取模型", "Select model"]
    private static let effortLabels: Set<String> = ["选择推理强度", "選取推理強度", "選擇推理強度", "Select effort"]
    private static let powerLabels: Set<String> = ["强度", "強度", "Power"]
    private static let resetModelLabels: Set<String> = ["重置为默认", "重設為預設", "重置為預設", "Reset to default"]
    private static let pluginLabels: Set<String> = ["插件", "外掛程式", "外掛", "Plugins"]
    private static let trace = Logger(subsystem: "com.miremote.controller", category: "CodexEffort")
    private static var busy = false

    static func capture() async throws -> Snapshot {
        guard AXIsProcessTrusted() else { throw Failure.access }
        guard !busy, let running = NSWorkspace.shared.frontmostApplication,
              running.bundleIdentifier == "com.openai.codex" else { throw Failure.context }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.05)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let window = element(app, kAXFocusedWindowAttribute),
              let bounds = frame(window), let title = string(window, kAXTitleAttribute),
              let web = firstDescendant(window, depth: 10, limit: 40, matching: { role($0) == "AXWebArea" }) else {
            throw Failure.composer
        }
        guard let (editor, composer) = findComposer(in: web, bounds: bounds) else { throw Failure.composer }
        let context = Context(pid: running.processIdentifier, window: window, title: title, web: web,
                              editor: editor, picker: composer.picker)
        return try snapshot(context)
    }

    static func options(_ field: Field, context: Context) async throws -> [Option] {
        guard !busy else { throw Failure.menu }
        busy = true
        defer { busy = false }
        let current = try snapshot(context)
        if field == .effort {
            // Model metadata describes available choices. The live slider is only
            // needed when applying one, and may be hidden on the model list page.
            let catalog = await effortCatalog(for: current.model, context: context)
            try Task.checkCancellation()
            let fresh = try snapshot(context)
            guard matchesModel(fresh.model, current.model), let catalog,
                  let selected = catalog.first(where: { $0.labels.contains(fresh.effort) }) else {
                throw Failure.effort
            }
            return catalog.map {
                Option(id: $0.rawValue, label: $0.label(matching: fresh.effort),
                       isSelected: $0 == selected, isEnabled: true)
            }
        }
        return try await withMenu(field, context: context) { trigger in
            let rows = try await rows(field, trigger: trigger, context: context)
            return rows.map(\.option)
        }
    }

    static func apply(_ field: Field, option: Option, context: Context) async throws -> Snapshot {
        guard !busy else { throw Failure.menu }
        busy = true
        defer { busy = false }
        let current = try snapshot(context)
        guard option.isEnabled else { throw Failure.option }
        if field == .effort {
            guard let target = Effort(rawValue: option.id) else { throw Failure.option }
            return try await applyEffort(target, from: current)
        }
        return try await withMenu(field, context: context) { trigger in
            let rows = try await rows(field, trigger: trigger, context: context)
            guard let row = rows.first(where: { $0.option.id == option.id && $0.option.isEnabled }) else {
                throw Failure.option
            }
            if field == .model, row.option.isSelected {
                try await close(trigger, context: context)
                return try snapshot(context)
            }
            if field == .plugins {
                let priorChips = countChips(for: row.option, context: context)
                try await clickPlugin(row, trigger: trigger, context: context)
                try await wait(context) {
                    expanded(trigger) == false && countChips(for: row.option, context: context) > priorChips ? true : nil
                }
                return try snapshot(context)
            }
            try press(row.element, context: context)
            try await close(trigger, context: context)
            return try await wait(context) {
                guard let result = try? snapshot(context), matchesModel(result.model, option.label) else { return nil }
                return result
            }
        }
    }

    private static func withMenu<T>(_ field: Field, context: Context,
                                    operation: @MainActor (AXUIElement) async throws -> T) async throws -> T {
        let composer = try validate(context)
        let trigger = composer.trigger(field)
        guard expanded(trigger) == false else { throw Failure.menu }
        try press(trigger, context: context)
        do {
            try await wait(context, attempts: field == .effort ? 40 : 14, failure: .menu) {
                expanded(trigger) == true ? true : nil
            }
            let value = try await operation(trigger)
            let liveTrigger = (try? validate(context))?.trigger(field) ?? trigger
            try await close(liveTrigger, context: context)
            return value
        } catch {
            // Cleanup only the menu we opened and only while its original chat is focused.
            if expanded(trigger) == true, (try? validate(context)) != nil {
                _ = postKey(53, context: context)
            }
            throw error
        }
    }

    private static func rows(_ field: Field, trigger: AXUIElement, context: Context) async throws -> [Row] {
        if field == .plugins {
            return try await wait(context) {
                guard expanded(trigger) == true else { return nil }
                return pluginRows(context)
            }
        }

        let menu = try await wait(context) { modelMenu(context) }
        if let selector = firstDescendant(menu, depth: 7, limit: 45,
            matching: { role($0) == "AXMenuItem" && modelLabels.contains(label($0)) }) {
            try press(selector, context: context)
        }
        return try await wait(context) {
            guard let menu = modelMenu(context) else { return nil }
            let items = descendants(menu, depth: 8, limit: 140) { role($0) == "AXMenuItem" }
            let rows: [Row] = items.compactMap { item in
                let name = label(item)
                // Model names in the native Codex catalog begin with GPT. Use
                // only concrete model rows, excluding reset, access and service-tier actions.
                guard splitSelection(name) == nil, isModelName(name),
                      !name.localizedCaseInsensitiveContains("locked"),
                      !name.contains("已锁定"), !name.contains("已鎖定") else { return nil }
                let selected = !(string(item, "AXMenuItemMarkChar") ?? "").isEmpty
                return Row(option: Option(id: name, label: name, isSelected: selected,
                                          isEnabled: enabled(item)), element: item)
            }
            return rows.isEmpty ? nil : unique(rows)
        }
    }

    private static func pluginRows(_ context: Context) -> [Row]? {
        for node in portals(context, matching: { role($0) == "AXGroup" }) {
            let section = children(node)
            guard let heading = section.firstIndex(where: { child in
                role(child) == "AXGroup" && children(child).contains {
                    role($0) == "AXStaticText" && pluginLabels.contains(string($0, kAXValueAttribute) ?? "")
                }
            }) else { continue }
            let rows = section.dropFirst(heading + 1).prefix {
                ["AXButton", "AXListItem", "AXOption"].contains(role($0))
            }.compactMap { item -> Row? in
                let title = label(item)
                guard !title.isEmpty else { return nil }
                let name = staticLabels(item, depth: 4).first ?? title
                return Row(option: Option(id: title, label: name, isSelected: false, isEnabled: enabled(item)),
                           element: item)
            }
            return unique(rows)
        }
        return nil
    }

    private static func unique(_ rows: [Row]) -> [Row] {
        let duplicates = Dictionary(grouping: rows, by: \.option.id)
        return rows.filter { duplicates[$0.option.id]?.count == 1 }
    }

    private static func countChips(for row: Option, context: Context) -> Int {
        // The editor represents an inserted mention as an AXImage whose name
        // is the plugin's display name. The menu adds its description to that name.
        descendants(context.editor, depth: 6, limit: 160) { item in
            guard role(item) == "AXImage" else { return false }
            let name = label(item)
            return !name.isEmpty && (row.id == name || row.id.hasPrefix(name + " "))
        }.count
    }

    private static func clickPlugin(_ row: Row, trigger: AXUIElement, context: Context) async throws {
        // Chromium's AXPress dismisses these suggestion rows without invoking
        // the insertion handler. Clicking the same verified element takes its normal path.
        if pluginHitPoint(row.element) == nil {
            _ = try validate(context)
            guard expanded(trigger) == true,
                  AXUIElementPerformAction(row.element, "AXScrollToVisible" as CFString) == .success else {
                throw Failure.option
            }
        }
        let location = try await wait(context) { pluginHitPoint(row.element) }
        try Task.checkCancellation()
        _ = try validate(context)
        guard expanded(trigger) == true, enabled(row.element), label(row.element) == row.option.id,
              pluginHitPoint(row.element) == location,
              let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                 mouseCursorPosition: location, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                               mouseCursorPosition: location, mouseButton: .left) else { throw Failure.option }
        for event in [down, up] {
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: AppNavigationAccessibility.syntheticEventTag)
            event.post(tap: .cghidEventTap)
        }
    }

    private static func pluginHitPoint(_ item: AXUIElement) -> CGPoint? {
        guard let rect = frame(item), rect.height >= 8, rect.width >= 8 else { return nil }
        let point = CGPoint(x: rect.midX, y: rect.midY)
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let hit, CFEqual(hit, item) else { return nil }
        return point
    }

    private static func readPower(_ context: Context, model: String) async throws -> Power {
        enum Entry { case power(Power), selectedModel(AXUIElement) }
        var stage = "menu-not-found"
        do {
            let entry = try await wait(context, attempts: 40, failure: .effortControl) {
                () -> Entry? in
                guard let menu = effortMenu(context) else { return nil }
                if let power = currentPower(in: menu, model: model, stage: &stage) { return .power(power) }
                let rows = descendants(menu, depth: 9, limit: 160) { item in
                    role(item) == "AXMenuItem" && enabled(item) && matchesModel(label(item), model) &&
                        !(string(item, "AXMenuItemMarkChar") ?? "").isEmpty
                }
                return rows.count == 1 ? .selectedModel(rows[0]) : nil
            }
            switch entry {
            case .power(let power): return power
            case .selectedModel(let row):
                stage = "compact-view-unavailable"
                // Activating the already checked model returns to the compact slider view.
                try press(row, context: context)
                return try await wait(context, attempts: 40, failure: .effortControl) {
                    guard let menu = effortMenu(context) else { return nil }
                    return currentPower(in: menu, model: model, stage: &stage)
                }
            }
        } catch {
            trace.notice("Effort control unavailable: \(stage, privacy: .public)")
            throw error
        }
    }

    private static func powerScope(_ menu: AXUIElement) -> [AXUIElement] {
        descendants(menu, depth: 10, limit: 150) {
            ["AXMenuItem", "AXSlider"].contains(role($0)) || string($0, kAXSubroleAttribute) == "AXApplicationStatus"
        }
    }

    private static func powerItem(in scope: [AXUIElement]) -> AXUIElement? {
        scope.first(where: { ["AXMenuItem", "AXSlider"].contains(role($0)) && powerLabels.contains(label($0)) })
    }

    private static func currentPower(in menu: AXUIElement, model: String, stage: inout String) -> Power? {
        let scope = powerScope(menu)
        guard let item = powerItem(in: scope) else { stage = "power-row-missing"; return nil }
        guard enabled(item) else { stage = "power-row-disabled"; return nil }
        if let reading = readPowerStatus(in: menu, scope: scope, model: model) {
            return Power(item: item, reading: reading)
        }
        // A reset-to-default action identifies an explicit model selection. Check
        // the displayed model as well before treating this as a single-model slider.
        let reset = scope.contains { role($0) == "AXMenuItem" && resetModelLabels.contains(label($0)) }
        let header = scope.first { role($0) == "AXMenuItem" && modelLabels.contains(label($0)) }
        if reset, let header, staticLabels(header, depth: 5).contains(where: { matchesPowerModel($0, model) }) {
            return Power(item: item, reading: nil)
        }
        stage = reset ? "power-model-header-unreadable" : "power-status-unreadable"
        return nil
    }

    private static func readPowerStatus(in menu: AXUIElement, scope: [AXUIElement], model: String) -> PowerReading? {
        for status in scope where string(status, kAXSubroleAttribute) == "AXApplicationStatus" {
            let candidates = [staticLabels(status, depth: 4).joined(separator: " "), label(status),
                              string(status, kAXValueAttribute) ?? ""]
            if let reading = candidates.lazy.compactMap({ powerReading($0, model: model) }).first { return reading }
        }
        // Chromium sometimes exposes the announcement as ordinary text instead of AXApplicationStatus.
        return staticLabels(menu, depth: 10).lazy.compactMap { powerReading($0, model: model) }.first
    }

    private static func matchesPowerModel(_ label: String, _ model: String) -> Bool {
        let key = normalizedModel(label)
        let expected = normalizedModel(model)
        return key == expected || "gpt" + key == expected
    }

    private static func powerReading(_ text: String, model: String) -> PowerReading? {
        let parts = text.components(separatedBy: .init(charactersIn: ",，、"))
        let selection = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let numbers = parts.dropFirst().joined(separator: " ").split { !$0.isNumber }.compactMap { Int($0) }
        guard numbers.count == 2, numbers[0] > 0, numbers[0] <= numbers[1],
              numbers[1] <= Effort.allCases.count else { return nil }
        for effort in Effort.allCases {
            for name in effort.labels where selection.hasSuffix(" " + name) {
                if matchesPowerModel(String(selection.dropLast(name.count + 1)), model) {
                    return PowerReading(effort: effort, index: numbers[0] - 1, count: numbers[1])
                }
            }
        }
        return nil
    }

    private static func effortMenu(_ context: Context) -> AXUIElement? {
        guard let picker = (try? validate(context))?.picker, expanded(picker) == true,
              let anchor = frame(picker) else { return nil }
        let nearby = anchor.insetBy(dx: -24, dy: -48)
        let menus = portals(context, matching: { node in isMenu(node) && frame(node)?.intersects(nearby) == true })
        let app = AXUIElementCreateApplication(context.pid)
        var focused = element(app, kAXFocusedUIElementAttribute)
        for _ in 0..<12 {
            guard let node = focused else { break }
            if isMenu(node), frame(node)?.intersects(nearby) == true { return node }
            focused = element(node, kAXParentAttribute)
        }
        // Only use geometry alone when it identifies a single nearby menu.
        return menus.count == 1 ? menus[0] : nil
    }

    private static func applyEffort(_ target: Effort, from initial: Snapshot) async throws -> Snapshot {
        let context = initial.context
        guard let catalog = await effortCatalog(for: initial.model, context: context) else { throw Failure.effort }
        guard let desired = catalog.firstIndex(of: target) else { throw Failure.option }
        var saved = try snapshot(context)
        guard matchesModel(saved.model, initial.model),
              let start = catalog.firstIndex(where: { $0.labels.contains(saved.effort) }) else {
            throw Failure.effort
        }
        let direction = desired >= start ? 1 : -1
        for index in stride(from: start, to: desired, by: direction) {
            let expected = index + direction
            let previous = saved
            saved = try await withMenu(.effort, context: context) { _ in
                let power = try await readPower(context, model: previous.model)
                if let reading = power.reading,
                   reading.index != index || reading.count != catalog.count || reading.effort != catalog[index] {
                    trace.notice("Effort catalog mismatch: UI index \(reading.index, privacy: .public) of \(reading.count, privacy: .public), expected index \(index, privacy: .public) of \(catalog.count, privacy: .public)")
                    throw Failure.effort
                }
                var stage = "focus"
                do {
                    try await focusPower(power.item, context: context)
                    stage = "arrow"
                    guard postKey(direction > 0 ? 124 : 123, context: context) else { throw Failure.effort }
                    // Codex commits the arrow change on keydown. Allow the renderer to
                    // process it, dismiss the menu, and verify the saved composer value.
                    stage = "dismiss"
                    try await Task.sleep(for: .milliseconds(350))
                    try await close(try validate(context).picker, context: context)
                    stage = "composer-confirmation"
                    return try await wait(context, attempts: 55, failure: .effortNotApplied) {
                        guard let picker = (try? validate(context))?.picker,
                              expanded(picker) == false, enabled(picker),
                              let result = try? snapshot(context), matchesModel(result.model, previous.model),
                              catalog[expected].labels.contains(result.effort) else { return nil }
                        return result
                    }
                } catch {
                    trace.notice("Effort step failed: \(stage, privacy: .public), expected \(catalog[expected].rawValue, privacy: .public)")
                    throw error
                }
            }
        }
        trace.notice("Effort applied: \(target.rawValue, privacy: .public)")
        return saved
    }

    private static func focusPower(_ item: AXUIElement, context: Context) async throws {
        _ = try validate(context)
        try Task.checkCancellation()
        AXUIElementSetAttributeValue(item, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let app = AXUIElementCreateApplication(context.pid)
        try await wait(context, failure: .effortNotApplied) { () -> Bool? in
            guard let focused = element(app, kAXFocusedUIElementAttribute), CFEqual(focused, item) else { return nil }
            return true
        }
    }

    private static func modelMenu(_ context: Context) -> AXUIElement? {
        portals(context, matching: isMenu).first
    }

    private static func isMenu(_ node: AXUIElement) -> Bool {
        let kind = role(node)
        return kind == "AXMenu" || kind == "AXGroup" &&
            ["菜单", "選單", "menu"].contains(string(node, kAXRoleDescriptionAttribute) ?? "")
    }

    private static func portals(_ context: Context, matching: (AXUIElement) -> Bool) -> [AXUIElement] {
        // Electron appends floating menus after the app shell under the web root.
        // This bounded shallow walk does not descend into the thread transcript.
        return descendants(context.web, depth: 10, limit: 120, reversed: true,
            descending: { node in
                let subrole = string(node, kAXSubroleAttribute) ?? ""
                return !["AXLandmarkMain", "AXLandmarkComplementary", "AXLandmarkBanner"].contains(subrole)
            }, matching: matching)
    }

    static func snapshot(_ context: Context) throws -> Snapshot {
        let composer = try validate(context)
        guard let value = splitSelection(label(composer.picker)) else { throw Failure.composer }
        return Snapshot(context: context, model: value.model, effort: value.label)
    }

    private static func validate(_ context: Context) throws -> Composer {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == context.pid else { throw Failure.context }
        let app = AXUIElementCreateApplication(context.pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        guard let window = element(app, kAXFocusedWindowAttribute), CFEqual(window, context.window),
              string(window, kAXTitleAttribute) == context.title,
              let parent = element(context.editor, kAXParentAttribute),
              let bounds = frame(window), let editorFrame = frame(context.editor),
              bounds.intersects(editorFrame),
              let current = composer(around: parent, editor: context.editor, knownPicker: context.picker) else {
            throw Failure.context
        }
        return current
    }

    private static func findComposer(in web: AXUIElement, bounds: CGRect) -> (AXUIElement, Composer)? {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.65
        var stack = [(web, 0)]
        var visited = 0
        while let (node, depth) = stack.popLast(), visited < 350, ProcessInfo.processInfo.systemUptime < deadline {
            visited += 1
            guard depth < 32 else { continue }
            let kind = role(node)
            if kind == "AXTextArea", let parent = element(node, kAXParentAttribute),
               let composer = composer(around: parent, editor: node) { return (node, composer) }
            guard ["AXWebArea", "AXGroup", "AXScrollArea"].contains(kind),
                  !["AXLandmarkComplementary", "AXLandmarkBanner"].contains(string(node, kAXSubroleAttribute) ?? "")
            else { continue }
            if let rect = frame(node), rect.maxY < bounds.maxY - min(390, bounds.height * 0.55) { continue }
            for child in children(node).prefix(150) { stack.append((child, depth + 1)) }
        }
        return nil
    }

    private static func composer(around parent: AXUIElement, editor: AXUIElement,
                                 knownPicker: AXUIElement? = nil) -> Composer? {
        let siblings = children(parent)
        guard siblings.contains(where: { CFEqual($0, editor) }),
              let add = siblings.first(where: { role($0) == "AXButton" && addLabels.contains(label($0)) }),
              let picker = siblings.first(where: { candidate in
                  guard role(candidate) == "AXPopUpButton" else { return false }
                  if let knownPicker, CFEqual(knownPicker, candidate) { return true }
                  let title = label(candidate)
                  return splitSelection(title) != nil || effortLabels.contains(title)
              }) else { return nil }
        return Composer(picker: picker, add: add)
    }

    private static func splitSelection(_ text: String) -> (model: String, effort: Effort, label: String)? {
        for effort in Effort.allCases {
            for name in effort.labels where text.hasSuffix(" " + name) {
                let model = String(text.dropLast(name.count + 1))
                if isModelName(model) { return (model, effort, name) }
            }
        }
        return nil
    }

    private static func isModelName(_ name: String) -> Bool {
        let normalized = normalizedModel(name)
        return normalized.hasPrefix("gpt") && normalized.dropFirst(3).first?.isNumber == true
    }

    nonisolated private static func normalizedModel(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func matchesModel(_ lhs: String, _ rhs: String) -> Bool {
        normalizedModel(lhs) == normalizedModel(rhs)
    }

    @discardableResult
    private static func wait<T>(_ context: Context, attempts: Int = 14, failure: Failure = .verification,
                                forValue: () -> T?) async throws -> T {
        for _ in 0..<attempts {
            try Task.checkCancellation()
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == context.pid else { throw Failure.context }
            if let value = forValue() { return value }
            try await Task.sleep(for: .milliseconds(40))
        }
        throw failure
    }

    private static func close(_ trigger: AXUIElement, context: Context) async throws {
        if expanded(trigger) == false { return }
        guard expanded(trigger) == true, postKey(53, context: context) else { throw Failure.menu }
        try await wait(context) { expanded(trigger) == false ? true : nil }
    }

    private static func postKey(_ key: CGKeyCode, context: Context) -> Bool {
        guard (try? validate(context)) != nil,
              let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
        for event in [down, up] {
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: AppNavigationAccessibility.syntheticEventTag)
            event.post(tap: .cghidEventTap)
        }
        return true
    }

    private static func press(_ node: AXUIElement, context: Context) throws {
        try Task.checkCancellation()
        _ = try validate(context)
        guard enabled(node) else { throw Failure.option }
        AXUIElementSetMessagingTimeout(node, 0.12)
        guard AXUIElementPerformAction(node, kAXPressAction as CFString) == .success else { throw Failure.menu }
    }

    private static func attribute(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(node, 0.04)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(node, key as CFString, &value) == .success ? value : nil
    }

    private static func element(_ node: AXUIElement, _ key: String) -> AXUIElement? {
        guard let value = attribute(node, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func frame(_ node: AXUIElement) -> CGRect? {
        guard let origin = attribute(node, kAXPositionAttribute), let size = attribute(node, kAXSizeAttribute),
              CFGetTypeID(origin) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(origin, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions),
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private static func string(_ node: AXUIElement, _ key: String) -> String? {
        attribute(node, key) as? String
    }

    private static func role(_ node: AXUIElement) -> String { string(node, kAXRoleAttribute) ?? "" }
    private static func label(_ node: AXUIElement) -> String {
        let title = string(node, kAXTitleAttribute) ?? ""
        return title.isEmpty ? string(node, kAXDescriptionAttribute) ?? "" : title
    }

    private static func expanded(_ node: AXUIElement) -> Bool? { attribute(node, kAXExpandedAttribute) as? Bool }
    private static func enabled(_ node: AXUIElement) -> Bool { attribute(node, kAXEnabledAttribute) as? Bool == true }
    private static func children(_ node: AXUIElement) -> [AXUIElement] { attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] }

    private static func staticLabels(_ node: AXUIElement, depth: Int) -> [String] {
        descendants(node, depth: depth, limit: 32) { role($0) == "AXStaticText" }.compactMap {
            string($0, kAXValueAttribute)
        }
    }

    private static func firstDescendant(_ root: AXUIElement, depth: Int, limit: Int,
                                        matching: (AXUIElement) -> Bool) -> AXUIElement? {
        descendants(root, depth: depth, limit: limit, first: true, matching: matching).first
    }

    private static func descendants(_ root: AXUIElement, depth: Int, limit: Int, reversed: Bool = false,
                                    first: Bool = false, descending: (AXUIElement) -> Bool = { _ in true },
                                    matching: (AXUIElement) -> Bool) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var stack = [(root, 0)]
        var count = 0
        while let (node, level) = stack.popLast(), count < limit {
            count += 1
            if matching(node) {
                result.append(node)
                if first { break }
            }
            if level < depth, descending(node) {
                let nodes = children(node)
                let ordered = reversed ? nodes : Array(nodes.reversed())
                stack.append(contentsOf: ordered.map { ($0, level + 1) })
            }
        }
        return result
    }

    private static func effortCatalog(for model: String, context: Context) async -> [Effort]? {
        let running = NSRunningApplication(processIdentifier: context.pid)
        guard let cli = running?.bundleURL?.appendingPathComponent("Contents/Resources/codex-cli/bin/codex")
        else { return nil }
        let normalized = normalizedModel(model)
        return await Task.detached(priority: .userInitiated) {
            readEffortCatalog(executable: cli, model: normalized)
        }.value
    }

    /// The supported levels come from the running app's bundled CLI. The UI's
    /// selected index/count must independently agree before we expose these levels.
    nonisolated private static func readEffortCatalog(executable: URL, model: String) -> [Effort]? {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        let pipe = Pipe()
        let input = Pipe()
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { return nil }
        let task = Process()
        task.executableURL = executable
        task.arguments = ["app-server", "-c", "analytics.enabled=false"]
        task.standardInput = input
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        defer {
            try? input.fileHandleForWriting.close()
            if task.isRunning { task.terminate() }
        }

        func send(_ message: String) -> Bool {
            do {
                try input.fileHandleForWriting.write(contentsOf: Data((message + "\n").utf8))
                return true
            } catch { return false }
        }

        do { try task.run() } catch { return nil }
        guard send(#"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"miremote_settings","version":"1.0"}}}"#)
        else { return nil }
        let end = ProcessInfo.processInfo.systemUptime + 3
        var buffer = Data()
        var pending = pollfd(fd: pipe.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while ProcessInfo.processInfo.systemUptime < end && buffer.count < 1_048_576 {
            guard poll(&pending, 1, 100) >= 0 else { return nil }
            guard pending.revents & Int16(POLLIN) != 0 else {
                if pending.revents != 0 { return nil }
                continue
            }
            let count = bytes.withUnsafeMutableBytes { read(pending.fd, $0.baseAddress, $0.count) }
            guard count > 0 else { return nil }
            buffer.append(contentsOf: bytes.prefix(count))
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard let reply = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      let id = reply["id"] as? Int else { continue }
                guard let result = reply["result"] as? [String: Any] else { return nil }
                if id == 1 {
                    guard send(#"{"method":"initialized"}"#),
                          send(#"{"id":2,"method":"model/list","params":{"limit":100}}"#) else { return nil }
                }
                if id == 2 {
                    let entries = result["data"] as? [[String: Any]] ?? []
                    let matches = entries.filter { entry in
                        ["model", "displayName"].contains { entry[$0].map { normalizedModel($0 as? String ?? "") } == model }
                    }
                    guard matches.count == 1,
                          let raw = matches[0]["supportedReasoningEfforts"] as? [[String: Any]] else { return nil }
                    let efforts = raw.compactMap { ($0["reasoningEffort"] as? String).flatMap(Effort.init(rawValue:)) }
                    return efforts.count == raw.count && Set(efforts).count == efforts.count ? efforts : nil
                }
            }
        }
        return nil
    }
}
