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
        case tvOff
        case tvVolumeUp
        case tvVolumeDown
        case quitCurrentApp
        case quitApp(bundleID: String)

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

    /// 保留调用方顺序，去重稳定 ID；取消始终可用且位于最后。
    mutating func open(choices: [Choice] = [.sleep, .shutDown, .cancel]) {
        var ids: Set<String> = [Choice.cancel.id]
        self.choices = choices.filter { ids.insert($0.id).inserted } + [.cancel]
        selection = .cancel
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
        if [.back, .power, .home, .tv].contains(key) {
            close()
            return .dismiss
        }
        guard !isExecuting else { return .none }
        switch key {
        case .up, .down, .left, .right:
            moveSelection(by: key == .up || key == .left ? -1 : 1)
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
        selection = current
        return activateSelection()
    }

    private mutating func moveSelection(by delta: Int) {
        guard let index = choices.firstIndex(where: { $0.id == selection.id }) else { return }
        var next = index + delta
        while choices.indices.contains(next) {
            if !choices[next].disabled {
                selection = choices[next]
                error = nil
                return
            }
            next += delta
        }
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

    /// 仅验证值与状态转移，不调用执行器、NSAppleScript 或任何真实设备 API。
    static func selfCheck() -> Bool {
        let volume = Choice(id: "tv.volumeUp", title: "电视音量 +", symbol: "speaker.plus",
                            section: "小米电视", command: .tvVolumeUp)
        let unavailable = Choice(id: "tv.off", title: "关闭小米电视（待机）", symbol: "power",
                                 section: "小米电视", command: .tvOff, disabled: true)
        let app = Choice(id: "app.example", title: "关闭示例 App", symbol: "app",
                         section: "应用", command: .quitApp(bundleID: "com.example.app"))
        var state = PowerMenuState()
        state.open()
        guard state.selection == .cancel, state.handle(.ok) == .dismiss,
              !state.isOpen else { return false }
        for key in [RemoteKey.back, .power, .home, .tv] {
            state.open()
            guard state.handle(.up) == .none, state.selection == .shutDown,
                  state.handle(key) == .dismiss, !state.isOpen else { return false }
        }
        state.open(choices: [volume, unavailable, .sleep, app, volume])
        guard state.choices == [volume, unavailable, .sleep, app, .cancel],
              state.selection == .cancel, state.select(unavailable) == .none,
              state.selection == .cancel else { return false }
        for expected in [app, .sleep, volume, volume] {
            guard state.handle(.up) == .none, state.selection == expected,
                  !state.isExecuting else { return false }
        }
        guard state.handle(.right) == .none, state.selection == .sleep,
              state.handle(.left) == .none, state.selection == volume,
              state.handle(.ok) == .execute(.tvVolumeUp), state.isExecuting,
              state.handle(.ok) == .none, state.select(app) == .none,
              state.handle(.down) == .none, state.selection == volume,
              state.complete(.success(())) == .none, state.isOpen,
              !state.isExecuting, state.selection == volume,
              state.handle(.ok) == .execute(.tvVolumeUp),
              state.complete(.failure(.message("电视未响应"))) == .none,
              state.isOpen, state.selection == .cancel,
              state.error == "电视未响应",
              state.complete(.success(())) == .none,
              state.error == "电视未响应" else { return false }
        for choice in [Choice.sleep, .shutDown, app,
                       Choice(id: "tv.off", title: "待机", symbol: "power",
                              section: "小米电视", command: .tvOff)] {
            state.open(choices: [choice])
            guard state.handle(.up) == .none, state.selection == choice,
                  let command = choice.command,
                  state.handle(.ok) == .execute(command),
                  state.handle(.ok) == .none,
                  state.complete(.success(())) == .dismiss,
                  !state.isOpen, state.handle(.ok) == .none else { return false }
        }
        state.open(choices: [unavailable])
        guard state.handle(.up) == .none, state.selection == .cancel,
              state.select(Choice.sleep) == .none,
              state.handle(.ok) == .dismiss else { return false }
        state.open(choices: [])
        return state.choices == [.cancel] && state.selection == .cancel
            && state.handle(.ok) == .dismiss
    }
}
