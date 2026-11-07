import AppKit
import SwiftUI

// 捕获式浮层打开时由 MappingEngine.setOverlayCapture 把列表按键喂给本中心；
// 独立的全局手势由 MappingEngine 优先决断，避免面板和鼠标模式遮住系统入口。
// App 控制模式 HUD 是非捕获的纯状态提示。
// 面板全部用 NSPanel(.nonactivatingPanel)：不抢焦点、不打断前台 App；
// 内容用系统材质与语义色，深浅色自动适配。

// MARK: - 系统功能菜单目录（静态数据 + 纯函数，供浮层与 self-test）

struct SystemMenuItem {
    let title: String
    let symbol: String
    let action: Action
    /// 危险动作（锁屏/睡眠/退出 App）：OK 需按住 0.6s 填充确认，杜绝单手误触（gamepad-ux D2）。
    var dangerous: Bool = false
}

enum SystemMenuCatalog {
    /// 网格条目（3 列）。全部走 ActionRunner 既有能力，无私有 API；危险项标红并集中排在末尾。
    static let items: [SystemMenuItem] = [
        .init(title: "调度中心",   symbol: "square.grid.3x2",             action: .system("mission_control")),
        .init(title: "App Exposé", symbol: "square.on.square",            action: .system("app_expose")),
        .init(title: "显示桌面",   symbol: "menubar.dock.rectangle",      action: .system("show_desktop")),
        .init(title: "左侧桌面",   symbol: "arrow.left.square",           action: .system("space_left")),
        .init(title: "右侧桌面",   symbol: "arrow.right.square",          action: .system("space_right")),
        .init(title: "聚焦编辑区", symbol: "cursorarrow.and.square.on.square.dashed", action: .focusInput),
        .init(title: "播放 / 暂停", symbol: "playpause",                   action: .system("play_pause")),
        .init(title: "静音",       symbol: "speaker.slash",               action: .system("mute")),
        .init(title: "打开 MiRemote 设置", symbol: "gearshape",           action: .overlay("open_settings")),
        .init(title: "退出当前 App", symbol: "escape",                    action: .system("quit_app"), dangerous: true),
        .init(title: "锁屏",       symbol: "lock",                        action: .system("lock_screen"), dangerous: true),
        .init(title: "睡眠",       symbol: "moon.zzz",                    action: .system("display_sleep"), dangerous: true),
    ]
    /// 常规区列数：9 个常规项 = 3×3；3 个危险项独立一行。
    static let columns = 3
    /// 危险项 OK 按住确认时长（gamepad-ux D2 遥控场景甜点值）。
    static let confirmHoldSeconds: TimeInterval = 0.6
    /// 行宽布局：常规网格 + 末行危险区。
    static var rowWidths: [Int] {
        let regular = items.filter { !$0.dangerous }.count
        var rows = Array(repeating: columns, count: regular / columns)
        if regular % columns != 0 { rows.append(regular % columns) }
        let dangerous = items.filter(\.dangerous).count
        if dangerous > 0 { rows.append(dangerous) }
        return rows
    }

    /// index → (行, 列)（按 rowWidths 切分）。
    static func position(of index: Int, rows: [Int]) -> (row: Int, col: Int) {
        var rest = index
        for (r, width) in rows.enumerated() {
            if rest < width { return (r, rest) }
            rest -= width
        }
        return (max(0, rows.count - 1), 0)
    }

    /// 网格方向移动的纯逻辑（供 self-test）：左右全序回绕，上下跨行保列并夹在行宽内。
    static func move(_ index: Int, key: RemoteKey, rows: [Int]) -> Int {
        let count = rows.reduce(0, +)
        guard count > 0 else { return 0 }
        switch key {
        case .left:  return (index - 1 + count) % count
        case .right: return (index + 1) % count
        case .up, .down:
            let (row, col) = position(of: index, rows: rows)
            let target = key == .up ? max(0, row - 1) : min(rows.count - 1, row + 1)
            guard target != row else { return index }
            let prefix = rows.prefix(target).reduce(0, +)
            return prefix + min(col, rows[target] - 1)
        default:     return index
        }
    }

    /// 浮层数据模型自测：条目非空、标题唯一、system 动作名全部在执行目录内。
    static func selfCheck() -> Bool {
        guard !items.isEmpty, Set(items.map(\.title)).count == items.count else { return false }
        let known = Set(WorkspaceActions.actionNames
                        + ["play_pause", "mute", "volume_up", "volume_down",
                           "lock_screen", "display_sleep", "mission_control"])
        for item in items {
            switch item.action {
            case .system(let name): if !known.contains(name) { return false }
            case .focusInput: break
            case .keyStroke: break
            case .overlay(let name): if name != "open_settings" { return false }
            default: return false
            }
        }
        // 实体音量 +/- 已是全局快捷键，系统菜单不再重复；保留无实体键的静音。
        let systemNames = items.compactMap { item -> String? in
            if case .system(let name) = item.action { return name }
            return nil
        }
        guard systemNames.contains("mute"),
              !systemNames.contains("volume_up"), !systemNames.contains("volume_down") else { return false }
        // 危险项必须集中在末尾且要求按住确认；常规区必须刚好铺满整行（无孤行）
        let dangerousIdx = items.enumerated().filter { $0.element.dangerous }.map(\.offset)
        guard dangerousIdx == Array((items.count - dangerousIdx.count)..<items.count) else { return false }
        guard (items.count - dangerousIdx.count) % columns == 0 else { return false }
        // 方向移动纯逻辑抽查（行宽 [3,3,3,3] 共 12 项）
        let rows = rowWidths
        return move(0, key: .right, rows: rows) == 1
            && move(0, key: .left, rows: rows) == 11
            && move(1, key: .down, rows: rows) == 4
            && move(4, key: .down, rows: rows) == 7
            && move(8, key: .down, rows: rows) == 11
            && move(11, key: .up, rows: rows) == 8
            && move(1, key: .up, rows: rows) == 1
    }
}

// MARK: - 浮层视图状态（持久 HostingView 的唯一数据源）

/// 选中移动 = @Published 变化驱动的连续动画；视图树只在浮层打开时创建一次，不随按键重建。
@MainActor
final class OverlayUIState: ObservableObject {
    @Published var kind: OverlayCenter.Kind?
    @Published var pickerEntries: [WindowSwitcher.PickerEntry] = []
    @Published var pickerIndex = 0
    @Published var pickerCurrentAppOnly = false
    @Published var frontAppName: String?
    @Published var menuIndex = 0
    @Published var menuConfirming = false
    @Published var wheelEntries: [AppWheelView.Entry] = []
    @Published var wheelIndex = 0
    @Published var codexSnapshot = CodexSessions.Snapshot()
    @Published var codexIndex = 0
    @Published var powerMenu = PowerMenuState()
}

/// 窗口选择器的菜单键三段流程：全局跨桌面 → 当前 App → 关闭。
enum WindowPickerFlow {
    static let pageSize = 6

    /// true=当前 App，false=全局，nil=关闭。
    static func nextAfterMenu(currentAppOnly: Bool) -> Bool? {
        currentAppOnly ? nil : true
    }

    /// 与会话列表一致：上下逐项、左右一页，首尾夹住，不回绕。
    static func movedIndex(_ index: Int, key: RemoteKey, count: Int) -> Int {
        let delta: Int
        switch key {
        case .up: delta = -1
        case .down: delta = 1
        case .left: delta = -pageSize
        case .right: delta = pageSize
        default: delta = 0
        }
        return count > 0 ? min(max(index + delta, 0), count - 1) : 0
    }

    static func selfCheck() -> Bool {
        movedIndex(0, key: .up, count: 10) == 0
            && movedIndex(0, key: .down, count: 10) == 1
            && movedIndex(1, key: .right, count: 10) == 7
            && movedIndex(7, key: .left, count: 10) == 1
            && movedIndex(8, key: .right, count: 10) == 9
            && movedIndex(4, key: .down, count: 0) == 0
            && nextAfterMenu(currentAppOnly: false) == true
            && nextAfterMenu(currentAppOnly: true) == nil
    }
}

// MARK: - 浮层中心

@MainActor
final class OverlayCenter {

    enum Kind: String {
        case windowPicker = "window_picker"
        case systemMenu = "system_menu"
        case tutorial = "tutorial"
        case appWheel = "app_wheel"
        case codexSessions = "codex_sessions"
        case computerPower = "computer_power"
    }

    private weak var model: AppModel?
    private weak var services: AppServices?
    private let runner = ActionRunner()
    private let quickLook: MappingQuickLookController

    private var active: Kind?
    private var panel: NSPanel?
    private let uiState = OverlayUIState()
    private var escMonitor: Any?

    // 窗口选择器状态
    private var pickerEntries: [WindowSwitcher.PickerEntry] = []
    private var pickerIndex = 0
    private var pickerCurrentAppOnly = false
    // 系统功能菜单状态
    private var menuIndex = 0
    // App 轮盘状态（停留式，DESIGN §3.1b：TV 长按弹出后松手停留，3s 无操作自动关）
    private var wheelApps: [NSRunningApplication] = []
    private var wheelIndex = 0
    private var wheelIdleTimer: Timer?
    private let codexSessions = CodexSessions()
    private var codexSnapshot = CodexSessions.Snapshot()
    private var codexIndex = 0
    private var powerMenu = PowerMenuState()
    private var powerGeneration: UInt64 = 0
    /// 窗口选择/系统菜单/教程不应无限占用遥控路由；10s 无操作自动收起。
    private static let overlayIdleSeconds: TimeInterval = 10
    private var overlayIdleTimer: Timer?
    // App 控制模式 HUD
    private var hudPanel: NSPanel?
    // 按键提示条（gamepad-ux B1：模式/浮层激活时屏底常驻）
    private var hintPanel: NSPanel?
    private var hintVisibilityGeneration: UInt64 = 0
    /// profile 切换提示的自增令牌（见 noteProfileSwitch）。
    private var profileHintToken = 0
    private var mouseStatusText: String?
    // 列表导航按住加速（gamepad-ux D3）：400ms 起连发，1.5s 后提速
    private var repeatKey: RemoteKey?
    private var repeatTimer: Timer?
    // 危险动作 hold-to-confirm（gamepad-ux D2）
    private var confirmTimer: Timer?
    private var confirmingIndex: Int?

    init(model: AppModel, services: AppServices?) {
        self.model = model
        self.services = services
        self.quickLook = MappingQuickLookController(model: model)
    }

    private var engine: MappingEngine? { services?.keyMapper?.engine }
    private var frontApp: NSRunningApplication? { services?.keyMapper?.lastExternalApplication }

    // MARK: 打开 / 关闭

    /// ActionRunner.onOverlay 入口（主线程）。同名浮层已开 → 关闭（同键 toggle 兜底；
    /// 正常路径下浮层打开后按键已被捕获，走 handleKey 关闭）。
    /// 「打开 MiRemote 设置」可绑定动作（菜单栏优先形态的遥控入口，GUIAppDelegate 接线）。
    var onOpenSettings: (() -> Void)?

    /// 异步失败回落可能重复到达；已有同一面板时保持打开，不执行 toggle。
    func ensureOpen(_ name: String) {
        guard active?.rawValue != name else { return }
        open(name)
    }

    func open(_ name: String) {
        if name == "open_settings" {
            close()
            onOpenSettings?()
            return
        }
        guard let kind = Kind(rawValue: name) else {
            log("未知浮层名: \(name)")
            return
        }
        if active == kind { close(); return }
        if active != nil { close() }
        if kind == .windowPicker || kind == .systemMenu || kind == .computerPower {
            MouseMode.shared.deactivate()
            mouseStatusText = nil
        }
        profileHintToken &+= 1
        active = kind
        switch kind {
        case .windowPicker:
            pickerCurrentAppOnly = false
            reloadPickerEntries()
            showPanel()
        case .systemMenu:
            menuIndex = 0
            showPanel()
        case .computerPower:
            powerGeneration &+= 1
            powerMenu.open()
            showPanel()
        case .tutorial:
            quickLook.setVisible(true,
                                 bundleID: frontApp?.bundleIdentifier,
                                 appName: frontApp?.localizedName)
        case .appWheel:
            // 数据源 = KeyMapperApp 的 MRU 栈（[0]=当前前台，[1..]=最近用过，主线程读）
            wheelApps = services?.keyMapper?.mruExternalApplications.filter { !$0.isTerminated } ?? []
            wheelIndex = wheelApps.count > 1 ? 1 : 0   // 默认选「上一个 App」，一确认即回切
            showPanel()
            restartWheelIdleTimer()
        case .codexSessions:
            codexIndex = 0
            codexSnapshot = CodexSessions.Snapshot(isLoading: true)
            showPanel()
            codexSessions.load { [weak self] snapshot in
                guard let self, self.active == .codexSessions else { return }
                let selectedID = self.codexSnapshot.entries.indices.contains(self.codexIndex)
                    ? self.codexSnapshot.entries[self.codexIndex].id : nil
                self.codexSnapshot = snapshot
                if let selectedID, let index = snapshot.entries.firstIndex(where: { $0.id == selectedID }) {
                    self.codexIndex = index
                } else {
                    self.codexIndex = min(self.codexIndex, max(0, snapshot.entries.count - 1))
                }
                self.sync(animated: false)
            }
        }
        if kind != .appWheel { restartOverlayIdleTimer() }
        installEscMonitor()
        showHintBar(HintBarCatalog.hints(for: kind))
        // 捕获遥控键：浮层期间事件不走动作分发（引擎 mainDispatch 保证主线程回调）。
        engine?.setOverlayCapture { [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) }
        }
    }

    func close() {
        guard active != nil else { return }
        active = nil
        powerGeneration &+= 1
        powerMenu.close()
        codexSessions.cancel()
        codexSnapshot = CodexSessions.Snapshot()
        codexIndex = 0
        engine?.setOverlayCapture(nil)
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
        wheelIdleTimer?.invalidate()
        wheelIdleTimer = nil
        overlayIdleTimer?.invalidate()
        overlayIdleTimer = nil
        stopRepeat()
        cancelConfirm(refresh: false)
        // 消失过渡：SwiftUI 侧 kind→nil 驱动缩放淡出，动画结束后仅 orderOut（面板常驻不销毁）
        withAnimation(Motion.overlay) { uiState.kind = nil }
        let closing = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.fadeOutDuration) { [weak self] in
            guard self?.active == nil else { return }   // 淡出期间又打开了新浮层则不收
            closing?.orderOut(nil)
        }
        quickLook.setVisible(false, bundleID: nil, appName: nil)
        restoreContextHints()
    }

    /// 全局返回长按 1.2s 触发：关闭所有浮层与 HUD。层态由引擎自清，
    /// 菜单栏/角标随 onLayerChanged 回到全局态。
    func escapeHatch() {
        close()
        mouseStatusText = nil
        noteLayer(0)
    }

    /// 真键盘 Esc 关闭（浮层不抢焦点，收不到 keyDown，用全局监听兜底；需输入监控权限，已具备）。
    private func installEscMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard ev.keyCode == 53 else { return }
            MainActor.assumeIsolated { self?.close() }
        }
    }

    // MARK: 遥控键路由（uiCapture 捕获回调，主线程）

    private func handleKey(_ event: ButtonEvent) {
        guard let active else { return }
        if active == .appWheel {
            restartWheelIdleTimer()
        } else {
            restartOverlayIdleTimer()
        }
        guard event.isDown else {
            keyUp(event.key)
            return
        }
        switch active {
        case .windowPicker: handlePickerKey(event.key)
        case .systemMenu:   handleMenuKey(event.key)
        case .appWheel:     handleWheelKey(event.key)
        case .codexSessions: handleCodexKey(event.key)
        case .computerPower: handlePowerKey(event.key)
        case .tutorial:
            // 再按 Home / 返回 / OK 关闭；其余键吞掉（教程页不该有副作用）。
            if event.key == .home || event.key == .back || event.key == .ok { close() }
        }
    }

    /// 松键：结束按住连发；OK 松开撤销危险动作确认（gamepad-ux D2/D3）。
    private func keyUp(_ key: RemoteKey) {
        if repeatKey == key { stopRepeat() }
        if key == .ok, confirmingIndex != nil { cancelConfirm(refresh: true) }
    }

    // MARK: 按住加速（gamepad-ux D3：立即 1 步 → 400ms 起 130ms/步 → 1.5s 后 65ms/步）

    private func startRepeat(_ key: RemoteKey, step: @escaping @MainActor () -> Void) {
        stopRepeat()
        repeatKey = key
        let startedAt = Date()
        let t = Timer(timeInterval: 0.13, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, self.repeatKey == key, self.active != nil else {
                    timer.invalidate()
                    return
                }
                step()
                if Date().timeIntervalSince(startedAt) > 1.5 { step() }   // 提速一倍
            }
        }
        t.fireDate = Date().addingTimeInterval(0.4)   // initial delay 防误连发
        RunLoop.main.add(t, forMode: .common)
        repeatTimer = t
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        repeatKey = nil
    }

    private func pickerStep(_ key: RemoteKey) {
        guard !pickerEntries.isEmpty else { return }
        pickerIndex = WindowPickerFlow.movedIndex(pickerIndex, key: key, count: pickerEntries.count)
        sync()
    }

    private func handlePickerKey(_ key: RemoteKey) {
        switch key {
        case .up, .down, .left, .right:
            pickerStep(key)
            startRepeat(key) { [weak self] in self?.pickerStep(key) }
        case .menu:
            // 菜单键固定三段：第一下已打开“全局跨桌面”；
            // 第二下切“当前 App”；第三下关闭。
            guard let next = WindowPickerFlow.nextAfterMenu(currentAppOnly: pickerCurrentAppOnly) else {
                close()
                return
            }
            pickerCurrentAppOnly = next
            reloadPickerEntries()
            sync()
        case .ok:
            if pickerEntries.indices.contains(pickerIndex) {
                let target = pickerEntries[pickerIndex].window
                close()
                WindowSwitcher.activate(target)
            } else {
                close()
            }
        case .back, .home, .tv:
            close()
        default:
            break
        }
    }

    private func menuStep(_ key: RemoteKey) {
        menuIndex = SystemMenuCatalog.move(menuIndex, key: key, rows: SystemMenuCatalog.rowWidths)
        sync()
    }

    private func handleMenuKey(_ key: RemoteKey) {
        switch key {
        case .up, .down, .left, .right:
            cancelConfirm(refresh: false)
            menuStep(key)
            startRepeat(key) { [weak self] in self?.menuStep(key) }
        case .ok:
            let item = SystemMenuCatalog.items[menuIndex]
            if item.dangerous {
                beginConfirm(item: item)
            } else {
                close()
                // 先关浮层再执行：目标动作（如聚焦输入框）需要落在真实前台 App 上。
                runner.run(item.action)
            }
        case .back, .menu, .home:
            close()
        default:
            break
        }
    }

    // MARK: 危险动作 hold-to-confirm（OK 按住 0.6s 填充环，中途松开取消）

    private func beginConfirm(item: SystemMenuItem) {
        guard confirmingIndex == nil else { return }
        confirmingIndex = menuIndex
        let index = menuIndex
        sync()
        let t = Timer(timeInterval: SystemMenuCatalog.confirmHoldSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.confirmingIndex == index else { return }
                self.confirmingIndex = nil
                self.close()
                self.runner.run(SystemMenuCatalog.items[index].action)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        confirmTimer = t
    }

    private func cancelConfirm(refresh: Bool) {
        confirmTimer?.invalidate()
        confirmTimer = nil
        guard confirmingIndex != nil else { return }
        confirmingIndex = nil
        if refresh, active == .systemMenu { sync() }
    }

    /// App 轮盘（停留式）：方向环选 App、OK 或再按 TV 确认切换、返回取消，
    /// 每次按键重置 3s 无操作自动关闭计时。
    private func handleWheelKey(_ key: RemoteKey) {
        restartWheelIdleTimer()
        switch key {
        case .left, .up:
            guard !wheelApps.isEmpty else { return }
            wheelIndex = (wheelIndex - 1 + wheelApps.count) % wheelApps.count
            sync()
        case .right, .down:
            guard !wheelApps.isEmpty else { return }
            wheelIndex = (wheelIndex + 1) % wheelApps.count
            sync()
        case .ok, .tv:
            let target = wheelApps.indices.contains(wheelIndex) ? wheelApps[wheelIndex] : nil
            close()
            if let target { WindowSwitcher.activateApplication(target) }
        case .back, .home, .menu:
            close()
        default:
            break
        }
    }

    private func restartWheelIdleTimer() {
        wheelIdleTimer?.invalidate()
        wheelIdleTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    private func restartOverlayIdleTimer() {
        overlayIdleTimer?.invalidate()
        overlayIdleTimer = nil
        // 系统可能正在等待 Automation 授权或保存文件，结果到达前保留反馈位置。
        if active == .computerPower, powerMenu.isExecuting { return }
        // 会话列表需要阅读标题；给它比图标菜单更长的空闲时间。
        let idleSeconds = active == .codexSessions ? 60 : Self.overlayIdleSeconds
        overlayIdleTimer = Timer.scheduledTimer(withTimeInterval: idleSeconds,
                                                repeats: false) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    private func reloadPickerEntries() {
        pickerEntries = WindowSwitcher.pickerEntries(currentAppOnly: pickerCurrentAppOnly,
                                                     frontPid: frontApp?.processIdentifier)
        pickerIndex = 0
    }

    // MARK: 电脑电源列表

    private func handlePowerKey(_ key: RemoteKey) {
        switch powerMenu.handle(key) {
        case .none:
            sync()
        case .dismiss:
            close()
        case .execute(let request):
            stopRepeat()
            restartOverlayIdleTimer()
            sync(animated: false)
            let token = powerGeneration
            ComputerPower.execute(request) { [weak self] result in
                guard let self, self.active == .computerPower,
                      self.powerGeneration == token else { return }
                if self.powerMenu.complete(result) == .dismiss {
                    self.close()
                } else {
                    self.restartOverlayIdleTimer()
                    self.sync(animated: false)
                }
            }
        }
    }

    // MARK: Codex 本地会话列表

    private func codexStep(_ delta: Int) {
        guard !codexSnapshot.entries.isEmpty else { return }
        codexIndex = CodexSessions.movedIndex(codexIndex, delta: delta,
                                             count: codexSnapshot.entries.count)
        restartOverlayIdleTimer()
        sync()
    }

    private func handleCodexKey(_ key: RemoteKey) {
        switch key {
        case .up, .down, .left, .right:
            let delta = key == .up ? -1 : key == .down ? 1 : key == .left ? -6 : 6
            codexStep(delta)
            startRepeat(key) { [weak self] in self?.codexStep(delta) }
        case .ok:
            guard codexSnapshot.entries.indices.contains(codexIndex) else { return }
            let target = codexSnapshot.entries[codexIndex]
            if CodexSessions.open(target) {
                close()
            } else {
                codexSessions.cancel()
                codexSnapshot.isLoading = false
                codexSnapshot.error = "无法打开 Codex。请确认已安装桌面 App 后重试。"
                sync(animated: false)
            }
        case .back, .home, .tv:
            close()
        default:
            break
        }
    }

    // MARK: 面板（持久 HostingView：视图树只建一次，之后全部走 sync() 状态驱动）

    /// 把逻辑状态发布给持久视图树；选中类变化以 Motion.select 驱动连续过渡（Codex 评审 P2-1）。
    private func sync(animated: Bool = true) {
        let apply = { [self] in
            uiState.kind = active
            uiState.pickerEntries = pickerEntries
            uiState.pickerIndex = pickerIndex
            uiState.pickerCurrentAppOnly = pickerCurrentAppOnly
            uiState.frontAppName = frontApp?.localizedName
            uiState.menuIndex = menuIndex
            uiState.menuConfirming = confirmingIndex != nil
            uiState.wheelEntries = wheelApps.map {
                AppWheelView.Entry(name: $0.localizedName ?? $0.bundleIdentifier ?? "App",
                                   bundleID: $0.bundleIdentifier)
            }
            uiState.wheelIndex = wheelIndex
            uiState.codexSnapshot = codexSnapshot
            uiState.codexIndex = codexIndex
            uiState.powerMenu = powerMenu
        }
        if animated {
            withAnimation(Motion.select) { apply() }
        } else {
            apply()
        }
    }

    /// 常驻面板：NSPanel 与 NSHostingView 全生命周期只创建一次；
    /// show/hide 仅切换 orderFront/orderOut，显隐与入退场动画全部由 uiState.kind 驱动，
    /// 跨次打开视图树连续（Codex r3 P1：不再是"单次打开期间"的伪持久）。
    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(contentRect: NSScreen.main?.frame ?? .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: OverlayRootView(state: uiState,
                                                                onDismiss: { [weak self] in self?.close() }))
        panel = p
        return p
    }

    /// 全屏透明面板承载居中内容：不抢焦点；点空白（内容之外任意处）关闭。
    private func showPanel() {
        let p = ensurePanel()
        if let screen = NSScreen.main { p.setFrame(screen.frame, display: true) }
        uiState.kind = nil       // 入场从隐藏态开始（消失后残留的 kind 已在 close 清空，这里兜底）
        sync(animated: false)    // 数据先无动画就位
        uiState.kind = nil
        p.orderFrontRegardless()
        withAnimation(Motion.overlay) { uiState.kind = active }
    }

    // MARK: per-app profile 切换提示（gamepad-ux ⑦：换布局要让用户知道）

    /// 提示条自动收起时长；令牌防止快速连切 App 时旧定时器收掉新提示。
    private static let profileHintMs = 2500

    /// 前台 App 切换：该 App 若显式改写了基础态键义（如飞书 OK=⌘Enter 发送），
    /// 闪一条提示条。基础态平时不常驻提示条，故到点自动收起。
    /// 浮层打开或已在功能层时不打扰——那两种状态的提示条另有主人。
    func noteProfileSwitch(_ bundleID: String?) {
        guard active == nil, mouseStatusText == nil, model?.activeLayer == 0 else { return }
        profileHintToken &+= 1
        let token = profileHintToken
        guard let model, let bundleID else { hideHintBar(); return }
        let hints = HintBarCatalog.hints(forBaseProfile: bundleID, config: model.config)
        guard !hints.isEmpty else {
            hideHintBar()   // 切到无专属绑定的 App：上一条提示不许残留
            return
        }
        showHintBar(hints)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.profileHintMs)) { [weak self] in
            guard let self, self.profileHintToken == token, self.active == nil,
                  self.mouseStatusText == nil else { return }
            self.hideHintBar()
        }
    }

    // MARK: App 控制模式 HUD（层 2；非捕获，仅提示）

    /// 层变化钩子（GUIAppDelegate 接线）。进层 2 → 弹角落 HUD 列出当前 App 模式键位；
    /// 回层 0 或进入其他层 → 收起。音效由 AppModel.noteLayer（可选提示音）负责。
    func noteLayer(_ layer: Int) {
        // 按键提示条：层激活时显示该层键表（浮层打开期间由浮层键表接管，不在此覆盖）
        if active == nil {
            if let mouseStatusText {
                showHintBar(HintBarCatalog.hintsForMouse(status: mouseStatusText))
            } else if layer != 0, let model {
                showHintBar(HintBarCatalog.hints(forLayer: layer, config: model.config,
                                                 profile: frontApp?.bundleIdentifier ?? "global"))
            } else {
                hideHintBar()
            }
        }
        guard layer == 2 else {
            hudPanel?.orderOut(nil)
            return
        }
        guard let model else { return }
        let bundleID = frontApp?.bundleIdentifier ?? "global"
        let rows = Self.controlModeRows(config: model.config, profile: bundleID)
        let view = ControlModeHUDView(appName: frontApp?.localizedName ?? "当前 App", rows: rows)
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        if hudPanel == nil {
            let p = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.isReleasedWhenClosed = false
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            hudPanel = p
        }
        guard let hudPanel else { return }
        hudPanel.contentView = host
        let size = host.fittingSize
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            hudPanel.setFrame(NSRect(x: f.maxX - size.width - 24, y: f.maxY - size.height - 24,
                                     width: size.width, height: size.height), display: true)
        }
        hudPanel.orderFrontRegardless()
    }

    /// 当前 App 控制模式（层2）键位表：实际生效绑定（global+overlay 合并）。纯函数可测。
    nonisolated static func controlModeRows(config: MappingConfig, profile: String) -> [(String, String)] {
        let order: [RemoteKey] = [.ok, .back, .up, .down, .left, .right,
                                  .volUp, .volDown, .menu, .home, .power]
        var rows: [(String, String)] = []
        for key in order {
            guard let binding = MappingDetailResolver.binding(in: config, profile: profile, key: key),
                  let action = binding.layers?["2"] else { continue }
            rows.append((KeyDisplay.badge(key), ActionSummary.describe(action)))
        }
        rows.append(("TV", "退出控制模式"))
        return rows
    }

    // MARK: 按键提示条面板（屏底半透明横条，可点穿；通用页可关，默认开）

    /// AppModel 状态轮询入口；浮层优先，鼠标模式退出后恢复所在层的提示。
    func updateMouseStatus(text: String?) {
        let normalized = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = normalized?.isEmpty == false ? normalized : nil
        guard mouseStatusText != next else { return }
        mouseStatusText = next
        profileHintToken &+= 1
        guard active == nil else { return }
        if next != nil { hudPanel?.orderOut(nil) }
        restoreContextHints()
    }

    private func restoreContextHints() {
        if let mouseStatusText {
            showHintBar(HintBarCatalog.hintsForMouse(status: mouseStatusText))
        } else if let model, model.activeLayer != 0 {
            showHintBar(HintBarCatalog.hints(forLayer: model.activeLayer, config: model.config,
                                             profile: frontApp?.bundleIdentifier ?? "global"))
        } else {
            hideHintBar()
        }
    }

    private func showHintBar(_ items: [HintBarCatalog.Hint]) {
        guard model?.showHintBar != false, !items.isEmpty else {
            hideHintBar()
            return
        }
        hintVisibilityGeneration &+= 1
        let host = NSHostingView(rootView: HintBarView(items: items))
        host.frame.size = host.fittingSize
        if hintPanel == nil {
            let p = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.isReleasedWhenClosed = false
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            hintPanel = p
        }
        guard let hintPanel else { return }
        hintPanel.contentView = host
        let size = host.fittingSize
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            hintPanel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.minY + 16,
                                      width: size.width, height: size.height), display: true)
        }
        if !hintPanel.isVisible {
            hintPanel.alphaValue = 0
            hintPanel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.fadeInDuration
                hintPanel.animator().alphaValue = 1
            }
        } else {
            hintPanel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.fadeInDuration
                hintPanel.animator().alphaValue = 1
            }
        }
    }

    private func hideHintBar() {
        guard let hintPanel, hintPanel.isVisible else { return }
        hintVisibilityGeneration &+= 1
        let token = hintVisibilityGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.fadeOutDuration
            hintPanel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // 全局入口可立即切换面板，旧淡出回调不能收掉新面板的提示。
            Task { @MainActor in
                guard self?.hintVisibilityGeneration == token else { return }
                hintPanel.orderOut(nil)
                hintPanel.alphaValue = 1
            }
        })
    }

    private func log(_ msg: String) { NSLog("[OverlayCenter] %@", msg) }
}

// MARK: - 按键提示条（gamepad-ux B1：PS5 glyph bar 范式）

enum HintBarCatalog {
    struct Hint {
        let keys: [RemoteKey]
        let text: String
    }

    /// 浮层键表（与各浮层 handleKey 路由保持一致）。
    static func hints(for kind: OverlayCenter.Kind) -> [Hint] {
        switch kind {
        case .windowPicker:
            return [Hint(keys: [.up, .down], text: "选窗口（按住加速）"),
                    Hint(keys: [.left, .right], text: "翻页"),
                    Hint(keys: [.menu], text: "切换范围"),
                    Hint(keys: [.ok], text: "激活"),
                    Hint(keys: [.back], text: "关闭")]
        case .systemMenu:
            return [Hint(keys: [.up, .down, .left, .right], text: "选择"),
                    Hint(keys: [.ok], text: "执行 · 红色项按住"),
                    Hint(keys: [.back], text: "关闭")]
        case .appWheel:
            return [Hint(keys: [.up, .down, .left, .right], text: "选 App"),
                    Hint(keys: [.ok, .tv], text: "切换"),
                    Hint(keys: [.back], text: "取消")]
        case .tutorial:
            return [Hint(keys: [.home, .back, .ok], text: "关闭教程")]
        case .codexSessions:
            return [Hint(keys: [.up, .down], text: "选会话（按住加速）"),
                    Hint(keys: [.left, .right], text: "翻页"),
                    Hint(keys: [.ok], text: "打开"),
                    Hint(keys: [.back, .home, .tv], text: "取消")]
        case .computerPower:
            return [Hint(keys: [.up, .down], text: "选择"),
                    Hint(keys: [.ok], text: "确认"),
                    Hint(keys: [.back, .power], text: "取消")]
        }
    }

    static func hintsForGlobal() -> [Hint] {
        [Hint(keys: [.left, .right], text: "双击 ⌃← / ⌃→"),
         Hint(keys: [.home], text: "双击窗口列表"),
         Hint(keys: [.menu], text: "双击系统面板 · 长按鼠标"),
         Hint(keys: [.tv], text: "单击 Codex · 双击上个 App"),
         Hint(keys: [.power], text: "电脑电源"),
         Hint(keys: [.back], text: "长按 1.2 秒退出当前应用")]
    }

    static func hintsForCodex() -> [Hint] {
        [Hint(keys: [.up, .down], text: "原生方向键"),
         Hint(keys: [.left, .right], text: "单击会话 · 双击 ⌃← / ⌃→"),
         Hint(keys: [.home], text: "单击列表 · 长按新建"),
         Hint(keys: [.menu], text: "单击命令 · 长按鼠标"),
         Hint(keys: [.tv], text: "长按模型"),
         Hint(keys: [.voice], text: "单击聚焦"),
         Hint(keys: [.back], text: "长按 1.2 秒退出当前应用")]
    }

    static func hintsForMouse(status: String = "鼠标模式") -> [Hint] {
        [Hint(keys: [], text: status),
         Hint(keys: [.up, .down, .left, .right], text: "移动 · 左右双击 ⌃← / ⌃→"),
         Hint(keys: [.ok], text: "左键"),
         Hint(keys: [.menu], text: "单击右键 · 长按退出"),
         Hint(keys: [.back], text: "单击退出鼠标 · 长按退出应用")]
    }

    /// 基础态的 per-app 覆盖提示：切到该 App 时闪一下，告诉用户这颗键在这里变了。
    /// 只列 profile 显式声明且基础态确实生效的槽位；Back 必须额外 opt-in，
    /// 与 MappingEngine 的保护保持一致，避免提示条许诺引擎不认的绑定。
    static func hints(forBaseProfile bundleID: String, config: MappingConfig) -> [Hint] {
        if bundleID == "com.openai.codex" { return hintsForCodex() }
        var hints: [Hint] = []
        if let action = config.profiles[bundleID]?["ok"]?.tap {
            hints.append(Hint(keys: [.ok], text: ActionSummary.describe(action)))
        }
        if let binding = config.profiles[bundleID]?["back"], binding.overrideBase == true,
           let action = binding.tap {
            hints.append(Hint(keys: [.back], text: ActionSummary.describe(action)))
        }
        return hints
    }

    /// 层键表：该层每个键的绑定摘要（最多 5 条 + 退出提示），数据与 HUD 同源。
    static func hints(forLayer layer: Int, config: MappingConfig, profile: String) -> [Hint] {
        let order: [RemoteKey] = [.ok, .back, .up, .down, .left, .right, .volUp, .volDown, .menu, .home]
        var result: [Hint] = []
        for key in order {
            guard result.count < 5,
                  let binding = MappingDetailResolver.binding(in: config, profile: profile, key: key),
                  let action = binding.layers?["\(layer)"] else { continue }
            var text = ActionSummary.describe(action)
            if text.count > 10 { text = String(text.prefix(10)) + "…" }
            result.append(Hint(keys: [key], text: text))
        }
        if layer == 2 {
            result.append(Hint(keys: [.tv], text: "退出"))
        } else {
            result.append(Hint(keys: [], text: layer == 1 ? "松开 OK 退出" : "再触发一次退出"))
        }
        return result
    }
}

/// 单键小键帽字形（深底白符，复用 RemoteDiagram 的键面语言）。
struct KeyCapView: View {
    let key: RemoteKey

    private static let symbols: [RemoteKey: String] = [
        .up: "arrow.up", .down: "arrow.down", .left: "arrow.left", .right: "arrow.right",
        .back: "arrow.backward.to.line", .home: "house", .menu: "line.3.horizontal",
        .tv: "tv", .power: "power", .voice: "mic",
        .volUp: "plus", .volDown: "minus",
    ]

    var body: some View {
        Group {
            if let symbol = Self.symbols[key] {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
            } else {
                Text(key == .ok ? "OK" : KeyDisplay.badge(key))
                    .font(.system(size: 10, weight: .bold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: 24, height: 24)
        .background(Color(red: 0.11, green: 0.11, blue: 0.12),
                    in: RoundedRectangle(cornerRadius: Radius.small))
    }
}

/// 屏底提示条：键帽字形 + 短词，随模式/浮层自动换文案。
struct HintBarView: View {
    let items: [HintBarCatalog.Hint]

    var body: some View {
        HStack(spacing: Spacing.rowH) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 5) {
                    ForEach(item.keys, id: \.self) { key in KeyCapView(key: key) }
                    Text(item.text).font(.callout)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

// MARK: - 视图

/// 持久根视图：观察 OverlayUIState，选中变化在既有视图树内做连续动画；
/// 入退场也由 kind 驱动（打开=spring 弹入，关闭=缩放淡出），视图树跨次打开不重建。
private struct OverlayRootView: View {
    @ObservedObject var state: OverlayUIState
    let onDismiss: () -> Void

    private var visible: Bool { state.kind != nil }

    var body: some View {
        ZStack {
            // 轻度压暗背景（主机浮层惯例）：突出浮层层级，点空白关闭
            Color.black.opacity(visible ? 0.18 : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
            Group {
                switch state.kind {
                case .windowPicker:
                    WindowPickerView(entries: state.pickerEntries,
                                     selected: state.pickerIndex,
                                     currentAppOnly: state.pickerCurrentAppOnly,
                                     frontAppName: state.frontAppName)
                case .systemMenu:
                    SystemMenuView(selected: state.menuIndex, confirming: state.menuConfirming)
                case .appWheel:
                    AppWheelView(apps: state.wheelEntries, selected: state.wheelIndex)
                case .codexSessions:
                    CodexSessionsView(snapshot: state.codexSnapshot, selected: state.codexIndex)
                case .computerPower:
                    PowerMenuView(state: state.powerMenu)
                default:
                    EmptyView()
                }
            }
            .scaleEffect(visible ? 1 : 0.96)
            .opacity(visible ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 窗口与会话使用相同的纵向列表语义，避免上下键在两种面板里承担不同职责。
private struct WindowPickerView: View {
    let entries: [WindowSwitcher.PickerEntry]
    let selected: Int
    let currentAppOnly: Bool
    let frontAppName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "macwindow.on.rectangle")
                Text("窗口列表").font(.headline)
                Spacer()
                if !entries.isEmpty {
                    Text("\(selected + 1) / \(entries.count)")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Text(currentAppOnly ? "当前 App · \(frontAppName ?? "当前应用")"
                                : "所有 App · 全部桌面")
                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            if entries.isEmpty {
                Text(currentAppOnly ? "当前 App 没有可见窗口，按菜单键查看所有 App"
                                    : "没有可见窗口")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).frame(height: 150)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(entries.enumerated()), id: \.element.window.windowID) { index, entry in
                                row(entry, selected: index == selected).id(entry.window.windowID)
                            }
                        }
                        .padding(.horizontal, 4).padding(.vertical, 5)
                    }
                    .frame(height: 360)
                    .onAppear { scroll(proxy) }
                    .onChange(of: selected) { _, _ in scroll(proxy) }
                    .onChange(of: entries.map(\.window.windowID)) { _, _ in scroll(proxy) }
                }
            }
        }
        .padding(Spacing.sheetPadding)
        .frame(width: 660)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.overlay))
        .overlay(RoundedRectangle(cornerRadius: Radius.overlay)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        .shadow(radius: 24, y: 8)
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard entries.indices.contains(selected) else { return }
        withAnimation(Motion.select) {
            proxy.scrollTo(entries[selected].window.windowID, anchor: .center)
        }
    }

    private func row(_ entry: WindowSwitcher.PickerEntry, selected: Bool) -> some View {
        HStack(spacing: 12) {
            appIcon(entry.bundleID).frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.window.title.isEmpty ? entry.appName : entry.window.title)
                    .font(.body.weight(selected ? .semibold : .regular)).lineLimit(1)
                Text(entry.appName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(minHeight: 50)
        .background(selected ? Color.accentColor.opacity(0.14) : Color.clear,
                    in: RoundedRectangle(cornerRadius: Radius.small))
        .overlay(RoundedRectangle(cornerRadius: Radius.small)
            .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private func appIcon(_ bundleID: String?) -> some View {
        if let bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        } else {
            Image(systemName: "app.dashed").font(.title).foregroundStyle(.secondary)
        }
    }
}

/// 系统功能菜单：3 列网格，方向键选择、OK 执行；危险项标红且 OK 按住填充确认。
private struct SystemMenuView: View {
    let selected: Int
    var confirming = false

    var body: some View {
        VStack(spacing: 12) {
            // 操作提示只保留屏底 HintBar 一份（权威），头部不再重复
            HStack(spacing: 8) {
                Image(systemName: "square.grid.3x3")
                Text("系统功能").font(.headline)
                Spacer()
            }
            let normal = SystemMenuCatalog.items.enumerated().filter { !$0.element.dangerous }
            let dangerous = SystemMenuCatalog.items.enumerated().filter { $0.element.dangerous }
            let columns = Array(repeating: GridItem(.fixed(188), spacing: 12),
                                count: SystemMenuCatalog.columns)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(normal, id: \.offset) { index, item in
                    tile(item, index: index)
                }
            }
            Divider().padding(.vertical, 2)
            HStack(spacing: 12) {
                ForEach(dangerous, id: \.offset) { index, item in
                    tile(item, index: index)
                }
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.overlay))
        .overlay(RoundedRectangle(cornerRadius: Radius.overlay)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        .shadow(radius: 24, y: 8)
    }

    @ViewBuilder
    private func tile(_ item: SystemMenuItem, index: Int) -> some View {
        let isSelected = index == selected
        VStack(spacing: 6) {
            Image(systemName: item.symbol).font(.system(size: 28))
            Text(item.title).font(.callout)
            if item.dangerous {
                Text("按住 OK 确认").font(.caption).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(item.dangerous ? Color.red : Color.primary)
        .frame(width: 180, height: 96)
        .background(Color(nsColor: .controlBackgroundColor)
            .opacity(isSelected ? 1 : 0.55),
            in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card)
            .stroke(isSelected ? (item.dangerous ? Color.red : Color.accentColor) : .clear, lineWidth: 2.5))
        .overlay(alignment: .topTrailing) {
            if isSelected, confirming {
                ConfirmRingView(duration: SystemMenuCatalog.confirmHoldSeconds)
                    .padding(5)
            }
        }
        .shadow(color: isSelected ? (item.dangerous ? Color.red : Color.accentColor).opacity(0.4) : .clear,
                radius: 6)
        .scaleEffect(isSelected ? 1.06 : 1)
    }
}

/// hold-to-confirm 填充环：出现后在 duration 内线性填满（执行时机由 OverlayCenter 计时器掌握）。
private struct ConfirmRingView: View {
    let duration: TimeInterval
    @State private var progress: Double = 0

    var body: some View {
        ZStack {
            Circle().stroke(Color.red.opacity(0.25), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.red, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 24, height: 24)
        .onAppear { withAnimation(.linear(duration: duration)) { progress = 1 } }
    }
}

/// App 轮盘（停留式）：图标沿圆环排布，中心显示选中 App 名与操作提示。
struct AppWheelView: View {
    struct Entry {
        let name: String
        let bundleID: String?
    }
    let apps: [Entry]
    let selected: Int

    private let radius: CGFloat = 140

    var body: some View {
        VStack(spacing: 10) {
            if apps.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "circle.dashed").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("暂无最近使用的 App").font(.callout)
                    Text("切换过几个 App 后再试；3 秒后自动关闭").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 30)
            } else {
                wheel
            }
            Text("3 秒无操作自动关闭")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(Spacing.sheetPadding)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.overlay))
        .overlay(RoundedRectangle(cornerRadius: Radius.overlay)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        .shadow(radius: 24, y: 8)
    }

    private var wheel: some View {
        ZStack {
            Circle()
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                .frame(width: radius * 2, height: radius * 2)
            wheelCenter
            wheelIcons
        }
        .frame(width: radius * 2 + 104, height: radius * 2 + 104)
    }

    private var wheelIcons: some View {
        ForEach(apps.indices, id: \.self) { index in
            let angle = Double(index) / Double(apps.count) * 2 * .pi - .pi / 2
            WheelIcon(
                entry: apps[index],
                isSelected: index == selected,
                x: radius * CGFloat(cos(angle)),
                y: radius * CGFloat(sin(angle))
            )
        }
    }

    private var wheelCenter: some View {
        VStack(spacing: 3) {
            Text(apps.indices.contains(selected) ? apps[selected].name : "")
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: radius * 1.3)
            Text(selected == 0 ? "当前前台" : "最近使用")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 3) {
                Image(systemName: "xmark.circle.fill")
                Text("返回取消")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 3)
        }
    }

}

private struct WheelIcon: View {
    let entry: AppWheelView.Entry
    let isSelected: Bool
    let x: CGFloat
    let y: CGFloat

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let bundleID = entry.bundleID,
                   let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
                } else {
                    Image(systemName: "app.dashed").font(.title).foregroundStyle(.secondary)
                }
            }
            .frame(width: isSelected ? 78 : 58, height: isSelected ? 78 : 58)
            .background(Circle().fill(Color(nsColor: .controlBackgroundColor))
                .padding(-7)
                .shadow(color: isSelected ? Color.accentColor.opacity(0.5) : .clear, radius: 6))
            .overlay(Circle()
                .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2.5)
                .padding(-7))
        }
        .animation(Motion.select, value: isSelected)
        .offset(x: x, y: y)
    }
}

/// App 控制模式角落 HUD：列出模式内键位含义（非捕获，可点穿）。
private struct ControlModeHUDView: View {
    let appName: String
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(Color.accentColor)
                Text("App 控制模式 · \(appName)")
                    .font(.callout.weight(.semibold))
            }
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    Text(row.0)
                        .font(.caption2.weight(.bold))
                        .frame(width: 38, height: 18)
                        .background(Color.accentColor.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: Radius.small))
                    Text(row.1).font(.caption).lineLimit(1)
                }
            }
        }
        .padding(12)
        .frame(width: 240, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.hud))
        .overlay(RoundedRectangle(cornerRadius: Radius.hud)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}
