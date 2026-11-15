import AppKit

/// 只允许固定的正常电源请求，避免把配置或任意文本拼进可执行脚本。
enum ComputerPower {
    enum Request: Sendable, Equatable {
        case sleep
        case shutDown

        var script: String {
            switch self {
            case .sleep: return #"tell application "System Events" to sleep"#
            case .shutDown: return #"tell application "System Events" to shut down"#
            }
        }
    }

    enum Failure: Error, Sendable, Equatable {
        case permissionDenied
        case cancelled
        case unavailable
        case message(String)

        var message: String {
            switch self {
            case .permissionDenied:
                return "未获自动化权限，请在系统设置中允许控制 System Events。"
            case .cancelled: return "电源操作已取消。"
            case .unavailable: return "无法完成电源操作，请稍后重试。"
            case .message(let message): return message
            }
        }
    }

    private static let queue = DispatchQueue(label: "com.miremote.computer-power", qos: .userInitiated)

    /// AppleScript 可能等待系统授权或 App 保存文件，独立串行队列避免阻塞遥控 UI。
    /// Automation 授权由系统首次发送 AppleEvent 时处理，不主动预申请或绕过权限。
    static func execute(_ request: Request,
                        completion: @escaping @MainActor @Sendable (Result<Void, Failure>) -> Void) {
        queue.async {
            let result = perform(request)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func perform(_ request: Request) -> Result<Void, Failure> {
        guard let script = NSAppleScript(source: request.script) else { return .failure(.unavailable) }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil, (result as NSAppleEventDescriptor?) != nil else {
            return .failure(failure(for: (error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue))
        }
        return .success(())
    }

    static func failure(for code: Int?) -> Failure {
        switch code {
        case -1743: return .permissionDenied
        case -128: return .cancelled
        default: return .unavailable
        }
    }

    /// 不创建 NSAppleScript、不发送 AppleEvents；只验证固定请求与错误映射。
    static func selfCheck() -> Bool {
        Request.sleep.script == #"tell application "System Events" to sleep"#
            && Request.shutDown.script == #"tell application "System Events" to shut down"#
            && failure(for: -1743) == .permissionDenied
            && failure(for: -128) == .cancelled
            && failure(for: nil) == .unavailable
    }
}

/// 可注入选项的纯状态机。打开、移动和取消永远不产生设备操作。
struct PowerMenuState {
    static let appColumns = 10
    static let actionColumns = 6

    enum Command: Sendable, Equatable {
        case computer(ComputerPower.Request)
        case tvWake
        case tvStandby
        case tvOff
        case tvVolumeUp
        case tvVolumeDown
        case tvMute
        case quitCurrentApp
        case quitApp(bundleID: String)
        case quitAppFromOptions(bundleID: String)
        case launchApp(bundleID: String)
        case systemAction(String)
        case focusInput
        case openSettings

        /// 遥控器由入口统一计时；鼠标使用同一 0.6 秒确认规则。
        /// 电视关机只打开电视自己的确认菜单，无须在本机重复确认。
        var requiresHoldConfirmation: Bool {
            switch self {
            case .computer, .quitCurrentApp, .quitApp: return true
            case .systemAction(let action): return ["lock_screen", "display_sleep"].contains(action)
            default: return false
            }
        }

        var isAppLaunch: Bool {
            if case .launchApp = self { return true }
            return false
        }

        var keepsMenuOpen: Bool {
            switch self {
            case .quitCurrentApp, .quitApp, .quitAppFromOptions: return true
            case .tvMute, .systemAction("play_pause"), .systemAction("mute"): return true
            case .tvVolumeUp, .tvVolumeDown: return true
            default: return false
            }
        }
    }

    struct Choice: Identifiable, Sendable, Equatable {
        let id: String
        let title: String
        let symbol: String
        let section: String
        let detail: String?
        let command: Command?
        let disabled: Bool

        init(id: String, title: String, symbol: String, section: String,
             detail: String? = nil, command: Command? = nil, disabled: Bool = false) {
            self.id = id
            self.title = title
            self.symbol = symbol
            self.section = section
            self.detail = detail
            self.command = command
            self.disabled = disabled
        }

        static let sleep = Choice(id: "mac.sleep", title: "Mac 休眠", symbol: "moon.zzz",
                                  section: "这台 Mac", detail: "让这台 Mac 进入休眠。",
                                  command: .computer(.sleep))
        static let shutDown = Choice(id: "mac.shutDown", title: "Mac 关机", symbol: "power",
                                     section: "这台 Mac", detail: "正常关闭这台 Mac，系统可能提示保存文件。",
                                     command: .computer(.shutDown))
        static let cancel = Choice(id: "cancel", title: "取消", symbol: "xmark", section: "")
    }

    /// 同名分类合并，按首次出现顺序排列；取消独立于分类。
    struct Section: Identifiable, Sendable, Equatable {
        var id: String { title }
        let title: String
        var choices: [Choice]

        /// 与面板网格共用固定列数；未填满的末行不拉伸列宽。
        var columnCount: Int {
            !choices.isEmpty && choices.allSatisfy { $0.command?.isAppLaunch == true }
                ? PowerMenuState.appColumns : PowerMenuState.actionColumns
        }
    }

    var sections: [Section] {
        var result: [Section] = []
        for choice in choices where choice.id != Choice.cancel.id {
            if let index = result.firstIndex(where: { $0.title == choice.section }) {
                result[index].choices.append(choice)
            } else {
                result.append(Section(title: choice.section, choices: [choice]))
            }
        }
        return result
    }

    enum Effect: Equatable {
        case none
        case dismiss
        case execute(Command)
    }

    private(set) var choices: [Choice] = [.sleep, .shutDown, .cancel]
    private(set) var selection: Choice = .cancel
    private(set) var isOpen = false
    private(set) var isExecuting = false
    private(set) var error: String?
    enum AppOption { case open, quit }
    private(set) var appOption: AppOption?
    private(set) var canQuitSelectedApp = false

    mutating func showAppOptions(running: Bool) {
        guard isOpen, !isExecuting, case .launchApp = selection.command else { return }
        canQuitSelectedApp = running
        appOption = .open
    }

    var selectedCommand: Command? {
        if appOption == .quit, case .launchApp(let id) = selection.command {
            return .quitAppFromOptions(bundleID: id)
        }
        return selection.command
    }

    private var executingCommand: Command?
    private var preferredPosition = 0.5 / Double(appColumns)

    private struct VisualRow {
        let sectionID: String
        let columnCount: Int
        let choices: [Choice]
    }

    /// 每个分类独立折行，与所有分类展开时的视图顺序一致。
    private var visualRows: [VisualRow] {
        sections.flatMap { section in
            stride(from: 0, to: section.choices.count, by: section.columnCount).map { start in
                VisualRow(sectionID: section.id, columnCount: section.columnCount,
                          choices: Array(section.choices[start..<min(start + section.columnCount,
                                                                    section.choices.count)]))
            }
        }
    }

    /// 保留调用方顺序，去重稳定 ID；取消始终可用且位于最后。
    mutating func open(choices: [Choice] = [.sleep, .shutDown, .cancel]) {
        var ids: Set<String> = [Choice.cancel.id]
        self.choices = choices.filter { ids.insert($0.id).inserted } + [.cancel]
        appOption = nil
        selection = .cancel
        preferredPosition = 0.5 / Double(Self.appColumns)
        isOpen = true
        isExecuting = false
        executingCommand = nil
        error = nil
        // 调用方已将运行中的 App 排在收藏 App 前面；打开只聚焦，不执行。
        if let first = self.choices.first(where: { !$0.disabled && $0.command?.isAppLaunch == true })
            ?? sections.flatMap(\.choices).first(where: { !$0.disabled }) {
            updateSelection(first)
        }
    }

    /// App 生命周期变化只更新当前面板，不重新打开、执行或安装输入捕获。
    /// 尽量保留当前焦点；目标消失时选同位置的下一项。
    mutating func refreshChoices(_ choices: [Choice]) {
        guard isOpen, !isExecuting else { return }
        let selectedID = selection.id
        let oldIndex = self.choices.firstIndex { $0.id == selectedID } ?? 0
        var ids: Set<String> = [Choice.cancel.id]
        self.choices = choices.filter { ids.insert($0.id).inserted } + [.cancel]
        let replacement = self.choices.first { $0.id == selectedID && !$0.disabled }
            ?? self.choices.dropFirst(min(oldIndex, self.choices.count - 1)).first { !$0.disabled }
            ?? .cancel
        if replacement != selection {
            updateSelection(replacement)
        } else {
            updatePreferredPosition(for: replacement)
        }
    }

    mutating func close() {
        appOption = nil
        isOpen = false
        isExecuting = false
        executingCommand = nil
        error = nil
    }

    mutating func handle(_ key: RemoteKey) -> Effect {
        guard isOpen else { return .none }
        if appOption != nil, !isExecuting {
            switch key {
            case .back, .menu: appOption = nil
            case .up, .left: appOption = .open
            case .down, .right: if canQuitSelectedApp { appOption = .quit }
            case .ok: return activateSelection()
            case .home, .power, .tv: close(); return .dismiss
            default: break
            }
            return .none
        }
        if [.back, .power, .home, .tv, .menu].contains(key) {
            close()
            return .dismiss
        }
        guard !isExecuting else { return .none }
        switch key {
        case .up, .down:
            moveRow(by: key == .up ? -1 : 1)
            return .none
        case .left, .right:
            moveColumn(by: key == .left ? -1 : 1)
            return .none
        case .ok:
            return activateSelection()
        default:
            return .none
        }
    }

    /// 鼠标与遥控器共用同一执行闸门；只接受当前列表中的可用项目。
    mutating func select(_ choice: Choice) -> Effect {
        guard isOpen, !isExecuting,
              let current = choices.first(where: { $0.id == choice.id }),
              !current.disabled else { return .none }
        updateSelection(current)
        return activateSelection()
    }

    /// 指针聚焦与明确激活分离；不信任调用方携带的命令或 disabled 标记。
    mutating func focus(_ choice: Choice) {
        guard isOpen, !isExecuting,
              let current = choices.first(where: { $0.id == choice.id }),
              !current.disabled else { return }
        updateSelection(current)
    }

    /// 保留给程序化预览使用；分类聚焦只移动到最近的可用格，不执行动作。
    mutating func focusSection(_ id: String) {
        guard isOpen, !isExecuting,
              let row = visualRows.first(where: { $0.sectionID == id && $0.choices.contains { !$0.disabled } }),
              let choice = preferredChoice(in: row) else { return }
        updateSelection(choice)
    }

    private mutating func updateSelection(_ choice: Choice) {
        appOption = nil
        selection = choice
        error = nil
        updatePreferredPosition(for: choice)
    }

    private mutating func updatePreferredPosition(for choice: Choice) {
        if let row = visualRows.first(where: { $0.choices.contains { $0.id == choice.id } }),
           let column = row.choices.firstIndex(where: { $0.id == choice.id }) {
            preferredPosition = (Double(column) + 0.5) / Double(row.columnCount)
        }
    }

    private mutating func moveColumn(by delta: Int) {
        guard selection.id != Choice.cancel.id,
              let row = visualRows.first(where: { $0.choices.contains { $0.id == selection.id } }),
              let column = row.choices.firstIndex(where: { $0.id == selection.id }) else { return }
        // 只在当前视觉行内循环；末行按实际项目数取模，并跳过禁用格。
        var next = column
        for _ in row.choices.indices {
            next = (next + delta + row.choices.count) % row.choices.count
            if !row.choices[next].disabled {
                updateSelection(row.choices[next])
                return
            }
        }
    }

    private mutating func moveRow(by delta: Int) {
        let rows = visualRows
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex(where: { $0.choices.contains { $0.id == selection.id } })
        // 取消仅作关闭按钮与错误安全焦点，不插入普通上下循环。
        var next = current ?? (delta > 0 ? -1 : rows.count)
        for _ in rows.indices {
            next = (next + delta + rows.count) % rows.count
            if let choice = preferredChoice(in: rows[next]) {
                updateSelection(choice)
                return
            }
        }
    }

    private func preferredChoice(in row: VisualRow) -> Choice? {
        // 不同列数按固定格中心对齐；禁用格跳过，等距时选择左侧。
        let column = row.choices.indices.filter { !row.choices[$0].disabled }
            .min { left, right in
                let leftDistance = abs((Double(left) + 0.5) / Double(row.columnCount) - preferredPosition)
                let rightDistance = abs((Double(right) + 0.5) / Double(row.columnCount) - preferredPosition)
                return abs(leftDistance - rightDistance) < 0.000_001
                    ? left < right : leftDistance < rightDistance
            }
        return column.map { row.choices[$0] }
    }

    private mutating func activateSelection() -> Effect {
        guard !selection.disabled else { return .none }
        guard let command = selectedCommand else {
            close()
            return .dismiss
        }
        appOption = nil
        isExecuting = true
        executingCommand = command
        error = nil
        return .execute(command)
    }

    mutating func complete(_ result: Result<Void, ComputerPower.Failure>) -> Effect {
        guard isOpen, isExecuting, let command = executingCommand else { return .none }
        isExecuting = false
        executingCommand = nil
        switch result {
        case .success:
            if command.keepsMenuOpen { return .none }
            close()
            return .dismiss
        case .failure(let failure):
            selection = .cancel
            error = failure.message
            return .none
        }
    }

    /// 仅验证固定网格导航、命令元数据与执行闸门，不调用真实设备 API。
    static func selfCheck() -> Bool {
        func item(_ index: Int, section: String = "功能", disabled: Bool = false) -> Choice {
            Choice(id: "\(section).\(index)", title: "\(index)", symbol: "app", section: section,
                   command: .systemAction("action.\(index)"), disabled: disabled)
        }
        var options = Self()
        let target = Choice(id: "one", title: "One", symbol: "app", section: "Apps", command: .launchApp(bundleID: "one"))
        options.open(choices: [target])
        options.showAppOptions(running: false)
        guard options.handle(.down) == .none, options.appOption == .open,
              options.handle(.back) == .none, options.selection == target, options.isOpen else { return false }
        options.showAppOptions(running: true)
        guard options.handle(.down) == .none, options.selectedCommand == .quitAppFromOptions(bundleID: "one"),
              options.selectedCommand?.requiresHoldConfirmation == false,
              options.handle(.ok) == .execute(.quitAppFromOptions(bundleID: "one")),
              options.appOption == nil, options.isExecuting,
              options.handle(.ok) == .none,
              options.complete(.success(())) == .none,
              options.isOpen, !options.isExecuting,
              options.selection == target, options.selectedCommand == .launchApp(bundleID: "one") else { return false }
        // 完成回调不关闭面板，后续方向、OK 和返回仍可用；关闭后刷新不复活。
        let nextTarget = Choice(id: "two", title: "Two", symbol: "app", section: "Apps", command: .launchApp(bundleID: "two"))
        options.refreshChoices([target, nextTarget])
        guard options.handle(.right) == .none, options.selection == nextTarget,
              options.handle(.ok) == .execute(.launchApp(bundleID: "two")) else { return false }
        options.open(choices: [target, nextTarget])
        options.refreshChoices([nextTarget])
        guard options.selection == nextTarget, options.isOpen, !options.isExecuting,
              options.handle(.back) == .dismiss else { return false }
        options.refreshChoices([target])
        guard !options.isOpen else { return false }
        let apps = (0..<13).map {
            Choice(id: "app.\($0)", title: "App \($0)", symbol: "app", section: "软件",
                   command: .launchApp(bundleID: "app.\($0)"), disabled: $0 == 1)
        }
        // 前方软件退出导致折行改变时，保留软件焦点并按新的视觉列上下导航。
        options.open(choices: apps)
        options.focus(apps[10])
        options.refreshChoices(Array(apps.dropFirst()))
        guard options.selection == apps[10], options.handle(.down) == .none,
              options.selection == apps[12] else { return false }
        let actions = (0..<14).map { item($0, disabled: $0 == 7) }
        let unavailable = (0..<7).map { item($0, section: "不可用", disabled: true) }
        let volume = Choice(id: "volume", title: "音量", symbol: "speaker", section: "电视", command: .tvVolumeUp)
        var state = PowerMenuState()
        state.open()
        guard state.selection == .sleep, !state.isExecuting,
              state.handle(.left) == .none, state.selection == .shutDown,
              state.handle(.right) == .none, state.selection == .sleep else { return false }
        state.open(choices: [actions[0]] + apps + [actions[1], apps[0]])
        guard state.selection == apps[0], !state.isExecuting,
              state.choices.count == 16,
              state.sections.map(\.title) == ["功能", "软件"],
              state.sections[0].choices == [actions[0], actions[1]],
              state.sections[1].columnCount == 10,
              state.sections[0].columnCount == 6 else { return false }
        // 软件十列折行；左右在同一视觉行首尾循环，禁用格可跨越。
        state.open(choices: apps + actions)
        guard state.selection == apps[0], state.handle(.right) == .none,
              state.selection == apps[2], state.handle(.left) == .none,
              state.selection == apps[0] else { return false }
        state.focus(apps[9])
        guard state.handle(.right) == .none, state.selection == apps[0],
              state.handle(.left) == .none, state.selection == apps[9],
              state.handle(.down) == .none, state.selection == apps[12],
              state.handle(.right) == .none, state.selection == apps[10],
              state.handle(.left) == .none, state.selection == apps[12],
              state.handle(.up) == .none, state.selection == apps[2] else { return false }
        state.focus(apps[10])
        guard state.handle(.left) == .none, state.selection == apps[12],
              state.handle(.right) == .none, state.selection == apps[10],
              state.handle(.up) == .none, state.selection == apps[0] else { return false }
        // 六列功能区逐行移动，并按固定格中心在十列/六列之间对齐。
        state.focus(actions[5])
        guard state.handle(.right) == .none, state.selection == actions[0],
              state.handle(.left) == .none, state.selection == actions[5],
              state.handle(.down) == .none, state.selection == actions[11],
              state.handle(.up) == .none, state.selection == actions[5] else { return false }
        state.focus(actions[6])
        guard state.handle(.left) == .none, state.selection == actions[11],
              state.handle(.right) == .none, state.selection == actions[6],
              state.handle(.right) == .none, state.selection == actions[8],
              state.handle(.left) == .none, state.selection == actions[6] else { return false }
        state.focus(actions[13])
        guard state.handle(.right) == .none, state.selection == actions[12],
              state.handle(.left) == .none, state.selection == actions[13] else { return false }
        state.focus(apps[12])
        guard state.handle(.down) == .none, state.selection == actions[1],
              state.handle(.up) == .none, state.selection == apps[12] else { return false }
        // 禁用列等距偏左；上下循环跳过全禁用行，不经过取消。
        state.focus(actions[1])
        guard state.handle(.down) == .none, state.selection == actions[6] else { return false }
        state.open(choices: unavailable + apps + actions + unavailable.map {
            Choice(id: "last.\($0.id)", title: $0.title, symbol: $0.symbol, section: "末尾不可用", disabled: true)
        })
        state.focus(actions[12])
        guard state.handle(.down) == .none, state.selection == apps[0],
              state.handle(.up) == .none, state.selection == actions[12],
              state.handle(.down) == .none, state.selection == apps[0] else { return false }
        state.focus(.cancel)
        guard state.handle(.down) == .none, state.selection == apps[0] else { return false }
        state.focus(.cancel)
        guard state.handle(.up) == .none, state.selection == actions[12] else { return false }
        // 鼠标使用权威目录，伪造命令或可用标志不能改变真实动作。
        let forgedDisabled = Choice(id: apps[1].id, title: "伪造可用", symbol: "app", section: "软件",
                                    command: .computer(.shutDown))
        state.focus(forgedDisabled)
        guard state.select(forgedDisabled) == .none, state.selection == actions[12] else { return false }
        let forged = Choice(id: apps[0].id, title: "伪造", symbol: "power", section: "其他",
                            command: .computer(.shutDown))
        state.focus(forged)
        guard state.selection == apps[0], !state.isExecuting,
              state.handle(.ok) == .execute(.launchApp(bundleID: "app.0")),
              state.handle(.ok) == .none, state.select(actions[0]) == .none else { return false }
        state.focus(actions[0])
        state.focusSection("功能")
        guard state.selection == apps[0], state.handle(.down) == .none,
              state.selection == apps[0], state.complete(.success(())) == .dismiss,
              !state.isOpen, state.complete(.success(())) == .none else { return false }
        // 音量保持面板开启；失败回落到取消，恢复导航清除错误。
        state.open(choices: apps + [volume])
        guard state.select(volume) == .execute(.tvVolumeUp),
              state.complete(.success(())) == .none, state.isOpen,
              state.select(volume) == .execute(.tvVolumeUp),
              state.complete(.failure(.message("电视未响应"))) == .none,
              state.selection == .cancel, state.error == "电视未响应",
              state.complete(.success(())) == .none, state.error == "电视未响应",
              state.handle(.down) == .none, state.selection == apps[0], state.error == nil else { return false }
        state.focusSection("电视")
        state.focusSection("不存在")
        guard state.selection == volume, !state.isExecuting,
              state.handle(.left) == .none, state.selection == volume,
              state.handle(.right) == .none, state.selection == volume else { return false }
        // 首尾禁用时循环仍寻找可用格；整行只有一个可用项时保持原位。
        state.open(choices: (0..<8).map { item($0, disabled: [0, 2, 5, 6].contains($0)) })
        guard state.selection.id == actions[1].id,
              state.handle(.left) == .none, state.selection.id == actions[4].id,
              state.handle(.right) == .none, state.selection.id == actions[1].id,
              state.handle(.down) == .none, state.selection.id == actions[7].id,
              state.handle(.left) == .none, state.selection.id == actions[7].id,
              state.handle(.right) == .none, state.selection.id == actions[7].id else { return false }
        // 执行中仍可关闭；关闭后的完成回调不会复活面板。
        for key in [RemoteKey.back, .power, .home, .tv, .menu] {
            state.open(choices: [volume])
            guard state.handle(.ok) == .execute(.tvVolumeUp),
                  state.handle(key) == .dismiss, !state.isOpen,
                  state.complete(.success(())) == .none else { return false }
        }
        // 独立退出卡片保留长按；常用软件子菜单明确选择退出后单按执行。
        let requiresHold: [Command] = [.computer(.sleep), .computer(.shutDown),
                                      .quitCurrentApp, .quitApp(bundleID: "example.app"),
                                      .systemAction("lock_screen"), .systemAction("display_sleep")]
        let immediate: [Command] = [.tvWake, .tvStandby, .tvOff, .tvVolumeUp, .tvVolumeDown,
                                   .quitAppFromOptions(bundleID: "example.app"),
                                   .launchApp(bundleID: "example.app"), .focusInput, .openSettings,
                                   .systemAction("mission_control"), .systemAction("mute")]
        guard requiresHold.allSatisfy(\.requiresHoldConfirmation),
              immediate.allSatisfy({ !$0.requiresHoldConfirmation }) else { return false }
        for command in requiresHold + immediate {
            let choice = Choice(id: "entry", title: "入口", symbol: "app", section: "控制", command: command)
            state.open(choices: [choice])
            guard state.selection == choice, !state.isExecuting,
                  state.handle(.ok) == .execute(command), state.select(choice) == .none else { return false }
            guard state.complete(.success(())) == (command.keepsMenuOpen ? .none : .dismiss) else { return false }
        }
        // 首个软件禁用时选下一个；没有软件回落至首个可用功能。
        state.open(choices: actions + [apps[1], apps[2]])
        guard state.selection == apps[2] else { return false }
        state.open(choices: [apps[1]] + [actions[0]])
        guard state.selection == actions[0] else { return false }
        for choices in [unavailable, []] {
            state.open(choices: choices)
            for key in [RemoteKey.up, .down, .left, .right] {
                guard state.handle(key) == .none, state.selection == .cancel, !state.isExecuting else { return false }
            }
            guard state.select(.sleep) == .none, state.handle(.ok) == .dismiss, !state.isOpen else { return false }
        }
        return state.sections.isEmpty && state.choices == [.cancel]
    }
}
