import Foundation
import AppKit

// M5：把原 main.swift 的接线逻辑抽成可复用的服务容器，
// CLI 模式与 GUI 模式共用同一套接线，不复制两份。

func ts() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

func log(_ msg: String) {
    FileHandle.standardError.write("[\(ts())] \(msg)\n".data(using: .utf8)!)
}

// MARK: - 配置读写（ConfigStore：UI 与 CLI 共用，路径可注入便于自测）

enum ConfigStore {
    /// 默认配置文件 URL（~/Library/Application Support/MiRemote/config.json）
    static func defaultURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MiRemote")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    /// 读配置；解析失败返回 nil（调用方决定回退策略，原文件保留未动）。
    static func load(from url: URL) -> MappingConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MappingConfig.self, from: data)
    }

    /// 只读加载（文件不存在或解析失败返回 nil，绝不创建文件）。
    /// 启动早期读 settings（遥控器 VID/PID、声卡名等）用——语音-only 模式不应因此落盘配置。
    static func loadIfExists(at path: String?) -> MappingConfig? {
        load(from: path.map { URL(fileURLWithPath: $0) } ?? defaultURL())
    }

    /// 写配置（pretty + sortedKeys，便于用户手改与 diff）。
    @discardableResult
    static func save(_ config: MappingConfig, to url: URL) -> Bool {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(config) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            log("配置写入失败: \(error)")
            return false
        }
    }
}

func loadOrCreateConfig(at path: String? = nil) -> MappingConfig {
    let url = path.map { URL(fileURLWithPath: $0) } ?? ConfigStore.defaultURL()
    if FileManager.default.fileExists(atPath: url.path) {
        if let loaded = ConfigStore.load(from: url) {
            let cfg = migrateConfigIfNeeded(loaded)
            if cfg.version != loaded.version, ConfigStore.save(cfg, to: url) {
                log("配置已升级到 v\(cfg.version)，已补齐内置 Profile（用户已有绑定保持不变）")
            }
            log("配置已加载: \(url.path)")
            return cfg
        }
        // Action 严格解码：未知 type/缺字段会走到这里。明确告知回退，绝不静默。
        log("配置解析失败，使用默认配置（原文件保留未动）: \(url.path)")
        return defaultConfig()   // 不覆盖用户的问题文件，便于修复
    }
    let cfg = defaultConfig()
    if ConfigStore.save(cfg, to: url) {
        log("已生成默认配置: \(url.path)")
    }
    return cfg
}

/// 分阶段迁移；每一阶段只执行一次，用户日后主动删除的 Profile 不会被补回。
func migrateConfigIfNeeded(_ input: MappingConfig) -> MappingConfig {
    guard input.version < MappingConfig.currentVersion else { return input }
    var cfg = input
    if cfg.version < 2 {
        if cfg.profiles["global"] == nil { cfg.profiles["global"] = [:] }
        for preset in Presets.all { Presets.apply(preset, to: &cfg) }
        // 导航交互的明确入口：菜单键点按开关导航模式。
        var menu = cfg.profiles["global"]?["menu"] ?? KeyBinding()
        menu.tap = .layerToggle(3)
        cfg.profiles["global"]?["menu"] = menu
        if cfg.settings.doubleMs < 150 { cfg.settings.doubleMs = 250 }
        cfg.version = 2
    }
    if cfg.version < 3 {
        var rules = cfg.voiceProfiles ?? [:]
        if rules["global"] == nil { rules["global"] = VoiceTriggerRule() }
        cfg.voiceProfiles = rules
        cfg.version = 3
    }
    if cfg.version < 4 {
        migrateToMentalModelV2(&cfg)
        cfg.version = 4
    }
    if cfg.version < 5 {
        // Home 双击不能连续执行两次“显示桌面”（结果是一来一回）；
        // 为双击设置独立语义后，MappingEngine 会在双击窗口内决断单/双击。
        var g = cfg.profiles["global"] ?? [:]
        var home = g["home"] ?? KeyBinding()
        home.double = .system("mission_control")
        g["home"] = home
        cfg.profiles["global"] = g
        cfg.version = 5
    }
    if cfg.version < 6 {
        // 支持 App 的预设曾把 Home/菜单基础槽改成聚焦、地址栏、字幕等语义，
        // 造成同一实体键随 App 变义。将有用的 App 专属动作搬到 TV 控制模式（层2），
        // 基础态回归 global；只处理内置支持 App，不动用户自建 Profile。
        let supported = Set(Presets.all.compactMap(\.bundleID))
        for profileName in supported {
            guard var profile = cfg.profiles[profileName] else { continue }
            for key in ["home", "menu"] {
                guard var binding = profile[key] else { continue }
                var layers = binding.layers ?? [:]
                if layers["2"] == nil {
                    if key == "home", let tap = binding.tap {
                        layers["2"] = tap
                    } else if key == "menu" {
                        // 旧媒体/演示预设的真正功能放在 hold；tap=导航层开关丢弃。
                        if let hold = binding.hold {
                            layers["2"] = hold
                        } else if let tap = binding.tap, tap != .layerToggle(3) {
                            layers["2"] = tap
                        }
                    }
                }
                binding.tap = nil
                binding.hold = nil
                binding.double = nil
                binding.layers = layers.isEmpty ? nil : layers
                profile[key] = binding
            }
            cfg.profiles[profileName] = profile
        }
        cfg.version = 6
    }
    if cfg.version < 7 {
        // Home 单按直接进入调度中心；移除双击，保证松开即触发、没有双击等待。
        var g = cfg.profiles["global"] ?? [:]
        var home = g["home"] ?? KeyBinding()
        home.tap = .system("mission_control")
        home.double = nil
        g["home"] = home
        cfg.profiles["global"] = g
        cfg.version = 7
    }
    if cfg.version < 8 {
        // v8：飞书聊天与会议是同一个 App，旧「飞书会议」预设把 tv.tap 占成静音，
        // 槽级覆盖直接盖掉 global 的「TV=进/出 App 控制模式」——结果是飞书里
        // 按 TV 只发静音、进不了控制模式，连带控制模式 HUD/提示条也永远不出现。
        // 这里把 TV 归还给控制模式，静音搬进控制模式的菜单键。
        // 只回收「值仍等于老预设」的那一条，用户改成别的一律不动。
        let bundle = "com.electron.lark"
        let legacyMute = Action.keyStroke(key: "d", mods: ["left_option", "left_shift"])
        if var profile = cfg.profiles[bundle], profile["tv"]?.tap == legacyMute {
            var tv = profile["tv"] ?? KeyBinding()
            tv.tap = nil
            profile["tv"] = tv
            var menu = profile["menu"] ?? KeyBinding()
            var layers = menu.layers ?? [:]
            if layers["2"] == nil { layers["2"] = legacyMute }   // 用户已占用则不动
            menu.layers = layers
            profile["menu"] = menu
            cfg.profiles[bundle] = profile
        }
        // 合并后的飞书预设按 slot 级补齐（force=false，不覆盖用户已设的槽位）。
        Presets.apply(Presets.feishu, to: &cfg)
        cfg.version = 8
    }
    if cfg.version < 9 {
        // Only the previous semantic Codex preset's Escape slot is upgraded.
        // Preserve custom profiles, every other back slot, and global gestures.
        let bundle = "com.openai.codex"
        if var profile = cfg.profiles[bundle],
           profile["back"]?.tap == .keyStroke(key: "escape", mods: []),
           profile["back"]?.overrideBase == true,
           Presets.codexContextActions.allSatisfy({ key, action in profile[key.rawValue]?.tap == action }) {
            profile["back"]?.tap = .system("codex_context_back")
            cfg.profiles[bundle] = profile
        }
        cfg.version = 9
    }
    return cfg
}

/// v4：按键心智模型 v2（DESIGN §3.1b）。系统导航键（Home/菜单/TV）的 base 槽位
/// 是心智模型的骨架，强制改写到 v2 语义；用户其余自定义（层内/手势/per-app）保留。
func migrateToMentalModelV2(_ cfg: inout MappingConfig) {
    var g = cfg.profiles["global"] ?? [:]

    var home = g["home"] ?? KeyBinding()
    home.tap = .system("mission_control")       // 单按立即进入调度中心
    home.hold = .overlay("tutorial")            // 当前 App 映射教程浮层
    home.double = nil
    g["home"] = home

    var menu = g["menu"] ?? KeyBinding()
    menu.tap = .overlay("window_picker")        // 窗口选择器浮层
    menu.hold = .overlay("system_menu")         // 完整系统功能菜单浮层
    menu.double = nil
    g["menu"] = menu

    var tv = g["tv"] ?? KeyBinding()
    tv.tap = .layerToggle(2)                    // 进/出 App 控制模式（层2 + HUD）
    tv.hold = .overlay("app_wheel")             // App 轮盘（停留式，DESIGN §3.1b）
    tv.double = nil                             // v2 双击不定义（TV 双击切层已被控制模式取代）
    // 层2 内 TV 不再直选数字：留空让 tap 回退 layerToggle(2)，保证「再按 TV 退出模式」。
    tv.layers?.removeValue(forKey: "2")
    g["tv"] = tv

    // 零同按原则（DESIGN §3.1b）：默认不再注入 OK hold=瞬时层；用户已设的 hold 保留。

    // 层2 音量± 由旧「数字 2/3 直选」改为「切 Agent（上一个/下一个标签）」。
    var volUp = g["volUp"] ?? KeyBinding()
    if volUp.tap == nil { volUp.tap = .system("volume_up") }
    if volUp.layers?["2"] == .keyStroke(key: "2", mods: []) {
        volUp.layers?["2"] = .tabJump(dir: 1, index: nil)
    }
    g["volUp"] = volUp
    var volDown = g["volDown"] ?? KeyBinding()
    if volDown.tap == nil { volDown.tap = .system("volume_down") }
    if volDown.layers?["2"] == .keyStroke(key: "3", mods: []) {
        volDown.layers?["2"] = .tabJump(dir: -1, index: nil)
    }
    g["volDown"] = volDown

    cfg.profiles["global"] = g

    // per-app 清理：旧预设的「TV 双击=layer_toggle(2)」与旧 TV tap 接线让位给控制模式。
    let staleTvTaps: [Action] = [
        .keyStroke(key: "return", mods: ["left_cmd", "left_shift"]),   // 旧 Ghostty 预设
        .keyStroke(key: "1", mods: []),                                 // 旧 Codex/Claude 桌面预设
    ]
    for (name, profile) in cfg.profiles where name != "global" {
        guard var tvB = profile["tv"] else { continue }
        if tvB.double == .layerToggle(2) { tvB.double = nil }
        if let tap = tvB.tap, staleTvTaps.contains(tap) { tvB.tap = nil }
        var p = profile
        p["tv"] = tvB
        cfg.profiles[name] = p
    }
}

func defaultConfig() -> MappingConfig {
    // 默认配置 = 按键心智模型 v2（DESIGN §3.1b，2026-07-19 定稿）：
    //   内容操作：方向/OK/返回原生直通（引擎保护）。
    //   同级切换：音量± = 系统音量（跟键帽一致）；控制模式内 = 切 Agent/标签。
    //   系统导航：Home 单击=调度中心（左右切桌面）、长按=映射教程浮层；
    //             菜单单击=窗口选择器浮层、长按=系统功能菜单浮层。
    //   App 专用：TV 单击=进/出 App 控制模式（层2+HUD）、长按=App 轮盘浮层（停留式）。
    //   零同按组合：单手拇指操作，「按住 A 再按 B」（OK+方向手势、OK 长按瞬时层）
    //   不进默认配置；引擎能力保留，供高级用户自配。层1 数据保留但默认无入口。
    var cfg = MappingConfig()
    cfg.voiceProfiles = ["global": VoiceTriggerRule()]
    cfg.profiles["global"] = [
        "up":      KeyBinding(tap: .keyStroke(key: "up_arrow", mods: []),
                              layers: ["1": .system("volume_up")]),
        "down":    KeyBinding(tap: .keyStroke(key: "down_arrow", mods: []),
                              layers: ["1": .system("volume_down")]),
        "left":    KeyBinding(tap: .keyStroke(key: "left_arrow", mods: [])),
        "right":   KeyBinding(tap: .keyStroke(key: "right_arrow", mods: [])),
        "ok":      KeyBinding(tap: .keyStroke(key: "return", mods: [])),
        "back":    KeyBinding(tap: .keyStroke(key: "delete", mods: []),
                              layers: ["1": .system("previous_app")]),
        "menu":    KeyBinding(tap: .overlay("window_picker"),
                              hold: .overlay("system_menu"),
                              layers: ["1": .system("next_app")]),
        "home":    KeyBinding(tap: .system("mission_control"),
                              hold: .overlay("tutorial"),
                              double: nil,
                              layers: ["1": .system("mission_control")]),
        // TV 单击 = 进/出 App 控制模式（层2；HUD 由 GUI 随层变化显示）；
        // 长按 = App 轮盘浮层（停留式：弹出后可松手，方向选、OK/再按 TV 确认、
        // 返回取消、3s 超时自关；浮层打开期间按键走 uiCapture 路由，UI 侧实现）。
        "tv":      KeyBinding(tap: .layerToggle(2),
                              hold: .overlay("app_wheel"),
                              layers: ["1": .system("app_expose")]),
        // 电源长按 = 鼠标模式开关（P4：给 mouse_mode 一个开箱可达的默认入口；
        // 方向键移动指针、OK=左键。tap 保持键帽语义的显示器睡眠）。
        "power":   KeyBinding(tap: .system("display_sleep"), hold: .mouseMode),
        "volUp":   KeyBinding(tap: .system("volume_up")),
        "volDown": KeyBinding(tap: .system("volume_down")),
        "voice":   KeyBinding(tap: .voice),
    ]
    // 内置预设并入默认配置：App 控制模式绑定(层2)/多agent跳转 进 global，媒体/会议进 per-app overlay。
    // 不覆盖上面已设的槽位（apply 默认 force=false）。
    for p in Presets.all { Presets.apply(p, to: &cfg) }
    return cfg
}

// MARK: - 电平计（GUI 语音页实时电平表的数据源）

final class LevelMeterSink: PCMSink, @unchecked Sendable {
    /// 每批样本的 RMS（0…1），在 ATVV 队列上回调，消费方自行切主线程。
    var onLevel: ((Float) -> Void)?

    func streamStarted(sampleRate: Double) { onLevel?(0) }
    func write(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        var acc = 0.0
        for s in samples { let d = Double(s); acc += d * d }
        let rms = (acc / Double(samples.count)).squareRoot() / 32768.0
        onLevel?(Float(min(1, rms)))
    }
    func streamStopped() { onLevel?(0) }
}

// MARK: - 语音链路（M1）

/// 纯门控：off 会丢弃待确认的长按；重新启用后必须先等旧物理会话 STOP，再收新 START。
/// 不执行音频、输入设备或键盘操作，供生产链路与 self-check 共用。
struct VoiceDeliveryGate {
    private(set) var enabled = true
    private var physicalSession = false
    private var acceptsFrames = false
    private var pressGate = VoicePressGate()

    @discardableResult mutating func setEnabled(_ value: Bool) -> Bool {
        guard enabled != value else { return false }
        enabled = value
        if !value { cancelPending() }
        return true
    }

    mutating func begin(nowNs: UInt64, holdMs: Int, actionsEnabled: Bool) {
        guard !physicalSession else { return } // 重复 START 不重置已开始/待确认的会话。
        physicalSession = true
        acceptsFrames = enabled
        pressGate.begin(nowNs: nowNs, holdMs: holdMs,
                        enabled: enabled && (holdMs == 0 || actionsEnabled))
    }

    mutating func receive(_ frame: VoicePressGate.Frame, nowNs: UInt64) -> VoicePressGate.Delivery? {
        guard enabled, acceptsFrames else { return nil }
        return pressGate.receive(frame, nowNs: nowNs)
    }

    @discardableResult mutating func end() -> Bool {
        physicalSession = false
        acceptsFrames = false
        return pressGate.end()
    }

    mutating func cancelPending() {
        acceptsFrames = false
        _ = pressGate.end()
    }

    static func selfCheck() -> Bool {
        let frame = VoicePressGate.Frame(data: Data([1]), sync: nil)
        var gate = VoiceDeliveryGate()
        // CLI 默认允许纯音频桥（没有 IME/切输入动作）。重复 START 不重新开始。
        gate.begin(nowNs: 0, holdMs: 0, actionsEnabled: false)
        guard case .begin? = gate.receive(frame, nowNs: 1) else { return false }
        gate.begin(nowNs: 2, holdMs: 0, actionsEnabled: false)
        guard case .frames? = gate.receive(frame, nowNs: 3) else { return false }
        guard gate.setEnabled(false), gate.receive(frame, nowNs: 4) == nil else { return false }
        // off→on 不能续播同一物理会话；重复 START 也不能绕过。
        gate.setEnabled(true)
        gate.begin(nowNs: 5, holdMs: 0, actionsEnabled: true)
        guard gate.receive(frame, nowNs: 6) == nil, !gate.end() else { return false }
        // off 时到达的 START/音频全部丢弃，开关本身不会补发 START。
        gate.setEnabled(false)
        gate.begin(nowNs: 7, holdMs: 0, actionsEnabled: true)
        guard gate.receive(frame, nowNs: 8) == nil else { return false }
        gate.setEnabled(true)
        guard gate.receive(frame, nowNs: 9) == nil, !gate.end() else { return false }
        // 长按尚未到阈值时关闭，即使过阈值/重新启用也不能交付旧缓存。
        gate.begin(nowNs: 10, holdMs: 600, actionsEnabled: true)
        guard gate.receive(frame, nowNs: 100) == nil else { return false }
        gate.setEnabled(false)
        guard gate.receive(frame, nowNs: 700_000_010) == nil else { return false }
        gate.setEnabled(true)
        guard gate.receive(frame, nowNs: 800_000_010) == nil, !gate.end() else { return false }
        gate.begin(nowNs: 900_000_010, holdMs: 600, actionsEnabled: true)
        guard case .begin(let frames)? = gate.receive(frame, nowNs: 1_500_000_010),
              frames.count == 1, gate.end() else { return false }
        return gate.receive(frame, nowNs: 1_600_000_010) == nil
    }
}

final class VoiceBridgeApp: ATVVBridgeDelegate {
    private let decoder = ADPCMDecoder()
    private let post: PCMPostprocessor
    private let sink: PCMSink
    private let verbose: Bool

    /// 配置位：GUI 主线程写、ATVV 队列读——锁保护（Bool 竞态读写是未定义行为，
    /// 且会话中途切换会导致 stop 侧清理判断错位，见下方会话锁存）。
    private let cfgLock = NSLock()
    /// GUI 开关与 ATVV 回调串行化。不得持锁调用会等待主线程 TIS 的 shutdown。
    private let sessionLock = NSLock()
    private var pendingVoiceResolution: UUID?
    private var pendingVoiceFrames: [VoicePressGate.Frame] = []
    private var pendingVoiceStopped = false
    private var pendingVoiceOverflow = false
    private var deliveryGate = VoiceDeliveryGate()
    /// 旧 Codex 两按听写隔离 ATVV；专用按住动作单独缓冲／交付 PCM。
    private var suppressPhysicalSession = false
    private var physicalVoiceInProgress = false
    private var codexPhysicalSession = false
    private var codexPCM = RemotePCMHoldGate()
    /// 松手后仍可能等待最终结果；断连也必须取消这个 token。
    private var codexRecognitionToken: UInt64?
    private var codexReleaseWork: DispatchWorkItem?
    /// Raw IOHID evidence is independent of BLE STOP and mapping eligibility.
    private var rawVoiceHIDDown = false
    private var rawVoicePressGeneration: UInt64 = 0
    private var codexHoldPressGeneration: UInt64?
    /// Physical press identity for remotes using host-requested capture. Bridge callbacks
    /// enqueue on its BLE queue and must not synchronously call back into this service.
    var onPhysicalVoiceKey: ((_ held: Bool, _ generation: UInt64) -> Void)?
    var authorizeVoiceContinuation: ((UInt64) -> Void)?
    var revokeVoiceContinuation: ((UInt64) -> Void)?
    private var cleanupCount = 0
    private var _routeRemoteAudio: Bool
    private var _switchInput: Bool
    private var _doubao: Bool
    /// CLI 默认保留音频桥；GUI off 必须显式关闭此总门。
    var voiceEnabled: Bool {
        get { sessionLock.lock(); defer { sessionLock.unlock() }; return deliveryGate.enabled }
        set {
            sessionLock.lock()
            guard deliveryGate.setEnabled(newValue), !newValue else {
                sessionLock.unlock()
                return
            }
            let restoreInput = prepareForceEndLocked()
            sessionLock.unlock()
            completeForceEnd(restoreInput: restoreInput)
        }
    }
    /// 三模式原子切换；Mac 麦克风与关闭模式完全绕过远端 PCM/BlackHole。
    func configureVoiceMode(routeRemoteAudio: Bool, switchInput: Bool, doubao: Bool) {
        cfgLock.lock()
        _routeRemoteAudio = routeRemoteAudio
        _switchInput = switchInput
        _doubao = doubao
        cfgLock.unlock()
    }

    /// 会话锁存（cfgLock 保护）：一次语音会话实际执行过的操作。stop/结束只按锁存
    /// 状态对称清理——会话中把模式切到 off/macMic 不能跳过已做操作的回滚。
    private var sessionActive = false
    private var sessionRoutedRemoteAudio = false
    private var sessionSwitchedMic = false
    private var sessionDoubao = false
    private var _minimumHoldMs = 0
    var minimumHoldMs: Int {
        get { cfgLock.lock(); defer { cfgLock.unlock() }; return _minimumHoldMs }
        set { cfgLock.lock(); _minimumHoldMs = newValue; cfgLock.unlock() }
    }

    /// GUI 状态反馈钩子（ATVV 队列回调）。
    var onConnection: ((Bool, String?) -> Void)?
    var onVoiceActive: ((Bool) -> Void)?
    /// GUI 注入：在一次语音会话开始时，按最近的前台 App 解析快捷键。
    var resolveTriggerConfig: (() -> VoiceTriggerConfig)?
    /// 仅查询锁保护的配置／前台快照，不得在 ATVV 队列读取 AppKit UI。
    var shouldSuppressPhysicalVoice: (() -> Bool)?
    var shouldUseCodexPhysicalHold: (() -> Bool)?
    /// Live targeting is resolved on main before acquiring sessionLock, shared
    /// with HID's per-press claim so BLE/HID arrival order cannot change routes.
    var shouldReserveDouyinPhysicalVoice: (() -> Bool)?
    var reserveDouyinPhysicalVoice: (() -> Bool)?
    var releaseDouyinPhysicalVoice: (() -> Void)?
    var resetDouyinPhysicalVoice: (() -> Void)?

    func receiveRawVoiceHID(_ event: ButtonEvent) {
        guard event.key == .voice else { return }
        sessionLock.lock()
        if event.isDown != rawVoiceHIDDown {
            if event.isDown { rawVoicePressGeneration &+= 1 }
            onPhysicalVoiceKey?(event.isDown, rawVoicePressGeneration)
        }
        rawVoiceHIDDown = event.isDown
        if !event.isDown { codexHoldPressGeneration = nil }
        let revokeToken = event.isDown ? nil : codexRecognitionToken
        sessionLock.unlock()
        if let revokeToken { revokeVoiceContinuation?(revokeToken) }
    }

    func resetRawVoiceHID() {
        sessionLock.lock()
        if rawVoiceHIDDown { onPhysicalVoiceKey?(false, rawVoicePressGeneration) }
        rawVoiceHIDDown = false
        codexHoldPressGeneration = nil
        let token = codexRecognitionToken
        sessionLock.unlock()
        if let token { revokeVoiceContinuation?(token) }
    }

    /// Main has freshly validated the original dictation target. A BLE START or
    /// configured binding alone cannot issue a lease without a raw HID down.
    func renewVoiceContinuation(token: UInt64) {
        sessionLock.lock()
        let allowed = rawVoiceHIDDown && codexHoldPressGeneration == rawVoicePressGeneration
            && codexRecognitionToken == token && cleanupCount == 0
        sessionLock.unlock()
        if allowed { authorizeVoiceContinuation?(token) }
    }

    static func voiceContinuationSelfCheck() -> Bool {
        let app = VoiceBridgeApp(outputName: nil, wavPath: nil, gainDB: 0, verbose: false,
                                 switchInput: false, doubao: false, sinkOverride: LevelMeterSink())
        var physical: [Int] = []
        app.onPhysicalVoiceKey = { held, generation in physical.append((held ? 1 : -1) * Int(generation)) }
        var authorized: [UInt64] = []
        var revoked: [UInt64] = []
        app.authorizeVoiceContinuation = { authorized.append($0) }
        app.revokeVoiceContinuation = { revoked.append($0) }
        app.shouldUseCodexPhysicalHold = { true }
        app.atvvVoiceStarted()
        app.setCodexPhysicalHold(active: true, token: 42)
        app.renewVoiceContinuation(token: 42)
        guard authorized.isEmpty else { return false } // BLE alone is insufficient.
        app.receiveRawVoiceHID(.init(key: .voice, isDown: true, timeNs: 1))
        app.renewVoiceContinuation(token: 42)
        guard authorized.isEmpty else { return false } // old token cannot claim a new press.
        app.setCodexPhysicalHold(active: true, token: 42)
        app.renewVoiceContinuation(token: 41)
        app.renewVoiceContinuation(token: 42)
        guard authorized == [42] else { return false }
        // Each segment resets both ADPCM and smoothing history, preserving the
        // logical hold and gate token. No hardware/audio/input action is invoked.
        let frame = VoicePressGate.Frame(data: Data([0x11]), sync: nil)
        for _ in 0..<3 {
            app.decoder.reset(predictor: 1234, stepIndex: 50)
            _ = app.post.process([3000, 4000])
            app.atvvVoiceSegmentStarted()
            guard app.decoder.decode(frame.data) == ADPCMDecoder().decode(frame.data),
                  app.post.process([100, 200]) == [100, 200],
                  app.codexPCM.receive(frame)?.token == 42 else { return false }
        }
        app.receiveRawVoiceHID(.init(key: .voice, isDown: false, timeNs: 2))
        app.renewVoiceContinuation(token: 42)
        guard revoked == [42], authorized == [42],
              app.codexPCM.receive(frame)?.token == 42 else { return false } // tail stays open.
        app.receiveRawVoiceHID(.init(key: .voice, isDown: true, timeNs: 3))
        app.renewVoiceContinuation(token: 42)
        guard authorized == [42] else { return false }
        app.resetRawVoiceHID()
        app.renewVoiceContinuation(token: 42)
        guard revoked == [42, 42], authorized == [42] else { return false }
        app.setCodexPhysicalHold(active: false, token: 43)
        return revoked == [42, 42, 42] && app.codexPCM.receive(frame) == nil
            && physical == [1, -1, 2, -2]
    }

    /// Codex 即将接管触发键；保留其 BLE 预缓存，作废通用会话的所有延迟动作。
    /// 调用者为主线程；shutdown 可能访问 TIS，必须在 sessionLock 外执行。
    func prepareCodexPhysicalHold() {
        sessionLock.lock()
        restoreGeneration &+= 1
        restoreWork?.cancel()
        restoreWork = nil
        pendingVoiceTriggerEnd = false
        let restoreInput = inputNeedsRestore
        inputNeedsRestore = false
        sessionLock.unlock()
        VoiceTrigger.shutdown()
        if restoreInput { DefaultInput.restore() }
    }

    /// 只有映射确认的长按可激活；音频桥开关 off 不影响此独立且明确配置的 Codex 动作。
    func setCodexPhysicalHold(active: Bool, token: UInt64) {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        guard active else {
            if let press = codexHoldPressGeneration, rawVoiceHIDDown && press == rawVoicePressGeneration {
                onPhysicalVoiceKey?(false, press)
            }
            codexHoldPressGeneration = nil
            if let token = codexRecognitionToken { revokeVoiceContinuation?(token) }
            codexReleaseWork?.cancel()
            codexReleaseWork = nil
            codexPCM.deactivate()
            if codexRecognitionToken != token { codexRecognitionToken = nil }
            return
        }
        codexRecognitionToken = token
        codexHoldPressGeneration = rawVoiceHIDDown ? rawVoicePressGeneration : nil
        if let delivery = codexPCM.activate(token: token) {
            for frame in delivery.frames { processCodexFrame(frame, token: delivery.token) }
        }
    }

    /// HID up 与 BLE 尾包走不同队列。等待 STOP；缺失 STOP 时最多补收 250ms，
    /// 然后在已投递的主队列 PCM 后插入结束标记，不能先递增识别代次。
    func releaseCodexPhysicalHold(token: UInt64) {
        revokeVoiceContinuation?(token)
        sessionLock.lock()
        defer { sessionLock.unlock() }
        codexReleaseWork?.cancel()
        guard codexRecognitionToken == token, codexPhysicalSession else {
            DispatchQueue.main.async { CodexDictation.endRemoteTransport(token: token, reason: "hid-no-stream") }
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.sessionLock.lock()
            defer { self.sessionLock.unlock() }
            guard self.codexRecognitionToken == token else { return }
            self.codexReleaseWork = nil
            self.releaseDouyinPhysicalVoice?()
            _ = self.codexPCM.end()
            self.codexPhysicalSession = false
            self.physicalVoiceInProgress = false
            DispatchQueue.main.async { CodexDictation.endRemoteTransport(token: token, reason: "hid-release-timeout-250ms") }
        }
        codexReleaseWork = work
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
    }

    private func processCodexFrame(_ frame: VoicePressGate.Frame, token: UInt64) {
        if let sync = frame.sync { decoder.reset(predictor: sync.predictor, stepIndex: sync.stepIndex) }
        let samples = post.process(decoder.decode(frame.data))
        DispatchQueue.main.async { CodexDictation.receiveRemotePCM(samples, token: token) }
    }

    /// 语音会话期间默认麦克风的切换目标（前缀匹配；默认 BlackHole，配置可换）。
    private let micDeviceName: String

    init(outputName: String?, wavPath: String?, gainDB: Double, verbose: Bool,
         switchInput: Bool, doubao: Bool, micDeviceName: String = "BlackHole",
         extraSink: PCMSink? = nil, sinkOverride: PCMSink? = nil) {
        self.post = PCMPostprocessor(gainDB: gainDB)
        self.verbose = verbose
        self._routeRemoteAudio = true
        self._switchInput = switchInput
        self._doubao = doubao
        self.micDeviceName = micDeviceName
        if let sinkOverride {
            self.sink = sinkOverride
            return
        }
        var sinks: [PCMSink] = [AudioBridge(deviceName: outputName)]
        if let wavPath {
            sinks.append(WAVSink(url: URL(fileURLWithPath: wavPath)))
        }
        if let extraSink { sinks.append(extraSink) }
        self.sink = sinks.count == 1 ? sinks[0] : TeeSink(sinks)
    }

    func atvvLog(_ message: String) {
        if verbose { log(message) }
    }

    func atvvConnected(deviceName: String) {
        log("已连接: \(deviceName)")
        print("READY")
        onConnection?(true, deviceName)
    }

    func atvvDisconnected(error: String?) {
        // 断连是取消，必须先隔离 token，不能把 BLE 丢失当作正常松手提交。
        sessionLock.lock()
        let streamToken = codexPCM.end()
        let cancelledToken = codexRecognitionToken ?? streamToken
        codexRecognitionToken = nil
        sessionLock.unlock()
        if let cancelledToken {
            DispatchQueue.main.async { CodexDictation.cancelRemoteTransport(token: cancelledToken) }
        }
        atvvVoiceStopped() // 清理其余物理会话状态，避免重连后被旧锁存拦住。
        // 断连属于取消：作废在途 drain/延迟恢复，并立即对称释放通用触发键。
        forceEndSessionIfActive()
        log("断开连接\(error.map { ": \($0)" } ?? "")（自动重连中）")
        onConnection?(false, nil)
    }

    func atvvVoiceStarted() {
        guard shouldReserveDouyinPhysicalVoice?() == true, let reserveDouyinPhysicalVoice else {
            sessionLock.lock(); defer { sessionLock.unlock() }
            startPhysicalVoiceLocked(douyinOwned: false)
            return
        }
        // Never synchronously wait for main here: stopAndWait() drains this BLE
        // queue from main. Buffer bounded PCM until the same HID claim is known.
        sessionLock.lock()
        if physicalVoiceInProgress || (pendingVoiceResolution != nil && !pendingVoiceStopped) {
            sessionLock.unlock()
            return
        }
        let ticket = UUID()
        pendingVoiceResolution = ticket
        pendingVoiceFrames.removeAll()
        pendingVoiceStopped = false
        pendingVoiceOverflow = false
        sessionLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sessionLock.lock()
            let valid = self.pendingVoiceResolution == ticket
            self.sessionLock.unlock()
            guard valid else { return }
            let owned = reserveDouyinPhysicalVoice()
            self.sessionLock.lock()
            defer { self.sessionLock.unlock() }
            guard self.pendingVoiceResolution == ticket else {
                self.releaseDouyinPhysicalVoice?()
                return
            }
            let frames = self.pendingVoiceFrames
            let stopped = self.pendingVoiceStopped
            let overflow = self.pendingVoiceOverflow
            self.pendingVoiceResolution = nil
            self.pendingVoiceFrames.removeAll()
            if overflow {
                // Losing the prefix invalidates the entire physical stream.
                self.physicalVoiceInProgress = true
                self.suppressPhysicalSession = true
            } else {
                self.startPhysicalVoiceLocked(douyinOwned: owned)
                for frame in frames { self.processAudioFrameLocked(frame.data, sync: frame.sync) }
            }
            if stopped { self.stopPhysicalVoiceLocked() }
        }
    }

    private func startPhysicalVoiceLocked(douyinOwned: Bool) {
        guard !physicalVoiceInProgress else { return }
        physicalVoiceInProgress = true
        if douyinOwned || shouldUseCodexPhysicalHold?() == true {
            codexPhysicalSession = true
            codexPCM.begin()
            decoder.reset(predictor: 0, stepIndex: 0)
            post.reset()
            return
        }
        if shouldSuppressPhysicalVoice?() == true {
            suppressPhysicalSession = true
            return
        }
        let delay = minimumHoldMs
        cfgLock.lock()
        let actionsEnabled = _switchInput || _doubao
        cfgLock.unlock()
        deliveryGate.begin(nowNs: DispatchTime.now().uptimeNanoseconds, holdMs: delay,
                           actionsEnabled: actionsEnabled)
        if cleanupCount > 0 { deliveryGate.cancelPending() }
    }

    private func beginVoiceSession() {
        log("语音开始")
        onVoiceActive?(true)
        restoreGeneration &+= 1
        restoreWork?.cancel()
        restoreWork = nil
        if pendingVoiceTriggerEnd {
            // 上个流仍在排空时开始新流：先关闭旧 tap/double 会话；hold 由 begin 合并。
            pendingVoiceTriggerEnd = false
            VoiceTrigger.end()
        }
        // 会话锁存：本会话按此刻的配置执行并记录实际做过的操作，
        // 结束/stop 只按锁存值对称回滚（会话中途改配置不影响本会话清理）。
        let (wantAudio, wantSwitch, wantDoubao): (Bool, Bool, Bool) = {
            cfgLock.lock(); defer { cfgLock.unlock() }
            sessionActive = true
            sessionRoutedRemoteAudio = _routeRemoteAudio
            sessionSwitchedMic = false   // 真正切换后才置位，见 atvvAudioFrame 的 pendingMicSwitch 分支
            sessionDoubao = _doubao
            return (_routeRemoteAudio, _switchInput, _doubao)
        }()
        if !wantAudio, inputNeedsRestore {
            // 新的 Mac 麦克风会话不能沿用上个远端会话尚待恢复的 BlackHole 输入。
            DefaultInput.restore()
            inputNeedsRestore = false
        }
        // 抖动幽灵会话（有 START/STOP 但零音频帧）不做任何有副作用的操作：
        // 麦克风切换和豆包触发一样，等第一个真实音频帧到达再执行——否则遥控器
        // BLE START/STOP 每次抖动都会拿系统默认输入设备开刀一次，Bluetooth 耳机
        // 据此重新协商音频 profile，每次都炸出一下可闻的杂音。
        pendingMicSwitch = wantAudio && wantSwitch
        pendingTrigger = wantDoubao
        cfgLock.lock(); triggered = false; cfgLock.unlock()
        if wantAudio {
            decoder.reset(predictor: 0, stepIndex: 0)
            post.reset()
            sink.streamStarted(sampleRate: 16000)
        }
    }

    private var restoreWork: DispatchWorkItem?
    private var restoreGeneration: UInt64 = 0
    /// 即使新会话取消了旧延迟恢复，off 收尾仍须记得恢复曾经切过的输入设备。
    private var inputNeedsRestore = false
    private var pendingMicSwitch = false
    private var pendingTrigger = false
    private var triggered = false
    /// 音频排空前触发键仍属于上个会话；新会话必须先对称收尾再 begin。
    private var pendingVoiceTriggerEnd = false

    func atvvVoiceStopped() {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if pendingVoiceResolution != nil {
            pendingVoiceStopped = true
            return
        }
        stopPhysicalVoiceLocked()
    }

    func atvvVoiceSegmentStarted() {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        guard physicalVoiceInProgress, codexPhysicalSession, cleanupCount == 0 else { return }
        decoder.reset(predictor: 0, stepIndex: 0)
        post.reset()
    }

    func atvvVoiceContinuationFailed(reason: String) {
        sessionLock.lock()
        let token = rawVoiceHIDDown && codexHoldPressGeneration == rawVoicePressGeneration
            ? codexRecognitionToken : nil
        sessionLock.unlock()
        if let token {
            DispatchQueue.main.async { CodexDictation.remoteContinuationFailed(token: token, reason: reason) }
        }
    }

    private func stopPhysicalVoiceLocked() {
        releaseDouyinPhysicalVoice?()
        physicalVoiceInProgress = false
        if codexPhysicalSession {
            codexPhysicalSession = false
            codexReleaseWork?.cancel()
            codexReleaseWork = nil
            // BLE STOP 是兜底收音边界；映射正常 release 同样会执行 endPhysicalHold。
            if let token = codexPCM.end() {
                DispatchQueue.main.async { CodexDictation.endRemoteTransport(token: token, reason: "atvv-stop") }
            }
            return
        }
        if suppressPhysicalSession {
            suppressPhysicalSession = false
            return
        }
        guard deliveryGate.end() else { return }
        log("语音结束")
        onVoiceActive?(false)
        pendingMicSwitch = false
        pendingTrigger = false
        let (didAudio, didSwitch, didDoubao, didTrigger): (Bool, Bool, Bool, Bool) = {
            cfgLock.lock(); defer { cfgLock.unlock() }
            let r = (sessionRoutedRemoteAudio, sessionSwitchedMic, sessionDoubao, triggered)
            sessionActive = false
            sessionRoutedRemoteAudio = false
            sessionSwitchedMic = false
            sessionDoubao = false
            return r
        }()
        let shouldEndTrigger = didDoubao && didTrigger
        restoreGeneration &+= 1
        let generation = restoreGeneration
        pendingVoiceTriggerEnd = shouldEndTrigger
        if didAudio {
            sink.streamStopped { [weak self] in
                // AudioBridge 的回调代表硬件队列已播完 PCM 与静音尾；不得按固定时长猜测。
                // 额外留 500ms 给输入法消费尾部；新流/取消会作废这整个回调。
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(shouldEndTrigger ? 500 : 0)) {
                    self?.finishVoiceTail(generation: generation, endTrigger: shouldEndTrigger,
                                          restoreInput: didSwitch)
                }
            }
        } else {
            // Mac 麦克风路径未启动 sink，无需等待任何远端音频。
            finishVoiceTailLocked(generation: generation, endTrigger: shouldEndTrigger,
                                  restoreInput: didSwitch)
        }
    }

    private func finishVoiceTail(generation: UInt64, endTrigger: Bool, restoreInput: Bool) {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        finishVoiceTailLocked(generation: generation, endTrigger: endTrigger, restoreInput: restoreInput)
    }

    /// 调用者持 sessionLock；检查与 VoiceTrigger.end 的入队不可被新 begin 插入。
    private func finishVoiceTailLocked(generation: UInt64, endTrigger: Bool, restoreInput: Bool) {
        guard generation == restoreGeneration, cleanupCount == 0 else { return }
        if endTrigger, pendingVoiceTriggerEnd {
            pendingVoiceTriggerEnd = false
            VoiceTrigger.end()
        }
        guard restoreInput else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.sessionLock.lock()
            defer { self.sessionLock.unlock() }
            guard generation == self.restoreGeneration, self.cleanupCount == 0 else { return }
            DefaultInput.restore()
            self.inputNeedsRestore = false
            self.restoreWork = nil
            log("默认麦克风已还原（音频排空后）")
        }
        restoreWork = work
        // VoiceTrigger 在实际 keyUp 后给 IME 4s 回填窗口；麦克风至少保留同等时间。
        DispatchQueue.global().asyncAfter(deadline: .now() + (endTrigger ? 4.5 : 0), execute: work)
    }

    /// 服务停止兜底：语音会话仍在进行时按锁存状态强制收尾
    ///（松开触发键、还原默认麦克风），防止 stop 后修饰键粘住/麦克风停在 BlackHole。
    func forceEndSessionIfActive() {
        sessionLock.lock()
        let restoreInput = prepareForceEndLocked()
        sessionLock.unlock()
        completeForceEnd(restoreInput: restoreInput)
    }

    /// 调用者持 sessionLock；先禁止交付，再清理所有本地会话状态。
    private func prepareForceEndLocked() -> Bool {
        cleanupCount += 1
        if rawVoiceHIDDown { onPhysicalVoiceKey?(false, rawVoicePressGeneration) }
        rawVoiceHIDDown = false
        codexHoldPressGeneration = nil
        pendingVoiceResolution = nil
        pendingVoiceFrames.removeAll()
        pendingVoiceStopped = false
        resetDouyinPhysicalVoice?()
        codexReleaseWork?.cancel()
        codexReleaseWork = nil
        let streamToken = codexPCM.end()
        if let token = codexRecognitionToken ?? streamToken {
            revokeVoiceContinuation?(token)
            DispatchQueue.main.async { CodexDictation.cancelRemoteTransport(token: token) }
        }
        codexRecognitionToken = nil
        deliveryGate.cancelPending()
        restoreGeneration &+= 1
        let hadPendingMicRestore = restoreWork != nil
        restoreWork?.cancel()
        restoreWork = nil
        pendingVoiceTriggerEnd = false
        pendingMicSwitch = false
        pendingTrigger = false
        let (active, didAudio, didSwitch): (Bool, Bool, Bool) = {
            cfgLock.lock(); defer { cfgLock.unlock() }
            let r = (sessionActive, sessionRoutedRemoteAudio, sessionSwitchedMic)
            sessionActive = false
            sessionRoutedRemoteAudio = false
            sessionSwitchedMic = false
            sessionDoubao = false
            return r
        }()
        if active {
            log("服务停止：语音会话仍在进行，强制收尾")
            onVoiceActive?(false)
            if didAudio { sink.streamStopped() }
        }
        return didSwitch || hadPendingMicRestore || inputNeedsRestore
    }

    private func completeForceEnd(restoreInput: Bool) {
        // shutdown 可能同步等待主线程 TIS，主线程也可能正在切换 GUI 开关：
        // 不持 sessionLock 等待。cleanupCount 在此期间阻止新 START/PCM 交付。
        VoiceTrigger.shutdown()
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if restoreInput {
            DefaultInput.restore()
            inputNeedsRestore = false
        }
        cleanupCount -= 1
    }

    func atvvAudioFrame(_ frame: Data, sync: (predictor: Int16, stepIndex: Int)?) {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if pendingVoiceResolution != nil {
            guard !pendingVoiceStopped, !pendingVoiceOverflow else { return }
            guard pendingVoiceFrames.count < 128, frame.count <= 4096 else {
                pendingVoiceFrames.removeAll()
                pendingVoiceOverflow = true
                return
            }
            pendingVoiceFrames.append(.init(data: frame, sync: sync))
            return
        }
        processAudioFrameLocked(frame, sync: sync)
    }

    private func processAudioFrameLocked(_ frame: Data, sync: (predictor: Int16, stepIndex: Int)?) {
        guard cleanupCount == 0, !suppressPhysicalSession else { return }
        if codexPhysicalSession {
            let packet = VoicePressGate.Frame(data: frame, sync: sync)
            if let delivery = codexPCM.receive(packet) {
                for frame in delivery.frames { processCodexFrame(frame, token: delivery.token) }
            }
            return
        }
        guard let delivery = deliveryGate.receive(.init(data: frame, sync: sync),
                                              nowNs: DispatchTime.now().uptimeNanoseconds) else { return }
        switch delivery {
        case .begin(let frames):
            beginVoiceSession()
            for frame in frames { processVoiceFrame(frame.data, sync: frame.sync) }
        case .frames(let frames):
            for frame in frames { processVoiceFrame(frame.data, sync: frame.sync) }
        }
    }

    private func processVoiceFrame(_ frame: Data, sync: (predictor: Int16, stepIndex: Int)?) {
        if pendingMicSwitch {
            pendingMicSwitch = false
            let engaged = DefaultInput.engage(deviceName: micDeviceName)
            if engaged { inputNeedsRestore = true }
            cfgLock.lock(); sessionSwitchedMic = engaged; cfgLock.unlock()
            log(engaged
                ? "默认麦克风 → \(micDeviceName)"
                : "切换默认麦克风失败（未找到 \(micDeviceName)*，未装虚拟声卡？语音出字不可用，按键功能不受影响）")
        }
        if pendingTrigger {
            pendingTrigger = false
            cfgLock.lock(); triggered = true; cfgLock.unlock()
            VoiceTrigger.begin(config: resolveTriggerConfig?())
        }
        cfgLock.lock()
        let shouldRouteAudio = sessionRoutedRemoteAudio
        cfgLock.unlock()
        guard shouldRouteAudio else { return }
        if let sync {
            decoder.reset(predictor: sync.predictor, stepIndex: sync.stepIndex)
        }
        sink.write(post.process(decoder.decode(frame)))
    }
}

// MARK: - M2 按键映射接线

final class KeyMapperApp: HIDEngineDelegate, MappingEngineDelegate {
    let runner = ActionRunner()
    var engine: MappingEngine!
    let verbose: Bool
    private var genericVoiceHIDEnabled: Bool
    private var voiceHIDWasForwarded = false

    /// GUI 状态反馈钩子。
    var onLayerChanged: ((Int) -> Void)?
    var onSeizeState: ((Bool) -> Void)?
    /// 引擎路径上的每个按键事件（GUI「按下即亮」）。回调线程=事件来源线程。
    var onButtonEvent: ((ButtonEvent) -> Void)?
    var onActiveApplication: ((String?) -> Void)?

    /// 最近一个「非本进程」的前台应用（防止本 App 自己的设置窗口污染 per-app profile）。
    private(set) var lastExternalApplication: NSRunningApplication?

    /// 外部 App 的 MRU 栈（最新在前，最多 3 个；[0]=当前前台，[1]=上一个）。
    /// 主线程维护（NSWorkspace 通知在主线程投递）；App 轮盘 UI 直接读，
    /// `app_mru_back` 动作经主线程走 activateMRUBack()。
    private(set) var mruExternalApplications: [NSRunningApplication] = []
    private static let mruCapacity = 5   // App 轮盘容量（五大 App 目标，DESIGN §3.1b）

    /// MRU 压栈纯逻辑（自测覆盖）：去重后插到栈顶，截断到 cap。
    static func mruPush(_ stack: [String], _ id: String, cap: Int = mruCapacity) -> [String] {
        var next = stack.filter { $0 != id }
        next.insert(id, at: 0)
        if next.count > cap { next.removeLast(next.count - cap) }
        return next
    }

    /// MRU 回切目标纯逻辑（自测覆盖）：栈顶是当前前台，目标 = 第一个非当前项。
    static func mruBackTarget(_ stack: [String], current: String?) -> String? {
        stack.first { $0 != current }
    }

    private func pushMRU(_ app: NSRunningApplication) {
        mruExternalApplications.removeAll {
            $0.processIdentifier == app.processIdentifier || $0.isTerminated
        }
        mruExternalApplications.insert(app, at: 0)
        if mruExternalApplications.count > Self.mruCapacity {
            mruExternalApplications.removeLast(mruExternalApplications.count - Self.mruCapacity)
        }
    }

    /// `app_mru_back`：切到上一个外部 App（栈里第一个非当前前台且仍存活的）。主线程调用。
    func activateMRUBack() {
        let currentPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let target = mruExternalApplications.first(where: {
            !$0.isTerminated && $0.processIdentifier != currentPid
        }) else {
            log("app_mru_back：无可回切的上一个 App")
            return
        }
        WindowSwitcher.activateApplication(target)
    }

    /// 前台切换 observer token：stop/deinit 时移除，防旧服务泄漏与回调叠加。
    private var activateObserver: NSObjectProtocol?

    init(config: MappingConfig, verbose: Bool) {
        self.verbose = verbose
        genericVoiceHIDEnabled = config.globalShortcuts != nil
        engine = MappingEngine(config: config, runner: runner, delegate: self)
        runner.codexInputGeneration = { [weak engine] in
            guard let engine, !engine.isSuspended, !engine.tapRoute.uiCapture,
                  engine.tapRoute.effectiveLayer == 0 else { return nil }
            return engine.inputGeneration
        }
        // 启动时用当前前台 app seed（忽略自己）。
        let myPid = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != myPid {
            lastExternalApplication = front
            pushMRU(front)
            engine.setActiveProfile(front.bundleIdentifier)
            onActiveApplication?(front.bundleIdentifier)
        }
        // 前台 app 变化 → 自动切 profile。忽略本进程（设置窗口拿到前台不改 profile）。
        activateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != myPid else { return }
            self.resetDouyinVoiceReservation()
            self.lastExternalApplication = app
            self.pushMRU(app)
            self.engine.setActiveProfile(app.bundleIdentifier)
            self.onActiveApplication?(app.bundleIdentifier)
        }
    }

    /// 服务停止时显式解除通知订阅（closure observer 强持有直至 remove）。
    func invalidate() {
        if let activateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activateObserver)
        }
        activateObserver = nil
    }

    deinit { invalidate() }

    func hidLog(_ message: String) { if verbose { log("HID \(message)") } }
    func hidButton(_ event: ButtonEvent) {
        if verbose { log("KEY \(event.key.rawValue) \(event.isDown ? "↓" : "↑")") }
        onButtonEvent?(event)
        // M5 v2：Home 长按教程浮层改走引擎的 hold=.overlay("tutorial") 常规路径，
        // 浮层打开后由 uiCapture 捕获后续按键（含再按 Home 关闭）。
        var liveEligible = false
        if event.key == .voice {
            let route = onMain { () -> (eligible: Bool, deliver: Bool) in
                if event.isDown {
                    let eligible = reserveDouyinVoicePress(hid: true) == .live
                    let deliver = eligible || genericVoiceHIDEnabled || voiceHIDWasForwarded
                    voiceHIDWasForwarded = deliver
                    return (eligible, deliver)
                }
                let wasLive = douyinVoiceOwner == .live
                let deliver = voiceHIDWasForwarded || genericVoiceHIDEnabled
                voiceHIDWasForwarded = false
                releaseDouyinVoicePress(hid: true)
                return (wasLive, deliver)
            }
            guard route.deliver else { return }
            liveEligible = route.eligible
        }
        engine.handle(event, douyinLiveVoiceEligible: liveEligible)
    }

    private enum DouyinVoiceOwner { case live, suppressed, generic }
    private var douyinVoiceOwner: DouyinVoiceOwner?
    private var douyinHIDDown = false
    private var douyinBLEDown = false
    private var douyinHIDSeen = false
    private func onMain<T>(_ body: () -> T) -> T {
        Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
    }
    private func reserveDouyinVoicePress(hid: Bool) -> DouyinVoiceOwner {
        if hid {
            if !douyinHIDDown && douyinHIDSeen {
                // A new HID press supersedes an old missing BLE STOP.
                douyinBLEDown = false
                douyinVoiceOwner = nil
            }
            douyinHIDDown = true
            douyinHIDSeen = true
        } else { douyinBLEDown = true }
        if let douyinVoiceOwner { return douyinVoiceOwner }
        let owner: DouyinVoiceOwner = MainActor.assumeIsolated {
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == DouyinLiveDictation.bundleID else { return .generic }
            guard !engine.isSuspended, !engine.tapRoute.uiCapture,
                  engine.tapRoute.effectiveLayer == 0, !MouseMode.shared.isActive,
                  !TransientSystemUI.isMissionControlActive() else { return .suppressed }
            return DouyinLiveDictation.canHandleVoice() ? .live : .generic
        }
        douyinVoiceOwner = owner
        return owner
    }
    private func releaseDouyinVoicePress(hid: Bool) {
        if hid { douyinHIDDown = false } else { douyinBLEDown = false }
        if !douyinHIDDown && !douyinBLEDown {
            douyinVoiceOwner = nil
            douyinHIDSeen = false
        }
    }
    func reserveDouyinBLEVoice() -> Bool {
        reserveDouyinVoicePress(hid: false) != .generic
    }
    func updateVoiceHIDConfig(_ config: MappingConfig) {
        onMain { genericVoiceHIDEnabled = config.globalShortcuts != nil }
    }
    func releaseDouyinBLEVoice() {
        if Thread.isMainThread { releaseDouyinVoicePress(hid: false) }
        else { DispatchQueue.main.async { [weak self] in self?.releaseDouyinVoicePress(hid: false) } }
    }
    func resetDouyinVoiceReservation() {
        onMain {
            douyinVoiceOwner = nil
            douyinHIDDown = false
            douyinBLEDown = false
            douyinHIDSeen = false
        }
    }

    func hidSeizeState(_ exclusive: Bool) {
        log(exclusive ? "按键已独占接管" : "按键降级为监听模式（系统仍会响应原始按键）")
        onSeizeState?(exclusive)
    }
    func mappingLog(_ message: String) { if verbose { log("MAP \(message)") } }
    func layerChanged(_ layer: Int) {
        log("层 → \(layer)")
        onLayerChanged?(layer)
    }
}

/// 主线程写配置/前台 App，蓝牙队列读；用锁隔离跨线程状态。
private final class VoiceRuleStore: @unchecked Sendable {
    private let lock = NSLock()
    private var rules: [String: VoiceTriggerRule]?
    private var bundleID: String?
    private var codexTwoPressDictation = false
    private var codexPhysicalHold = false

    func update(config: MappingConfig) {
        lock.lock()
        rules = config.voiceProfiles
        codexTwoPressDictation = config.profiles["com.openai.codex"]?["voice"]?.tap
            == .system(CodexDictation.actionName)
        codexPhysicalHold = config.profiles["com.openai.codex"]?["voice"]?.hold
            == .system("codex_context_voice_start")
        lock.unlock()
    }

    func update(bundleID: String?) {
        lock.lock(); self.bundleID = bundleID; lock.unlock()
    }

    func resolve() -> VoiceTriggerConfig {
        lock.lock()
        let snapshotRules = rules
        let snapshotBundle = bundleID
        lock.unlock()
        return VoiceTriggerRouting.resolve(snapshotRules, bundleID: snapshotBundle)
    }

    func isDouyinFrontmost() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return bundleID == "com.bytedance.douyin.desktop"
    }

    func useCodexPhysicalHold() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return codexPhysicalHold && bundleID == "com.openai.codex"
    }

    func suppressPhysicalVoice() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return codexTwoPressDictation && bundleID == "com.openai.codex"
    }
}

/// IOHID 监听通道的过滤器：只放行"系统天然忽略"的键（如 back 0xF1），
/// 其余键由 hidutil 中转 + CGEventTap 处理，这里放行会造成双触发。
final class IOHIDOnlyFilter: HIDEngineDelegate {
    let target: KeyMapperApp
    let allowed: Set<RemoteKey>
    /// 所有原始按键事件（含被过滤不进引擎的），GUI「识别按键」学习模式用。
    var onRawButton: ((ButtonEvent) -> Void)?
    var onRawVoiceButton: ((ButtonEvent) -> Void)?
    init(_ target: KeyMapperApp, voiceKey: Bool = false) {
        self.target = target
        self.allowed = voiceKey ? [.back, .voice] : [.back]
    }
    func hidLog(_ message: String) { target.hidLog(message) }
    func hidButton(_ event: ButtonEvent) {
        if event.key == .voice { onRawVoiceButton?(event) }
        target.hidLog("IOHID读到 \(event.key.rawValue) \(event.isDown ? "↓" : "↑")")
        onRawButton?(event)
        if allowed.contains(event.key) { target.hidButton(event) }
    }
    func hidSeizeState(_ exclusive: Bool) {} // 监听模式，无独占概念
}

// MARK: - 服务容器（CLI/GUI 共用的接线）

/// 一次性组装语音链路 + 按键映射链路，start/stop 生命周期成对。
/// GUI 与 CLI 共用；差异只在 Options 与事件钩子。
final class AppServices {

    struct Options {
        var outputName: String? = "BlackHole 2ch"
        /// CLI --output 显式给过（显式值优先于 config settings.voiceOutputDevice）。
        var outputExplicit = false
        /// CLI --trigger-key/--trigger-mode/--ime 的覆盖记录（nil=未给 → 用配置或内置默认）。
        var cliTriggerKey: String?
        var cliTriggerMode: String?
        var cliIMEGiven = false
        var cliIME: String?
        var wavPath: String?
        var gainDB: Double = 0
        var verbose = false
        var switchInput = true
        var doubao = false
        var keys = false
        /// GUI 开启；CLI 保留 --trigger-key/--trigger-mode/--ime 的全局覆盖行为。
        var perAppVoiceRouting = false
        var configPath: String?
        /// GUI 附加：电平表 sink
        var levelSink: PCMSink?
    }

    let options: Options
    let voiceApp: VoiceBridgeApp
    let bridge: ATVVBridge
    let health = HealthMonitor()
    /// 等待批准提醒：本地 socket 收 Claude Code hook 事件（GUI/CLI 服务模式都监听）。
    let eventListener = EventListener()
    private(set) var keyMapper: KeyMapperApp?
    private(set) var tapEngine: TapEngine?
    private(set) var hidFilter: IOHIDOnlyFilter?
    private(set) var hidEngine: HIDEngine?
    private(set) var started = false
    private let voiceRuleStore = VoiceRuleStore()
    /// 睡眠/唤醒/设备事件的 observer tokens：stop 时逐个移除（否则旧服务无法释放、
    /// 重新 start 会叠加回调；闭包内一律弱捕获 tap/km 作为第二道防线）。
    private var workspaceObservers: [NSObjectProtocol] = []
    /// AppKit 显示参数通知来自 default center，必须在同一 center 解除。
    private var displayParametersObserver: NSObjectProtocol?
    /// All callers run on the main queue. GUI ends temporary TV-key routing
    /// when its display or physical-input context is no longer current.
    var onRemoteContextChanged: ((String) -> Void)?

    private func reconnectForExternalDisplay(reason: String) {
        guard started, options.keys else { return }
        guard keyMapper?.engine.isSuspended != true else {
            bridge.cancelReconnectRequest(reason: "遥控已暂停")
            return
        }
        let externalDisplay = NSScreen.screens.contains { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(CGDirectDisplayID(id.uint32Value)) == 0
        }
        // Display presence is not proof that the TV has selected this HDMI input.
        if externalDisplay { bridge.requestReconnect(reason: reason) }
        else { bridge.cancelReconnectRequest(reason: "未检测到外接显示器") }
    }

    /// 启动期语音触发三级合并（纯函数，供自测）：内置默认 ← 配置 global 规则 ← CLI 标志。
    /// cliIME 双层 Optional：nil=CLI 未给；.some(nil)=--ime none（不切输入法）；.some(v)=指定前缀。
    static func startupVoiceTriggerConfig(globalRule: VoiceTriggerRule?,
                                          cliKey: String?, cliMode: String?,
                                          cliIME: String??) -> VoiceTriggerConfig {
        var cfg = VoiceTriggerRouting.resolve(globalRule.map { ["global": $0] }, bundleID: nil)
        if let cliKey, VoiceTriggerConfig.keyTable[cliKey] != nil { cfg.keyName = cliKey }
        if let cliMode, let mode = VoiceTriggerConfig.Mode(rawValue: cliMode) { cfg.mode = mode }
        if let cliIME { cfg.imeBundlePrefix = cliIME }
        return cfg
    }

    init(options: Options) {
        // 启动早期只读预载配置：settings 覆盖项（VID/PID、声卡名、终端白名单）
        // 与 voiceProfiles.global 需要在各引擎构建前生效。文件缺失/坏损 → 全部内置默认。
        let preloaded = ConfigStore.loadIfExists(at: options.configPath)
        ActionRunner.configureTelevision(preloaded?.television)
        let settings = preloaded?.settings ?? MappingConfig.Settings()
        RemoteIdentity.configure(vendorID: settings.remoteVendorID,
                                 productID: settings.remoteProductID)
        FocusInput.extraTerminalBundles = Set(settings.terminalApps ?? [])
        var options = options
        if !options.outputExplicit, let dev = settings.voiceOutputDevice {
            options.outputName = dev
        }
        VoiceTrigger.config = Self.startupVoiceTriggerConfig(
            globalRule: preloaded?.voiceProfiles?["global"],
            cliKey: options.cliTriggerKey,
            cliMode: options.cliTriggerMode,
            cliIME: options.cliIMEGiven ? .some(options.cliIME) : nil)
        self.options = options
        voiceApp = VoiceBridgeApp(outputName: options.outputName,
                                  wavPath: options.wavPath,
                                  gainDB: options.gainDB,
                                  verbose: options.verbose,
                                  switchInput: options.switchInput,
                                  doubao: options.doubao,
                                  micDeviceName: settings.voiceOutputDevice ?? "BlackHole",
                                  extraSink: options.levelSink)
        voiceApp.minimumHoldMs = options.keys && preloaded?.globalShortcuts != nil
            ? preloaded?.settings.holdMs ?? 600 : 0
        bridge = ATVVBridge(delegate: voiceApp)
        voiceApp.onPhysicalVoiceKey = { [weak bridge] held, generation in
            bridge?.setVoiceButtonHeld(held, token: generation)
        }
        voiceApp.authorizeVoiceContinuation = { [weak bridge] token in bridge?.authorizeVoiceContinuation(token: token) }
        voiceApp.revokeVoiceContinuation = { [weak bridge] token in bridge?.revokeVoiceContinuation(token: token) }
        health.log = { log("健康 \($0)") }
        voiceApp.onConnection = { [weak health] connected, _ in
            health?.setBLEConnected(connected)
        }
    }

    /// 启动全部服务（幂等）。keys 链路仅在 options.keys 时启动。
    func start() {
        guard !started else { return }
        started = true
        KeyRemapper.log = { log("HIDUTIL \($0)") }
        switch KeyRemapper.cleanResidualMapping() {
        case .cleaned(let count):
            log("检测到上次异常退出残留（\(count) 条 hidutil 中转映射），已清理")
        case .cleanFailed:
            log("检测到上次异常退出残留，但清理失败（可运行 --doctor 重试）")
        case .none, .queryFailed:
            break
        }
        if options.keys {
            let config = loadOrCreateConfig(at: options.configPath)
            voiceRuleStore.update(config: config)
            Task { @MainActor in
                DouyinLiveDictation.configure(triggerConfig: VoiceTriggerRouting.resolve(config.voiceProfiles, bundleID: DouyinLiveDictation.bundleID))
            }
            voiceApp.shouldSuppressPhysicalVoice = { [weak voiceRuleStore] in
                voiceRuleStore?.suppressPhysicalVoice() ?? false
            }
            voiceApp.shouldUseCodexPhysicalHold = { [weak voiceRuleStore] in
                voiceRuleStore?.useCodexPhysicalHold() ?? false
            }
            Task { @MainActor [weak voiceApp] in
                CodexDictation.onPhysicalHoldState = { [weak voiceApp] active in
                    voiceApp?.setCodexPhysicalHold(active: active, token: CodexDictation.remotePCMToken)
                }
                CodexDictation.onPhysicalHoldRelease = { [weak voiceApp] token in
                    guard let voiceApp else {
                        CodexDictation.endRemoteTransport(token: token, reason: "hid-no-service")
                        return
                    }
                    voiceApp.releaseCodexPhysicalHold(token: token)
                }
                CodexDictation.onPhysicalHoldPrepare = { [weak voiceApp] in
                    voiceApp?.prepareCodexPhysicalHold()
                }
                CodexDictation.onPhysicalHoldContinuation = { [weak voiceApp] token in
                    voiceApp?.renewVoiceContinuation(token: token)
                }
            }
            let km = KeyMapperApp(config: config, verbose: options.verbose)
            voiceApp.shouldReserveDouyinPhysicalVoice = { [weak voiceRuleStore] in voiceRuleStore?.isDouyinFrontmost() ?? false }
            voiceApp.reserveDouyinPhysicalVoice = { [weak km] in km?.reserveDouyinBLEVoice() ?? false }
            voiceApp.releaseDouyinPhysicalVoice = { [weak km] in km?.releaseDouyinBLEVoice() }
            voiceApp.resetDouyinPhysicalVoice = { [weak km] in
                if Thread.isMainThread { km?.resetDouyinVoiceReservation() }
                else { DispatchQueue.main.async { km?.resetDouyinVoiceReservation() } }
            }
            voiceRuleStore.update(bundleID: km.lastExternalApplication?.bundleIdentifier)
            km.onActiveApplication = { [weak voiceRuleStore] bundleID in
                voiceRuleStore?.update(bundleID: bundleID)
            }
            if options.perAppVoiceRouting {
                voiceApp.resolveTriggerConfig = { [weak voiceRuleStore] in
                    voiceRuleStore?.resolve() ?? VoiceTriggerConfig()
                }
            }
            // app_mru_back 动作出口：切到 MRU 栈里的上一个外部 App（P6 核心侧）。
            ActionRunner.onAppMRUBack = { [weak km] in km?.activateMRUBack() }
            let tap = TapEngine(delegate: km)
            tap.router = km.engine  // 方向键三态分流的快照来源
            let filter = IOHIDOnlyFilter(km, voiceKey: true)
            filter.onRawVoiceButton = { [weak voiceApp] event in voiceApp?.receiveRawVoiceHID(event) }
            let hid = HIDEngine(delegate: filter)
            keyMapper = km
            tapEngine = tap
            hidFilter = filter
            hidEngine = hid
            health.setKeysEnabled(true)
            km.onSeizeState = { [weak health] alive in health?.setTapAlive(alive) }
            // tap 与映射是两个独立健康源：映射在位状态由 TapEngine 的安装结果直接上报。
            tap.onMappingState = { [weak health] installed in
                health?.setMappingInstalled(installed)
            }
            health.reinstallMapping = { [weak tap] in
                tap?.reinstallMapping(reason: "周期健康检查发现映射缺失")
            }
            // 暂停遥控：引擎是唯一事实源，联动 TapEngine（卸/装 hidutil 映射）
            // 与 HealthMonitor（暂停位让健康判定/自动重装豁免）。
            km.engine.onSuspendChanged = { [weak tap, weak health] suspended in
                health?.setSuspended(suspended)
                tap?.setSuspended(suspended)
            }
            // 映射生命周期：设备/显示服务重建后，短窗口复核实际映射，确认缺失才重装；
            // 设备移除 / 系统睡眠可能丢 keyUp → 复位引擎与 tap 的按压状态。
            hid.onDeviceMatched = { [weak self, weak tap] in
                tap?.scheduleMappingRecovery(reason: "设备接入")
                // Pairing through System Settings may stop the remote advertising
                // before the app's service scan sees it. Retrieve its now-connected
                // ATVV service when the OS has actually enumerated the target HID.
                self?.bridge.requestReconnect(reason: "系统已接入遥控器按键设备")
            }
            hid.onDeviceRemoved = { [weak self, weak km, weak tap] in
                self?.voiceApp.resetRawVoiceHID()
                self?.onRemoteContextChanged?("遥控器已断开")
                km?.resetDouyinVoiceReservation()
                km?.engine.resetInputState(reason: "设备移除")
                tap?.resetPressState()
            }
            let wsnc = NSWorkspace.shared.notificationCenter
            workspaceObservers.append(wsnc.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self, weak tap] _ in
                tap?.scheduleMappingRecovery(reason: "系统唤醒")
                self?.onRemoteContextChanged?("系统唤醒")
                self?.reconnectForExternalDisplay(reason: "系统唤醒且存在外接显示")
            })
            displayParametersObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main) { [weak self, weak tap] _ in
                tap?.scheduleMappingRecovery(reason: "显示参数变化")
                self?.onRemoteContextChanged?("显示连接变化")
                self?.reconnectForExternalDisplay(reason: "显示连接变化且存在外接显示")
            }
            for notification in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
                workspaceObservers.append(wsnc.addObserver(
                    forName: notification, object: nil, queue: .main) { [weak self] note in
                    let awake = note.name == NSWorkspace.screensDidWakeNotification
                    self?.onRemoteContextChanged?(awake ? "显示输出恢复" : "显示输出休眠")
                    if awake { self?.reconnectForExternalDisplay(reason: "外接显示输出恢复") }
                    else { self?.bridge.cancelReconnectRequest(reason: "显示输出休眠") }
                })
            }
            workspaceObservers.append(wsnc.addObserver(
                forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self, weak km, weak tap] _ in
                self?.onRemoteContextChanged?("系统即将休眠")
                self?.voiceApp.resetRawVoiceHID()
                self?.bridge.cancelReconnectRequest(reason: "系统即将休眠")
                km?.resetDouyinVoiceReservation()
                km?.engine.resetInputState(reason: "系统睡眠")
                tap?.resetPressState()
            })
            tap.start()
            hid.start()
            log("按键映射已启用（hidutil 中转 + CGEventTap + IOHID 监听兜底）")
        }
        eventListener.log = { log("EVENT \($0)") }
        eventListener.onEvent = { event in
            AgentNotifier.notify(event) { log("EVENT \($0)") }
        }
        eventListener.start()
        health.startPeriodicChecks()
        log("启动，输出设备: \(options.outputName ?? "系统默认")\(options.wavPath.map { "，WAV: \($0)" } ?? "")")
        bridge.start()
        DispatchQueue.main.async { [weak self] in
            self?.reconnectForExternalDisplay(reason: "启动且存在外接显示")
        }
    }

    /// 停止并恢复系统状态（hidutil 中转恢复、语音断开、shell 进程组清扫）。幂等。
    func stop() {
        guard started else { return }
        started = false
        ActionRunner.configureTelevision(nil)
        keyMapper?.engine.setSuspended(true)
        MouseMode.shared.deactivate()
        eventListener.stop()
        health.stop()
        // 先同步排空 ATVV 队列，再从生命周期线程收尾 VoiceBridgeApp；否则首帧回调
        // 可在 forceEnd 之后重新 begin，CLI 紧接 exit 时还会截断 BLE teardown。
        bridge.stopAndWait()
        voiceApp.forceEndSessionIfActive()   // 同步松触发键、还原输入法/麦克风
        tapEngine?.stop() // 恢复 hidutil 映射
        hidEngine?.stop()
        // observer / 回调解除：旧服务对象可释放，重新 start 不叠加回调。
        let wsnc = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { wsnc.removeObserver($0) }
        workspaceObservers.removeAll()
        if let displayParametersObserver {
            NotificationCenter.default.removeObserver(displayParametersObserver)
        }
        displayParametersObserver = nil
        keyMapper?.invalidate()
        ActionRunner.onAppMRUBack = nil
        // shell 动作派生的活动进程组：TERM→KILL 清扫，超时承诺随服务生命周期兑现。
        ShellProcessRegistry.shared.terminateAll()
        log("服务已停止，hidutil 中转已恢复")
    }

    /// 热加载映射配置（UI 写回 config.json 后调用）。
    /// settings 里的 VID/PID、声卡名改动需重启进程生效（引擎构建期绑定）；终端白名单即刻生效。
    func applyConfig(_ config: MappingConfig) {
        ActionRunner.configureTelevision(config.television)
        voiceApp.minimumHoldMs = options.keys && config.globalShortcuts != nil
            ? config.settings.holdMs : 0
        FocusInput.extraTerminalBundles = Set(config.settings.terminalApps ?? [])
        voiceRuleStore.update(config: config)
        Task { @MainActor in
            DouyinLiveDictation.configure(triggerConfig: VoiceTriggerRouting.resolve(config.voiceProfiles, bundleID: DouyinLiveDictation.bundleID))
        }
        keyMapper?.resetDouyinVoiceReservation()
        keyMapper?.updateVoiceHIDConfig(config)
        keyMapper?.engine.setConfig(config)
    }

    /// 体检「重建通道」：重装 hidutil 映射（TapEngine 内部含 tap 健康自愈）。
    /// 暂停/恢复遥控（UI 菜单栏面板的暂停 toggle 入口）。幂等。
    func setRemoteSuspended(_ suspended: Bool) {
        if suspended { keyMapper?.resetDouyinVoiceReservation() }
        keyMapper?.engine.setSuspended(suspended)
    }

    /// 只读：遥控是否处于暂停态（按键服务未启动时视为未暂停）。
    var isRemoteSuspended: Bool { keyMapper?.engine.isSuspended ?? false }

    func reinstallMapping() {
        tapEngine?.reinstallMapping(reason: "体检修复")
    }

    func runRepair() -> RepairReport {
        HealthMonitor.runRepair(runtime: health.sourcesSnapshot) { [weak self] in
            self?.reinstallMapping()
        }
    }
}
