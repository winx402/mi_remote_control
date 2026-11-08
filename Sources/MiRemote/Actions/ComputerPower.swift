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
    enum Command: Sendable, Equatable {
        case computer(ComputerPower.Request)
        case tvWake
        case tvStandby
        case tvOff
        case tvVolumeUp
        case tvVolumeDown
        case quitCurrentApp
        case quitApp(bundleID: String)
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

        var keepsMenuOpen: Bool {
            switch self {
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
    private var executingCommand: Command?
    private var rememberedColumns: [String: Int] = [:]
    private var preferredColumn = 0

    /// 保留调用方顺序，去重稳定 ID；取消始终可用且位于最后。
    mutating func open(choices: [Choice] = [.sleep, .shutDown, .cancel]) {
        var ids: Set<String> = [Choice.cancel.id]
        self.choices = choices.filter { ids.insert($0.id).inserted } + [.cancel]
        selection = .cancel
        rememberedColumns = [:]
        preferredColumn = 0
        isOpen = true
        isExecuting = false
        executingCommand = nil
        error = nil
    }

    mutating func close() {
        isOpen = false
        isExecuting = false
        executingCommand = nil
        error = nil
    }

    mutating func handle(_ key: RemoteKey) -> Effect {
        guard isOpen else { return .none }
        if [.back, .power, .home, .tv, .menu].contains(key) {
            close()
            return .dismiss
        }
        guard !isExecuting else { return .none }
        switch key {
        case .up, .down:
            moveSection(by: key == .up ? -1 : 1)
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

    /// 分类点击仅移动到该分类记忆的最近可用列，不执行任何动作。
    mutating func focusSection(_ id: String) {
        guard isOpen, !isExecuting,
              let section = sections.first(where: { $0.id == id }),
              let choice = preferredChoice(in: section) else { return }
        updateSelection(choice)
    }

    private mutating func updateSelection(_ choice: Choice) {
        selection = choice
        error = nil
        if let section = sections.first(where: { $0.id == choice.section }),
           let column = section.choices.firstIndex(where: { $0.id == choice.id }) {
            rememberedColumns[section.id] = column
            preferredColumn = column
        }
    }

    private mutating func moveColumn(by delta: Int) {
        guard selection.id != Choice.cancel.id,
              let section = sections.first(where: { $0.id == selection.section }),
              let column = section.choices.firstIndex(where: { $0.id == selection.id }) else { return }
        var next = column + delta
        while section.choices.indices.contains(next) {
            if !section.choices[next].disabled {
                updateSelection(section.choices[next])
                return
            }
            next += delta
        }
    }

    private mutating func moveSection(by delta: Int) {
        let groups = sections
        let current = selection.id == Choice.cancel.id
            ? groups.count : groups.firstIndex(where: { $0.id == selection.section })
        guard let current else { return }
        let rowCount = groups.count + 1
        var next = current
        // 取消也是最后一行；最多检查一圈，全部禁用或无分类时安全停在取消。
        for _ in 0..<rowCount {
            next = (next + delta + rowCount) % rowCount
            if next == groups.count {
                updateSelection(.cancel)
                return
            }
            if let choice = preferredChoice(in: groups[next]) {
                updateSelection(choice)
                return
            }
        }
    }

    private func preferredChoice(in section: Section) -> Choice? {
        let column = min(rememberedColumns[section.id] ?? preferredColumn,
                         section.choices.count - 1)
        // 分类中的禁用项不可选；优先靠近原列，等距时选择左侧。
        let enabled = section.choices.indices.filter { !section.choices[$0].disabled }
            .min { left, right in
                let leftDistance = abs(left - column)
                let rightDistance = abs(right - column)
                return leftDistance == rightDistance ? left < right : leftDistance < rightDistance
            }
        return enabled.map { section.choices[$0] }
    }

    private mutating func activateSelection() -> Effect {
        guard !selection.disabled else { return .none }
        guard let command = selection.command else {
            close()
            return .dismiss
        }
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

    /// 仅验证二维导航与执行闸门，不调用执行器或真实设备 API。
    static func selfCheck() -> Bool {
        let wake = Choice(id: "tv.wake", title: "开机", symbol: "power", section: "电视", command: .tvWake)
        let standby = Choice(id: "tv.standby", title: "待机", symbol: "moon", section: "电视", command: .tvStandby)
        let off = Choice(id: "tv.off", title: "关机", symbol: "power", section: "电视", command: .tvOff, disabled: true)
        let volume = Choice(id: "tv.volume", title: "音量 +", symbol: "speaker.plus", section: "电视", command: .tvVolumeUp)
        let app = Choice(id: "app.example", title: "退出应用", symbol: "app", section: "应用", command: .quitCurrentApp)
        let unavailable = Choice(id: "disabled", title: "不可用", symbol: "xmark", section: "不可用", disabled: true)
        var state = PowerMenuState()
        state.open()
        guard state.selection == .cancel, state.handle(.left) == .none,
              state.selection == .cancel, state.handle(.ok) == .dismiss, !state.isOpen else { return false }
        for key in [RemoteKey.back, .power, .home, .tv] {
            state.open()
            guard state.handle(.up) == .none, state.selection == .sleep,
                  state.handle(key) == .dismiss, !state.isOpen else { return false }
        }
        // 分类按首次出现排序，非相邻同名项合并；重复 ID 去重。
        state.open(choices: [wake, .sleep, standby, off, volume, .shutDown, unavailable, app, volume])
        guard state.choices.count == 9,
              state.sections.map(\.title) == ["电视", "这台 Mac", "不可用", "应用"],
              state.sections[0].choices == [wake, standby, off, volume],
              state.select(off) == .none, state.selection == .cancel else { return false }
        // 上下切分类，跳过整行禁用；左右仅在当前分类，边界不串行。
        guard state.handle(.up) == .none, state.selection == app,
              state.handle(.right) == .none, state.selection == app,
              state.handle(.up) == .none, state.selection == .sleep,
              state.handle(.right) == .none, state.selection == .shutDown,
              state.handle(.up) == .none, state.selection == standby,
              state.handle(.right) == .none, state.selection == volume,
              state.handle(.right) == .none, state.selection == volume,
              state.handle(.up) == .none, state.selection == .cancel,
              state.handle(.down) == .none, state.selection == volume,
              state.handle(.down) == .none, state.selection == .shutDown,
              state.handle(.left) == .none, state.selection == .sleep,
              state.handle(.up) == .none, state.selection == volume else { return false }
        // 已访问分类记忆自己的列；首次进入较短分类按当前列收敛。
        state.open(choices: [wake, standby, off, volume, .sleep, .shutDown])
        guard state.handle(.up) == .none, state.selection == .sleep,
              state.handle(.up) == .none, state.selection == wake,
              state.handle(.right) == .none, state.selection == standby,
              state.handle(.right) == .none, state.selection == volume,
              state.handle(.down) == .none, state.selection == .sleep,
              state.handle(.down) == .none, state.selection == .cancel,
              state.handle(.right) == .none, state.selection == .cancel,
              state.handle(.up) == .none, state.selection == .sleep,
              state.handle(.up) == .none, state.selection == volume else { return false }
        // 新分类尚无列记忆：从电视最右列向下，Mac 收敛至最后一列。
        state.open(choices: [wake, standby, off, volume, .sleep, .shutDown])
        guard state.select(volume) == .execute(.tvVolumeUp),
              state.handle(.ok) == .none, state.select(.sleep) == .none,
              state.handle(.down) == .none, state.selection == volume,
              state.complete(.success(())) == .none, state.isOpen,
              state.handle(.down) == .none, state.selection == .shutDown,
              state.handle(.up) == .none, state.selection == volume,
              state.handle(.ok) == .execute(.tvVolumeUp),
              state.complete(.failure(.message("电视未响应"))) == .none,
              state.isOpen, state.selection == .cancel, state.error == "电视未响应",
              state.complete(.success(())) == .none, state.error == "电视未响应" else { return false }
        // 上下落到禁用列时选择最近可用项，等距偏左；执行中返回仍可关闭。
        state.open(choices: [wake, off, volume, .sleep, .shutDown])
        guard state.handle(.up) == .none, state.selection == .sleep,
              state.handle(.right) == .none, state.selection == .shutDown,
              state.handle(.up) == .none, state.selection == wake,
              state.handle(.ok) == .execute(.tvWake),
              state.handle(.back) == .dismiss, !state.isOpen,
              state.complete(.success(())) == .none else { return false }
        for choice in [Choice.sleep, .shutDown, app, wake, standby,
                       Choice(id: "tv.off.enabled", title: "关机", symbol: "power", section: "电视", command: .tvOff)] {
            state.open(choices: [choice])
            guard state.handle(.up) == .none, state.selection == choice,
                  let command = choice.command,
                  state.handle(.ok) == .execute(command), state.isExecuting,
                  state.handle(.ok) == .none,
                  state.complete(.success(())) == .dismiss, !state.isOpen else { return false }
        }
        // 首尾循环包含取消行，跳过首尾整组禁用，并保留各类列记忆。
        let unavailableLast = Choice(id: "disabled.last", title: "不可用", symbol: "xmark",
                                     section: "末尾不可用", disabled: true)
        state.open(choices: [unavailable, wake, volume, .sleep, unavailableLast])
        guard state.handle(.down) == .none, state.selection == wake,
              state.handle(.left) == .none, state.selection == wake,
              state.handle(.up) == .none, state.selection == .cancel,
              state.handle(.up) == .none, state.selection == .sleep,
              state.handle(.down) == .none, state.selection == .cancel,
              state.handle(.down) == .none, state.selection == wake,
              state.handle(.right) == .none, state.selection == volume,
              state.handle(.right) == .none, state.selection == volume,
              state.handle(.up) == .none, state.selection == .cancel,
              state.handle(.down) == .none, state.selection == volume else { return false }
        // 指针聚焦不执行；分类点击恢复各自列，并使用列表中的权威项目。
        state.open(choices: [wake, standby, off, volume, .sleep, .shutDown, unavailable])
        state.focus(volume)
        guard state.selection == volume, !state.isExecuting else { return false }
        state.focusSection("这台 Mac")
        guard state.selection == .shutDown, !state.isExecuting else { return false }
        state.focusSection("电视")
        guard state.selection == volume, !state.isExecuting else { return false }
        state.focus(off)
        let forgedDisabled = Choice(id: off.id, title: "伪造可用", symbol: "power", section: "电视",
                                    command: .tvOff)
        state.focus(forgedDisabled)
        guard state.select(forgedDisabled) == .none, state.selection == volume else { return false }
        state.focus(.cancel)
        guard state.isOpen, !state.isExecuting, state.selection == .cancel else { return false }
        state.focusSection("电视")
        state.focusSection("不可用")
        state.focusSection("不存在")
        state.focus(Choice(id: "unknown", title: "未知", symbol: "app", section: "电视"))
        guard state.selection == volume, !state.isExecuting else { return false }
        let forged = Choice(id: wake.id, title: "伪造", symbol: "app", section: "其他",
                            command: .computer(.shutDown))
        state.focus(forged)
        guard state.selection == wake, state.handle(.ok) == .execute(.tvWake) else { return false }
        state.focus(.sleep)
        state.focusSection("这台 Mac")
        guard state.selection == wake, state.isExecuting,
              state.complete(.success(())) == .dismiss else { return false }
        state.focus(volume)
        state.focusSection("电视")
        guard !state.isOpen, !state.isExecuting else { return false }
        // 确认规则是命令元数据，遥控与鼠标共享；电视使用设备原生确认。
        let requiresHold: [Command] = [.computer(.sleep), .computer(.shutDown),
                                      .quitCurrentApp, .quitApp(bundleID: "example.app"),
                                      .systemAction("lock_screen"), .systemAction("display_sleep")]
        let immediate: [Command] = [.tvWake, .tvStandby, .tvOff, .tvVolumeUp, .tvVolumeDown,
                                   .launchApp(bundleID: "example.app"), .focusInput, .openSettings,
                                   .systemAction("mission_control"), .systemAction("mute")]
        guard requiresHold.allSatisfy(\.requiresHoldConfirmation),
              immediate.allSatisfy({ !$0.requiresHoldConfirmation }) else { return false }
        // 新增入口仍走唯一执行闸门，聚焦不会改变完成/错误约定。
        for command in immediate {
            let choice = Choice(id: "entry", title: "入口", symbol: "app", section: "控制", command: command)
            state.open(choices: [choice])
            state.focus(choice)
            guard !state.isExecuting, state.handle(.ok) == .execute(command),
                  state.select(choice) == .none else { return false }
            let effect = state.complete(.success(()))
            guard effect == (command.keepsMenuOpen ? .none : .dismiss) else { return false }
        }
        // 多个分类全禁用与完全无分类时，反复循环仍只停在取消。
        for choices in [[unavailable, unavailableLast], []] {
            state.open(choices: choices)
            for key in [RemoteKey.up, .down, .up, .down, .left, .right] {
                guard state.handle(key) == .none, state.selection == .cancel,
                      !state.isExecuting else { return false }
            }
            guard state.select(.sleep) == .none, state.handle(.ok) == .dismiss else { return false }
        }
        return state.sections.isEmpty && state.choices == [.cancel] && !state.isOpen
    }
}
