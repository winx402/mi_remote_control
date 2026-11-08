import Foundation

/// A one-shot script interface. Does not start the GUI, Bluetooth, or key mapping.
@MainActor
enum TelevisionCLI {
    private final class Completion { var result: Result<Void, XiaomiTVFailure>? }

    static func run(_ arguments: [String]) -> Int32 {
        guard let verb = arguments.first,
              ["status", "volume-up", "volume-down", "standby", "wake", "off", "power-menu", "up", "down", "left", "right", "ok", "back"].contains(verb),
              arguments.count == 1 || (arguments.count == 3 && arguments[1] == "--config") else {
            print("用法：miremote --tv status|volume-up|volume-down|standby|wake|off|power-menu|up|down|left|right|ok|back [--config 路径]")
            return 2
        }
        let path = arguments.count == 3 ? arguments[2] : nil
        let client = XiaomiTVController.shared
        client.configure(ConfigStore.loadIfExists(at: path)?.television)
        guard client.isConfigured else {
            print("请先在 MiRemote 通用设置中配置并启用小米电视。")
            return 1
        }
        let completion = Completion()
        if verb == "status" {
            client.checkConnection { completion.result = $0 }
        } else {
            let commands: [String: XiaomiTVCommand] = ["volume-up": .volumeUp, "volume-down": .volumeDown,
                "standby": .sleep, "wake": .wake, "off": .powerMenu, "power-menu": .powerMenu,
                "up": .up, "down": .down, "left": .left, "right": .right, "ok": .ok, "back": .back]
            guard let command = commands[verb] else { return 2 }
            client.perform(command) { completion.result = $0 }
        }
        let keepAlive = Timer(timeInterval: 0.05, repeats: true) { _ in }
        RunLoop.main.add(keepAlive, forMode: .default)
        let deadline = Date(timeIntervalSinceNow: 6)
        while completion.result == nil, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        keepAlive.invalidate()
        let result = completion.result
        client.stop()
        switch result {
        case .success:
            if verb == "off" || verb == "power-menu" {
                print("电视电源菜单指令已送达；请在电视上选择“关机”并确认。这不代表电视已经关机。")
            } else {
                print(verb == "status" ? "电视本地控制服务可达；这不代表屏幕开关状态。" : "电视已确认收到按键；实际结果请查看电视。")
            }
            return 0
        case .failure(let failure): print(failure.message); return 1
        case nil: print("等待电视确认超时；不会自动重发指令。"); return 1
        }
    }
}
