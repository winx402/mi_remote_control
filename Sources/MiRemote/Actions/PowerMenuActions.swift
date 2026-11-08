import AppKit

enum PowerMenuCatalog {
    static func choices(televisionConfigured: Bool, currentAppName: String?, douyinRunning: Bool) -> [PowerMenuState.Choice] {
        typealias Item = PowerMenuState.Choice
        let unavailable = televisionConfigured ? nil : "请先在通用设置中配置电视。"
        return [
            Item(id: "tv.wake", title: "唤醒电视", symbol: "sun.max", section: "小米电视",
                 detail: unavailable ?? "从待机恢复；电视已开启时不会把它关闭。", command: .tvWake, disabled: !televisionConfigured),
            Item(id: "tv.standby", title: "电视待机", symbol: "moon.zzz", section: "小米电视",
                 detail: unavailable ?? "让电视进入待机，Mac 继续运行。", command: .tvStandby, disabled: !televisionConfigured),
            Item(id: "tv.off", title: "电视关机", symbol: "power", section: "小米电视",
                 detail: "真正关机尚未接入；先验证待机唤醒和关机后的恢复方式。", command: .tvOff, disabled: true),
            Item(id: "tv.volumeDown", title: "电视音量 −", symbol: "speaker.wave.1", section: "小米电视",
                 detail: unavailable, command: .tvVolumeDown, disabled: !televisionConfigured),
            Item(id: "tv.volumeUp", title: "电视音量 ＋", symbol: "speaker.wave.3", section: "小米电视",
                 detail: unavailable, command: .tvVolumeUp, disabled: !televisionConfigured),
            .sleep, .shutDown,
            Item(id: "apps.current", title: "退出当前 App", symbol: "rectangle.portrait.and.arrow.right", section: "应用",
                 detail: currentAppName ?? "没有可退出的前台 App。", command: .quitCurrentApp, disabled: currentAppName == nil),
            Item(id: "apps.douyin", title: "退出抖音", symbol: "app.badge", section: "应用",
                 detail: douyinRunning ? "正常退出，保留应用自己的保存提示。" : "抖音未运行。",
                 command: .quitApp(bundleID: "com.bytedance.douyin.desktop"), disabled: !douyinRunning)
        ]
    }

    static func selfCheck() -> Bool {
        let configured = choices(televisionConfigured: true, currentAppName: "测试 App", douyinRunning: true)
        let unavailable = choices(televisionConfigured: false, currentAppName: nil, douyinRunning: false)
        return Set(configured.map(\.id)).count == configured.count
            && configured.filter { $0.section == "小米电视" && $0.id != "tv.off" }.allSatisfy { !$0.disabled }
            && unavailable.filter { $0.section == "小米电视" || $0.section == "应用" }.allSatisfy(\.disabled)
            && configured.contains { $0.command == .computer(.shutDown) && $0.title.contains("Mac") }
            && configured.contains { $0.command == .tvStandby && !$0.disabled }
            && configured.contains { $0.command == .tvWake && !$0.disabled }
            && configured.contains { $0.command == .tvOff && $0.disabled }
    }
}

@MainActor
enum PowerMenuActions {
    static func perform(_ command: PowerMenuState.Command, currentApplication: NSRunningApplication?,
                        completion: @escaping @MainActor @Sendable (Result<Void, ComputerPower.Failure>) -> Void) {
        switch command {
        case .computer(let request): ComputerPower.execute(request, completion: completion)
        case .tvWake: television(.wake, completion: completion)
        case .tvStandby: television(.sleep, completion: completion)
        case .tvOff:
            completion(.failure(.message("真正关机尚未接入；待机请使用“电视待机”。")))
        case .tvVolumeUp: television(.volumeUp, completion: completion)
        case .tvVolumeDown: television(.volumeDown, completion: completion)
        case .quitCurrentApp: quit(currentApplication, completion: completion)
        case .quitApp(let bundleID):
            let target = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first { !$0.isTerminated && $0.activationPolicy == .regular }
            quit(target, completion: completion)
        }
    }

    private static func television(_ command: XiaomiTVCommand,
                                   completion: @escaping @MainActor @Sendable (Result<Void, ComputerPower.Failure>) -> Void) {
        XiaomiTVController.shared.perform(command) { result in
            completion(result.mapError { .message($0.message) })
        }
    }

    private static func quit(_ target: NSRunningApplication?,
                             completion: @escaping @MainActor @Sendable (Result<Void, ComputerPower.Failure>) -> Void) {
        guard let target, !target.isTerminated, target.activationPolicy == .regular,
              target.processIdentifier != NSRunningApplication.current.processIdentifier else {
            completion(.failure(.message("目标应用已退出或不可用。")))
            return
        }
        // Normal termination allows the app to show its own save/cancel prompt.
        completion(target.terminate() ? .success(()) : .failure(.message("无法发送退出请求，请在应用中正常退出。")))
    }
}
