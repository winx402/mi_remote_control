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

        var message: String {
            switch self {
            case .permissionDenied:
                return "未获自动化权限，请在系统设置中允许控制 System Events。"
            case .cancelled: return "电源操作已取消。"
            case .unavailable: return "无法完成电源操作，请稍后重试。"
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

/// 电源列表的纯状态机：打开、移动和取消永远不产生电源请求。
struct PowerMenuState {
    enum Choice: Int, CaseIterable, Sendable, Equatable {
        case sleep, shutDown, cancel

        var title: String {
            switch self {
            case .sleep: return "休眠"
            case .shutDown: return "关机"
            case .cancel: return "取消"
            }
        }

        var symbol: String {
            switch self {
            case .sleep: return "moon.zzz"
            case .shutDown: return "power"
            case .cancel: return "xmark"
            }
        }

        var request: ComputerPower.Request? {
            switch self {
            case .sleep: return .sleep
            case .shutDown: return .shutDown
            case .cancel: return nil
            }
        }
    }

    enum Effect: Equatable {
        case none
        case dismiss
        case execute(ComputerPower.Request)
    }

    private(set) var selection: Choice = .cancel
    private(set) var isOpen = false
    private(set) var isExecuting = false
    private(set) var error: String?

    mutating func open() {
        selection = .cancel
        isOpen = true
        isExecuting = false
        error = nil
    }

    mutating func close() {
        isOpen = false
        isExecuting = false
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
        case .up, .down:
            let delta = key == .up ? -1 : 1
            selection = Choice(rawValue: min(max(selection.rawValue + delta, 0), Choice.allCases.count - 1))!
            error = nil
            return .none
        case .ok:
            guard let request = selection.request else {
                close()
                return .dismiss
            }
            isExecuting = true
            error = nil
            return .execute(request)
        default:
            return .none
        }
    }

    mutating func complete(_ result: Result<Void, ComputerPower.Failure>) -> Effect {
        guard isOpen, isExecuting else { return .none }
        isExecuting = false
        switch result {
        case .success:
            close()
            return .dismiss
        case .failure(let failure):
            selection = .cancel
            error = failure.message
            return .none
        }
    }

    /// 执行器只在这里由测试注入；不会走 ComputerPower.execute 或任何真实电源 API。
    static func selfCheck() -> Bool {
        var requests: [ComputerPower.Request] = []
        let executor: (ComputerPower.Request) -> Result<Void, ComputerPower.Failure> = {
            requests.append($0)
            return .success(())
        }
        func dispatch(_ key: RemoteKey, to state: inout PowerMenuState) -> Effect {
            let effect = state.handle(key)
            if case .execute(let request) = effect { return state.complete(executor(request)) }
            return effect
        }

        var state = PowerMenuState()
        state.open()
        guard state.selection == .cancel, requests.isEmpty,
              dispatch(.ok, to: &state) == .dismiss, requests.isEmpty else { return false }
        for key in [RemoteKey.back, .power, .home, .tv] {
            state.open()
            _ = dispatch(.up, to: &state)
            guard state.selection == .shutDown, requests.isEmpty,
                  dispatch(key, to: &state) == .dismiss, !state.isOpen,
                  requests.isEmpty else { return false }
        }
        state.open()
        for key in [RemoteKey.up, .up, .up, .down, .down, .down, .left, .right] {
            _ = dispatch(key, to: &state)
        }
        guard state.selection == .cancel, requests.isEmpty else { return false }
        for request in [ComputerPower.Request.sleep, .shutDown] {
            state.open()
            _ = dispatch(.up, to: &state)
            if request == .sleep { _ = dispatch(.up, to: &state) }
            guard state.handle(.ok) == .execute(request), state.isExecuting,
                  state.handle(.ok) == .none else { return false }
            guard state.complete(executor(request)) == .dismiss,
                  state.handle(.ok) == .none, !state.isOpen else { return false }
        }
        guard requests == [.sleep, .shutDown] else { return false }
        state.open()
        _ = state.handle(.up)
        guard state.handle(.ok) == .execute(.shutDown),
              state.complete(.failure(.permissionDenied)) == .none,
              state.isOpen, state.selection == .cancel,
              state.error == ComputerPower.Failure.permissionDenied.message,
              dispatch(.ok, to: &state) == .dismiss,
              requests == [.sleep, .shutDown] else { return false }
        return ComputerPower.selfCheck()
    }
}
