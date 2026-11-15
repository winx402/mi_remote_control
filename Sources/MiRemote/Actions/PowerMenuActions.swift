import AppKit

enum PowerMenuCatalog {
    /// 运行中 App 优先，收藏补齐；保留首个 ID 的大小写并稳定去重，不限制运行数量。
    static func orderedAppIDs(running: [String], favorites: [String]) -> [String] {
        var seen: Set<String> = []
        return (running + favorites).compactMap { rawID in
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id.lowercased()).inserted else { return nil }
            return id
        }
    }

    static func choices(televisionConfigured: Bool, currentAppName: String?, douyinRunning: Bool,
                        apps: [(id: String, title: String)] = []) -> [PowerMenuState.Choice] {
        typealias Item = PowerMenuState.Choice
        let unavailable = televisionConfigured ? nil : "请先在通用设置中配置电视。"
        var result = apps.map { app in
            Item(id: "launch.\(app.id)", title: app.title, symbol: "app", section: "常用 App",
                 detail: "打开或切换到\(app.title)。", command: .launchApp(bundleID: app.id))
        }
        result += [
            Item(id: "tv.off", title: "电视关机…", symbol: "power", section: "小米电视",
                 detail: unavailable ?? "打开电视原生电源菜单，再用遥控器选择“关机”并确认。", command: .tvOff, disabled: !televisionConfigured),
            Item(id: "tv.standby", title: "电视待机", symbol: "moon.zzz", section: "小米电视",
                 detail: unavailable ?? "让电视进入待机，Mac 继续运行。", command: .tvStandby, disabled: !televisionConfigured),
            Item(id: "tv.wake", title: "尝试唤醒", symbol: "sun.max", section: "小米电视",
                 detail: unavailable ?? "尝试网络唤醒；电视待机后本地服务离线时无法送达。", command: .tvWake, disabled: !televisionConfigured),
            Item(id: "tv.volumeDown", title: "电视音量 −", symbol: "speaker.wave.1", section: "小米电视",
                 detail: unavailable, command: .tvVolumeDown, disabled: !televisionConfigured),
            Item(id: "tv.volumeUp", title: "电视音量 ＋", symbol: "speaker.wave.3", section: "小米电视",
                 detail: unavailable, command: .tvVolumeUp, disabled: !televisionConfigured),
        ]
        for item in SystemMenuCatalog.items where !item.dangerous {
            switch item.action {
            case .system(let name):
                let media = name == "play_pause" || name == "mute"
                result.append(Item(id: "system.\(name)", title: name == "mute" ? "Mac 静音" : item.title,
                    symbol: item.symbol, section: media ? "媒体" : "工作区", command: .systemAction(name)))
            case .focusInput:
                result.append(Item(id: "system.focusInput", title: item.title, symbol: item.symbol,
                    section: "工作区", command: .focusInput))
            default: break // Settings is grouped with app management below.
            }
        }
        result += [
            .sleep, .shutDown,
            Item(id: "mac.lock", title: "Mac 锁屏", symbol: "lock", section: "这台 Mac",
                 detail: "按住 OK 确认锁屏。", command: .systemAction("lock_screen")),
            Item(id: "mac.displaySleep", title: "Mac 熄屏", symbol: "display", section: "这台 Mac",
                 detail: "关闭 Mac 显示输出，不是电视关机。按住 OK 确认。", command: .systemAction("display_sleep")),
            Item(id: "apps.current", title: "退出当前 App", symbol: "rectangle.portrait.and.arrow.right", section: "应用",
                 detail: currentAppName ?? "没有可退出的前台 App。", command: .quitCurrentApp, disabled: currentAppName == nil),
            Item(id: "apps.douyin", title: "退出抖音", symbol: "app.badge", section: "应用",
                 detail: douyinRunning ? "正常退出，保留应用自己的保存提示。" : "抖音未运行。",
                 command: .quitApp(bundleID: "com.bytedance.douyin.desktop"), disabled: !douyinRunning),
            Item(id: "apps.settings", title: "MiRemote 设置", symbol: "gearshape", section: "应用",
                 detail: "打开遥控器设置。", command: .openSettings)
        ]
        return result
    }

    static func selfCheck() -> Bool {
        let configured = choices(televisionConfigured: true, currentAppName: "测试 App", douyinRunning: true)
        let unavailable = choices(televisionConfigured: false, currentAppName: nil, douyinRunning: false)
        let appList = (0..<23).map { (id: "example.app.\($0)", title: "App \($0)") }
        let withApps = choices(televisionConfigured: true, currentAppName: nil, douyinRunning: false,
                               apps: appList)
        let launchChoices = withApps.filter { $0.command?.isAppLaunch == true }
        let runningIDs = (0..<23).map { "running.\($0)" }
        return orderedAppIDs(running: ["", "  ", "App.A", "app.a", " App.B "],
                             favorites: ["APP.B", "app.C", "", "APP.A", "app.c"]) == ["App.A", "App.B", "app.C"]
            && orderedAppIDs(running: runningIDs, favorites: ["RUNNING.0", "favorite"]) == runningIDs + ["favorite"]
            && orderedAppIDs(running: [], favorites: []) == []
            && launchChoices.count == appList.count
            && launchChoices.map(\.id) == appList.map { "launch.\($0.id)" }
            && Array(withApps.prefix(appList.count)) == launchChoices
            && launchChoices.map(\.command) == appList.map { .launchApp(bundleID: $0.id) }
            && Array(withApps.dropFirst(appList.count)).map(\.id) == configured.map(\.id)
            && Set(configured.map(\.id)).count == configured.count
            && configured.filter { $0.section == "小米电视" }.allSatisfy { !$0.disabled }
            && unavailable.filter { $0.section == "小米电视" || $0.id == "apps.current" || $0.id == "apps.douyin" }.allSatisfy(\.disabled)
            && configured.contains { $0.command == .computer(.shutDown) && $0.title.contains("Mac") }
            && configured.contains { $0.command == .tvStandby && !$0.disabled }
            && configured.contains { $0.command == .tvWake && !$0.disabled }
            && configured.contains { $0.command == .tvOff && !$0.disabled }
            && configured.contains { $0.command == .openSettings }
            && configured.contains { $0.command == .systemAction("mission_control") }
    }
}

@MainActor
enum PowerMenuActions {
    static func perform(_ command: PowerMenuState.Command, currentApplication: NSRunningApplication?,
                        completion: @escaping @MainActor @Sendable (Result<Void, ComputerPower.Failure>) -> Void) {
        switch command {
        case .launchApp(let bundleID):
            guard let app = DockApplications.resolve(bundleID) else { completion(.failure(.message("未找到该应用。"))); return }
            DockApplications.launch(app)
            completion(.success(()))
        case .systemAction(let name): ActionRunner().run(.system(name)); completion(.success(()))
        case .focusInput: ActionRunner().run(.focusInput); completion(.success(()))
        case .openSettings: ActionRunner().run(.overlay("open_settings")); completion(.success(()))
        case .computer(let request): ComputerPower.execute(request, completion: completion)
        case .tvWake: television(.wake, completion: completion)
        case .tvStandby: television(.sleep, completion: completion)
        case .tvOff: television(.powerMenu, completion: completion)
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
