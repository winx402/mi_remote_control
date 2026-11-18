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
    /// 网格条目（3 列）。全部走 ActionRunner 既有能力；危险项标红并集中排在末尾。
    static let items: [SystemMenuItem] = [
        .init(title: "调度中心",   symbol: "square.grid.3x2",             action: .system("mission_control")),
        .init(title: "应用窗口",   symbol: "square.on.square",            action: .system("app_expose")),
        .init(title: "显示桌面",   symbol: "menubar.dock.rectangle",      action: .system("show_desktop")),
        .init(title: "左侧桌面",   symbol: "arrow.left.square",           action: .system("space_left")),
        .init(title: "右侧桌面",   symbol: "arrow.right.square",          action: .system("space_right")),
        .init(title: "聚焦编辑区", symbol: "cursorarrow.and.square.on.square.dashed", action: .focusInput),
        .init(title: "播放 / 暂停", symbol: "playpause",                   action: .system("play_pause")),
        .init(title: "静音",       symbol: "speaker.slash",               action: .system("mute")),
        .init(title: "MiRemote 设置", symbol: "gearshape",                action: .overlay("open_settings")),
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

    static func rowWidths(favoriteCount: Int) -> [Int] {
        (favoriteCount > 0 ? [min(6, favoriteCount)] : []) + rowWidths
    }

    static func systemIndex(_ selected: Int, favoriteCount: Int) -> Int? {
        let index = selected - favoriteCount
        return items.indices.contains(index) ? index : nil
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
            && move(5, key: .down, rows: rowWidths(favoriteCount: 6)) == 8
            && move(7, key: .up, rows: rowWidths(favoriteCount: 6)) == 1
            && move(0, key: .left, rows: rowWidths(favoriteCount: 6)) == 17
            && systemIndex(5, favoriteCount: 6) == nil
            && systemIndex(6, favoriteCount: 6) == 0
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
    @Published var douyinItems = DouyinMenuItem.functions
    @Published var douyinMenuError: String?
    @Published var menuIndex = 0
    @Published var menuConfirming = false
    @Published var menuApps: [DockApplications.Entry] = []
    @Published var runningControlAppIDs: Set<String> = []
    @Published var wheelEntries: [AppWheelView.Entry] = []
    @Published var wheelIndex = 0
    @Published var codexSettings = CodexSessionSettingsPanel()
    @Published var codexSnapshot = CodexSessions.Snapshot()
    @Published var codexList = CodexSessionList(entries: [])
    @Published var isLaunchingCodexChat = false
    @Published var codexSelection = CodexSessionList.Selection()
    @Published var powerMenu = PowerMenuState()
    @Published var televisionPowerStatus: String?
    @Published var powerConfirmingID: String?
    @Published var powerGeneration: UInt64 = 0
    @Published var confirmationInputGeneration: UInt64 = 0
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
        case douyinCategories = "douyin_categories"
        case douyinLive = "douyin_live"
        case douyinRooms = "douyin_rooms"
        var isDouyinMenu: Bool { self == .douyinLive || self == .douyinCategories || self == .douyinRooms }
        case systemMenu = "system_menu"
        case tutorial = "tutorial"
        case appWheel = "app_wheel"
        case codexSessions = "codex_sessions"
        case codexSettings = "codex_settings"
        case computerPower = "computer_power"
        case televisionPower = "television_power"
    }

    private weak var model: AppModel?
    private weak var services: AppServices?
    private let runner = ActionRunner()
    private let quickLook: MappingQuickLookController

    private var active: Kind?
    var hasActiveOverlay: Bool { active != nil }
    var onActiveChanged: (() -> Void)?
    private var panel: NSPanel?
    private let uiState = OverlayUIState()
    private var escMonitor: Any?

    // 窗口选择器状态
    private var pickerEntries: [WindowSwitcher.PickerEntry] = []
    private var pickerIndex = 0
    private var pickerCurrentAppOnly = false
    // 系统功能菜单状态
    private var douyinRootItems: [DouyinMenuItem] = []
    // Keep the other root layout only for this opening of the live menu.
    private var alternateDouyinItems: [DouyinMenuItem]?
    private var showsMoreDouyinSettings: Bool { douyinRootItems.contains(.collapseMore) }
    private var readingDouyinOptions = false
    private var douyinMenuGeneration: UInt64 = 0
    private var douyinReadTask: Task<Void, Never>?
    private var douyinPendingGroup: DouyinLiveOptions.Group?
    private var douyinNativeReadDepth = 0
    private var douyinMenuOpenedAt: TimeInterval?
    private var douyinHomeTask: Task<Void, Never>?
    private var douyinHomePending = false
    private var douyinHomeGeneration: UInt64 = 0
    private var menuIndex = 0
    private var menuApps: [DockApplications.Entry] = []
    private var runningControlAppIDs: Set<String> = []
    private var controlApplicationObservers: [NSObjectProtocol] = []
    // App 轮盘状态（停留式，DESIGN §3.1b：TV 长按弹出后松手停留，3s 无操作自动关）
    private var wheelApps: [NSRunningApplication] = []
    private var wheelIndex = 0
    private var wheelIdleTimer: Timer?
    private let codexSessions = CodexSessions()
    private var codexSettingsTask: Task<Void, Never>?
    private var codexSettingsEpoch: UInt64 = 0
    private var codexSnapshot = CodexSessions.Snapshot()
    private var codexList = CodexSessionList(entries: [])
    private var codexSelection = CodexSessionList.Selection()
    private var codexLaunchTask: Task<Void, Never>?
    private var browsedSessions = false
    private var powerMenu = PowerMenuState()
    private var powerApplication: NSRunningApplication?
    private var televisionPowerStatus: String?
    private var televisionMenu = TelevisionPowerMenuState()
    private var televisionMenuConfiguration: XiaomiTVConfiguration?
    private final class TelevisionCleanup { var requested = false }
    private var televisionCleanup: TelevisionCleanup?
    private var televisionMonitor: Timer?
    private var televisionCheckInFlight = false
    private var televisionDeadline: ContinuousClock.Instant?
    private var televisionContextGeneration: UInt64 = 0
    private var powerConfirmingID: String?
    private var powerConfirmTimer: Timer?
    private var powerOKHeld = false
    private var powerGeneration: UInt64 = 0
    /// 窗口选择/系统菜单/教程不应无限占用遥控路由；10s 无操作自动收起。
    private static let overlayIdleSeconds: TimeInterval = 10
    private var overlayIdleTimer: Timer?
    private var overlayIdleGeneration: UInt64 = 0
    // App 控制模式 HUD
    private var hudPanel: NSPanel?
    // 按键提示条（gamepad-ux B1：模式/浮层激活时屏底常驻）
    private var hintPanel: NSPanel?
    private var hintVisibilityGeneration: UInt64 = 0
    /// profile 切换提示的自增令牌（见 noteProfileSwitch）。
    private var profileHintToken = 0
    private var mouseStatusText: String?
    private var dockNavigationActive = false
    private var applicationNavigationMode: AppNavigationMode?
    private var applicationNavigationEditing = false
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
        let canonical = name == "system_menu" ? "computer_power" : name
        guard active?.rawValue != canonical else { return }
        open(name)
    }

    func open(_ name: String, wakeTelevision: Bool = false) {
        if name == "open_settings" {
            close()
            onOpenSettings?()
            return
        }
        guard let requestedKind = Kind(rawValue: name) else {
            log("未知浮层名: \(name)")
            return
        }
        let kind: Kind = requestedKind == .systemMenu ? .computerPower : requestedKind
        if kind == .televisionPower, active != kind, !XiaomiTVController.shared.isIdle {
            log("电视控制繁忙，未重复请求电源菜单")
            return
        }
        if active == kind {
            // The TV may have been put to sleep by another remote while this
            // panel remained open. A physical power press still attempts WAKEUP.
            if kind == .computerPower, wakeTelevision {
                ActionRunner.configureTelevision(model?.config.television)
                if XiaomiTVController.shared.isConfigured {
                    XiaomiTVController.shared.perform(.wake) { [weak self] result in
                        if case .failure(let failure) = result { self?.log("电视唤醒：\(failure.message)") }
                    }
                }
            }
            close()
            return
        }
        invalidateDouyinHome()
        if active != nil { close() }
        if kind == .codexSettings || kind.isDouyinMenu || kind == .windowPicker || kind == .systemMenu || kind == .computerPower || kind == .televisionPower {
            MouseMode.shared.deactivate()
            mouseStatusText = nil
        }
        profileHintToken &+= 1
        active = kind
        if kind.isDouyinMenu { douyinMenuOpenedAt = ProcessInfo.processInfo.systemUptime }
        onActiveChanged?()
        switch kind {
        case .douyinCategories:
            uiState.douyinItems = DouyinMenuItem.categories
            menuIndex = DouyinFeedNavigation.currentCategoryName().flatMap { name in
                uiState.douyinItems.firstIndex(of: .category(name))
            } ?? 0
            showPanel()
        case .douyinRooms:
            panel?.orderOut(nil)
            switch DouyinControls.readLiveRooms() {
            case .success(let names) where !names.isEmpty:
                uiState.douyinItems = names.map(DouyinMenuItem.room)
                menuIndex = 0
                showPanel()
            case .success:
                close()
                reportDouyinError("关注列表目前没有正在直播的主播")
                return
            case .failure(let error):
                close()
                reportDouyinError(error.localizedDescription)
                return
            }
        case .douyinLive:
            loadDouyinLiveMenu()
        case .windowPicker:
            pickerCurrentAppOnly = false
            reloadPickerEntries()
            showPanel()
        case .systemMenu:
            menuIndex = 0
            let available: [DockApplications.Entry]
            if let ids = model?.config.menuFavoriteApps {
                available = ids.compactMap { DockApplications.resolve($0) }
            } else {
                available = DockApplications.pinned()
            }
            var seenApps = Set<String>()
            menuApps = Array(available.filter { seenApps.insert($0.id).inserted }.prefix(6))
            showPanel()
        case .computerPower:
            powerGeneration &+= 1
            reloadControlApplications()
            ActionRunner.configureTelevision(model?.config.television)
            let foreground = NSWorkspace.shared.frontmostApplication
            powerApplication = (foreground?.processIdentifier == NSRunningApplication.current.processIdentifier
                ? frontApp : foreground).flatMap {
                    $0.activationPolicy == .regular && !$0.isTerminated
                        && $0.processIdentifier != NSRunningApplication.current.processIdentifier ? $0 : nil
                }
            powerMenu.open(choices: controlPowerChoices())
            observeControlApplications()
            televisionPowerStatus = nil
            if wakeTelevision, XiaomiTVController.shared.isConfigured {
                televisionPowerStatus = "正在尝试唤醒电视…"
                let token = powerGeneration
                XiaomiTVController.shared.perform(.wake) { [weak self] result in
                    guard let self, self.active == .computerPower, self.powerGeneration == token else { return }
                    switch result {
                    case .success: self.televisionPowerStatus = "唤醒指令已送达；电视已开启时保持当前状态。"
                    case .failure(let failure): self.televisionPowerStatus = "唤醒未获确认：" + failure.message
                    }
                    self.sync(animated: false)
                }
            }
            showPanel()
        case .televisionPower:
            televisionContextGeneration &+= 1
            let contextGeneration = televisionContextGeneration
            ActionRunner.configureTelevision(model?.config.television)
            let configuration = model?.config.television
            televisionMenuConfiguration = configuration
            powerGeneration &+= 1
            televisionMenu = TelevisionPowerMenuState()
            televisionDeadline = ContinuousClock().now.advanced(by: .seconds(60))
            let cleanup = TelevisionCleanup()
            televisionCleanup = cleanup
            // The TV already displays its own power menu. Keep only remote-key
            // routing here; no Mac confirmation page or invisible mouse blocker.
            uiState.kind = nil
            panel?.orderOut(nil)
            let token = powerGeneration
            XiaomiTVController.shared.perform(.powerMenu, matching: configuration) { [weak self] result in
                guard let self else { return }
                guard self.active == .televisionPower, self.powerGeneration == token else {
                    if cleanup.requested, self.televisionContextGeneration == contextGeneration,
                       TelevisionPowerMenuState.mayHaveOpened(result) {
                        XiaomiTVController.shared.dismissPowerMenu(matching: configuration)
                    }
                    return
                }
                self.televisionMenu.opened(result)
                guard self.televisionMenu.mayBeOpen else {
                    self.log("电视电源菜单：\(self.televisionMenu.message)")
                    self.close(dismissTelevisionMenu: false)
                    return
                }
                self.startTelevisionMonitor()
            }
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
        case .codexSettings:
            uiState.codexSettings = CodexSessionSettingsPanel()
            showPanel()
            reloadCodexSettings()
        case .codexSessions:
            let identity = CodexSessionIdentity.capture()
            browsedSessions = false
            codexSelection = .dot
            codexSnapshot = CodexSessions.Snapshot(isLoading: true)
            codexList = CodexSessionList(entries: [])
            showPanel()
            codexSessions.load(identity: identity) { [weak self] incoming in
                guard let self, self.active == .codexSessions else { return }
                let list = CodexSessionList(entries: incoming.entries, sidebarProjects: incoming.sidebarProjects)
                self.codexSelection = list.selection(after: self.codexList, prior: self.codexSelection,
                                                     browsed: self.browsedSessions, currentKey: incoming.currentIdentityKey)
                self.codexList = list
                self.codexSnapshot = incoming
                self.sync(animated: false)
            }
        }
        // Controller rejection can complete synchronously and close this mode.
        // Never reinstall a capture after that close has released it.
        guard active == kind else { return }
        if kind != .appWheel { restartOverlayIdleTimer() }
        installEscMonitor()
        if kind == .televisionPower || kind.isDouyinMenu { hideHintBar() }
        else { showHintBar(HintBarCatalog.hints(for: kind)) }
        // 捕获遥控键：浮层期间事件不走动作分发（引擎 mainDispatch 保证主线程回调）。
        engine?.setOverlayCapture({ [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) }
        }, immediateDirections: kind == .codexSettings || kind.isDouyinMenu || kind == .systemMenu || kind == .computerPower || kind == .televisionPower,
           prioritizeNavigationTaps: kind == .codexSettings || kind.isDouyinMenu)
    }

    func close(dismissTelevisionMenu: Bool = true) {
        guard active != nil else { return }
        let abandoningTV = active == .televisionPower && !dismissTelevisionMenu
        let dismissTV = active == .televisionPower && dismissTelevisionMenu && televisionMenu.mayBeOpen
        televisionCleanup?.requested = active == .televisionPower && dismissTelevisionMenu && televisionMenu.isLoading
        let televisionConfiguration = televisionMenuConfiguration
        active = nil
        invalidateDouyinRead()
        douyinMenuOpenedAt = nil
        douyinRootItems.removeAll()
        alternateDouyinItems = nil
        uiState.douyinMenuError = nil
        onActiveChanged?()
        powerGeneration &+= 1
        powerMenu.close()
        powerApplication = nil
        for observer in controlApplicationObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        controlApplicationObservers.removeAll()
        televisionPowerStatus = nil
        televisionMenu = TelevisionPowerMenuState()
        televisionMenuConfiguration = nil
        televisionCleanup = nil
        televisionDeadline = nil
        televisionMonitor?.invalidate()
        televisionMonitor = nil
        televisionCheckInFlight = false
        cancelPowerConfirmation(refresh: false)
        powerOKHeld = false
        if dismissTV { XiaomiTVController.shared.dismissPowerMenu(matching: televisionConfiguration) }
        else if abandoningTV { XiaomiTVController.shared.abandonMenuNavigation(matching: televisionConfiguration) }
        codexSettingsEpoch &+= 1
        codexSettingsTask?.cancel()
        codexSettingsTask = nil
        codexLaunchTask?.cancel()
        codexLaunchTask = nil
        codexSessions.cancel()
        codexSnapshot = CodexSessions.Snapshot()
        codexList = CodexSessionList(entries: [])
        codexSelection = CodexSessionList.Selection()
        engine?.setOverlayCapture(nil)
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
        wheelIdleTimer?.invalidate()
        wheelIdleTimer = nil
        overlayIdleTimer?.invalidate()
        overlayIdleTimer = nil
        overlayIdleGeneration &+= 1
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
        invalidateDouyinHome()
        close()
        mouseStatusText = nil
        noteLayer(0)
    }

    /// 真键盘 Esc 关闭（浮层不抢焦点，收不到 keyDown，用全局监听兜底；需输入监控权限，已具备）。
    private func installEscMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard ev.keyCode == 53,
                  ev.cgEvent?.getIntegerValueField(.eventSourceUserData) != DockNavigationController.syntheticEventTag,
                  ev.cgEvent?.getIntegerValueField(.eventSourceUserData) != AppNavigationAccessibility.syntheticEventTag else { return }
            MainActor.assumeIsolated {
                if self?.active == .codexSettings { self?.backFromCodexSettings() }
                else { self?.close() }
            }
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
        case .douyinLive, .douyinCategories, .douyinRooms:
            // Navigation out of an in-flight native read must never wait for it.
            if readingDouyinOptions, [.up, .left, .down, .right, .ok].contains(event.key) { return }
            if active == .douyinCategories && (event.key == .left || event.key == .right) { return }
            switch event.key {
            case .up, .left, .down, .right:
                let step = { [weak self] in
                    guard let self, let size = self.panel?.contentView?.bounds.size else { return }
                    let layout = DouyinMenuLayout(items: self.uiState.douyinItems, availableSize: size)
                    self.menuIndex = layout.move(self.menuIndex, key: event.key)
                    self.sync()
                }
                step()
                startRepeat(event.key, step: step)
            case .ok:
                if uiState.douyinItems.indices.contains(menuIndex) {
                    performDouyinAction(uiState.douyinItems[menuIndex])
                }
            case .home:
                if active == .douyinCategories { close() }
                else {
                    dismissDouyinMenu()
                    _ = handleDouyinShortcut(.home) { self.open($0) }
                }
            case .back: backFromDouyinMenu()
            case .menu:
                if showsMoreDouyinSettings { toggleDouyinMenuSize() }
                else { close() }
            default: break
            }
        case .windowPicker: handlePickerKey(event.key)
        case .systemMenu:   handleMenuKey(event.key)
        case .appWheel:     handleWheelKey(event.key)
        case .codexSessions: handleCodexKey(event.key)
        case .codexSettings: handleCodexSettingsKey(event.key)
        case .computerPower: handlePowerKey(event.key)
        case .televisionPower: handleTelevisionPowerKey(event.key)
        case .tutorial:
            // 再按 Home / 返回 / OK 关闭；其余键吞掉（教程页不该有副作用）。
            if event.key == .home || event.key == .back || event.key == .ok { close() }
        }
    }

    /// 松键：结束按住连发；OK 松开撤销危险动作确认（gamepad-ux D2/D3）。
    private func keyUp(_ key: RemoteKey) {
        if key == .ok {
            powerOKHeld = false
            cancelPowerConfirmation(refresh: true)
        }
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

    func handleDouyinShortcut(_ key: RemoteKey, openMenu: @escaping (String) -> Void) -> Bool {
        // A delayed short tap belongs to the app that received the original press.
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.bytedance.douyin.desktop" else { return true }
        if key == .home, douyinHomeTask != nil {
            douyinHomePending = true
            CodexNavigation.showNotice("返回首页后将打开栏目菜单")
            return true
        }
        let page = DouyinFeedNavigation.shortcutPage()
        if key == .home {
            if case .category = page {
                openMenu(Kind.douyinCategories.rawValue)
            } else {
                beginDouyinHome(checkMiniWindow: page == nil, openMenu: openMenu)
            }
            return true
        }
        guard let page else {
            if key == .menu, DouyinLiveOptions.isMiniWindow() {
                openMenu(Kind.douyinLive.rawValue)
            } else {
                reportDouyinError("正在等待抖音页面加载，请稍后再按一次")
            }
            return true
        }
        switch (key, page) {
        case (.menu, .category("关注")):
            openMenu(Kind.douyinRooms.rawValue)
        case (.menu, .liveRoom):
            openMenu(Kind.douyinLive.rawValue)
        default: return false
        }
        return true
    }

    private func invalidateDouyinHome() {
        douyinHomeGeneration &+= 1
        douyinHomeTask?.cancel()
        douyinHomeTask = nil
        douyinHomePending = false
    }

    private func beginDouyinHome(checkMiniWindow: Bool, openMenu: @escaping (String) -> Void) {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        invalidateDouyinRead()
        invalidateDouyinHome()
        let generation = douyinHomeGeneration
        let started = ProcessInfo.processInfo.systemUptime
        CodexNavigation.showNotice("正在返回推荐首页…")
        log("DOUYIN_HOME_STARTED generation=\(generation)")
        douyinHomeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.douyinHomeGeneration == generation {
                    self.douyinHomeTask = nil
                    self.douyinHomePending = false
                }
            }
            // Give an interrupted native read one turn to observe invalidation and
            // release its operation lock before Home starts changing the page.
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, self.active == nil,
                  self.douyinHomeGeneration == generation,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            while self.douyinNativeReadDepth > 0 {
                try? await Task.sleep(for: .milliseconds(20))
                guard !Task.isCancelled, self.active == nil,
                      self.douyinHomeGeneration == generation,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            }
            DouyinFeedNavigation.resetSelection()
            let cancelled = { [weak self] in
                guard let self else { return true }
                return self.douyinHomeGeneration != generation || self.active != nil
            }
            let error: String?
            if checkMiniWindow, DouyinLiveOptions.isMiniWindow() {
                error = DouyinLiveOptions.returnToLargeWindow() ?? DouyinControls.goHome(shouldCancel: cancelled)
            } else {
                error = DouyinControls.goHome(shouldCancel: cancelled)
            }
            guard self.douyinHomeGeneration == generation,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            let pending = self.douyinHomePending
            self.douyinHomeTask = nil
            self.douyinHomePending = false
            self.log("DOUYIN_HOME_COMPLETED generation=\(generation) elapsed_ms=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) success=\(error == nil)")
            self.reportDouyinError(error)
            if error == nil, pending, self.active == nil {
                openMenu(Kind.douyinCategories.rawValue)
            }
        }
    }

    private func dismissDouyinMenu() {
        close()
        // Remove the full-screen hit target before operating the player below it.
        panel?.orderOut(nil)
    }

    /// Every read belongs to one visible menu route. Invalidating before changing
    /// route also prevents RunLoop-driven native reads from publishing after Back.
    private func invalidateDouyinRead() {
        douyinMenuGeneration &+= 1
        douyinReadTask?.cancel()
        douyinReadTask = nil
        readingDouyinOptions = false
        douyinPendingGroup = nil
    }

    private func douyinSelectionID(_ item: DouyinMenuItem) -> String {
        switch item {
        case .collapseMore: return "group:native"
        case .playerGroup(let group): return "group:" + group.id
        case .playerOption(let group, let option): return "option:" + group.id + ":" + option.id
        default: return String(describing: item)
        }
    }

    private func setDouyinItems(_ items: [DouyinMenuItem], focusing groupID: String? = nil) {
        let selectedID = uiState.douyinItems.indices.contains(menuIndex)
            ? douyinSelectionID(uiState.douyinItems[menuIndex]) : nil
        uiState.douyinItems = items
        let focusID = groupID.map { "group:" + $0 } ?? selectedID
        menuIndex = items.firstIndex { douyinSelectionID($0) == focusID } ?? min(menuIndex, max(0, items.count - 1))
    }

    private func douyinRootMenu(groups: [DouyinLiveOptions.Group], needsRetry: Bool,
                                startingWith initial: [DouyinMenuItem] = DouyinMenuItem.playbackControls) -> [DouyinMenuItem] {
        var items = initial
        for section in ["播放器设置", "弹幕设置", "礼物设置"] {
            items += groups.filter { DouyinMenuItem.groupSection($0) == section }.map(DouyinMenuItem.playerGroup)
            if section == "播放器设置", needsRetry { items.append(.retryPlayerOptions) }
        }
        items += DouyinMenuItem.roomControls
        return items
    }

    private func loadDouyinLiveMenu(focusing groupID: String? = nil) {
        guard active == .douyinLive else { return }
        invalidateDouyinRead()
        uiState.douyinMenuError = nil
        // Useful controls appear before any AX request. A live refresh leaves the
        // existing controls and selection visible until its replacement is ready.
        if douyinRootItems.isEmpty {
            douyinRootItems = DouyinMenuItem.functions
            menuIndex = 0
        }
        setDouyinItems(douyinRootItems, focusing: groupID)
        showPanel()
        let generation = douyinMenuGeneration
        let started = ProcessInfo.processInfo.systemUptime
        log("DOUYIN_MENU_VISIBLE generation=\(generation) elapsed_ms=\(Int((started - (douyinMenuOpenedAt ?? started)) * 1000))")
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active == .douyinLive, self.douyinMenuGeneration == generation else { return }
            self.panel?.displayIfNeeded()
            self.log("DOUYIN_MENU_RENDERED generation=\(generation) elapsed_ms=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))")
        }
        douyinReadTask = Task { @MainActor [weak self] in
            let result = await DouyinLiveOptions.discoverMenu()
            guard let self, !Task.isCancelled, self.active == .douyinLive,
                  self.douyinMenuGeneration == generation else { return }
            let items: [DouyinMenuItem]
            switch result {
            case .success(let discovery):
                items = discovery.isMiniWindow ? [.returnToLargeWindow]
                    : self.douyinRootMenu(groups: discovery.compactGroups, needsRetry: discovery.needsRetry)
            case .failure(let error):
                items = DouyinMenuItem.functions + [.retryPlayerOptions]
                self.uiState.douyinMenuError = error.localizedDescription
            }
            self.douyinRootItems = items
            self.setDouyinItems(items)
            self.sync(animated: false)
            self.log("DOUYIN_MENU_DISCOVERED generation=\(generation) elapsed_ms=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) items=\(items.count)")
            self.douyinReadTask = nil
        }
    }

    private func openDouyinOptions(_ group: DouyinLiveOptions.Group, applying option: DouyinLiveOptions.Option? = nil) {
        guard active == .douyinLive, !readingDouyinOptions else { return }
        invalidateDouyinRead()
        uiState.douyinMenuError = nil
        readingDouyinOptions = true
        douyinPendingGroup = group
        let generation = douyinMenuGeneration
        panel?.orderOut(nil)
        douyinReadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.douyinMenuGeneration == generation {
                    self.readingDouyinOptions = false
                    self.douyinPendingGroup = nil
                    self.douyinReadTask = nil
                }
            }
            // Let AppKit flush the hidden panel before sending hover events to the client beneath.
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, self.active == .douyinLive, self.douyinMenuGeneration == generation else { return }
            self.douyinNativeReadDepth += 1
            defer { self.douyinNativeReadDepth -= 1 }
            let previousCancellation = DouyinLiveOptions.shouldCancelOperation
            DouyinLiveOptions.shouldCancelOperation = { [weak self] in
                guard let self else { return true }
                return self.active != .douyinLive || self.douyinMenuGeneration != generation
            }
            defer { DouyinLiveOptions.shouldCancelOperation = previousCancellation }
            if group.id == "native" {
                self.readDouyinNativeGroups(group, generation: generation)
            } else {
                self.readDouyinOptions(group, applying: option, generation: generation)
            }
        }
    }

    private func readDouyinOptions(_ group: DouyinLiveOptions.Group, applying option: DouyinLiveOptions.Option?, generation: UInt64) {
        if let option, let error = DouyinLiveOptions.execute(option, in: group) {
            guard active == .douyinLive, douyinMenuGeneration == generation else { return }
            uiState.douyinMenuError = error
            showPanel()
            restartOverlayIdleTimer()
            return
        }
        guard active == .douyinLive, douyinMenuGeneration == generation else { return }
        if option?.id == "reset", group.id.hasPrefix("danmaku.") {
            // Reset changes sibling values too; leave no old value on those
            // cards until its own native submenu confirms the new selection.
            douyinRootItems = douyinRootItems.map { item in
                if case .playerGroup(let current) = item, current.id.hasPrefix("danmaku.") {
                    return .playerGroup(DouyinLiveOptions.refreshedGroup(current, options: []))
                }
                return item
            }
        }
        let result = DouyinLiveOptions.options(in: group)
        guard active == .douyinLive, douyinMenuGeneration == generation else { return }
        var displayedGroup = group
        if case .success(let options) = result {
            displayedGroup = DouyinLiveOptions.refreshedGroup(group, options: options)
            func refreshedItem(_ item: DouyinMenuItem) -> DouyinMenuItem {
                if case .playerGroup(let current) = item, current.id == group.id {
                    return .playerGroup(displayedGroup)
                }
                return item
            }
            douyinRootItems = douyinRootItems.map(refreshedItem)
            alternateDouyinItems = alternateDouyinItems?.map(refreshedItem)
        }
        switch result {
        case .success(let options) where options.count == 1 && options[0].id == "perform":
            performAfterDismissingDouyinMenu { DouyinLiveOptions.execute(options[0], in: group) }
            return
        case .success(let options) where !options.isEmpty:
            uiState.douyinItems = options.map { .playerOption(displayedGroup, $0) }
            menuIndex = options.firstIndex(where: { $0.isSelected }) ?? 0
        case .success:
            uiState.douyinMenuError = "当前直播间没有可用的" + group.title + "选项"
        case .failure(let error):
            uiState.douyinMenuError = error.localizedDescription
        }
        showPanel()
        restartOverlayIdleTimer()
    }

    private func readDouyinNativeGroups(_ group: DouyinLiveOptions.Group, generation: UInt64) {
        let result = DouyinLiveOptions.nativeGroups(in: group)
        guard active == .douyinLive, douyinMenuGeneration == generation else { return }
        switch result {
        case .success(let groups):
            let compact = showsMoreDouyinSettings ? (alternateDouyinItems ?? []) : douyinRootItems
            guard let toggle = compact.firstIndex(where: {
                if case .playerGroup(let item) = $0 { return item.id == group.id }
                return false
            }) else { return }
            let prefix = compact.prefix(toggle)
            let basicIDs = Set(prefix.compactMap { item -> String? in
                if case .playerGroup(let basic) = item { return basic.id }
                return nil
            })
            alternateDouyinItems = compact
            douyinRootItems = douyinRootMenu(groups: groups.filter { !basicIDs.contains($0.id) },
                                            needsRetry: DouyinLiveOptions.needsRetry,
                                            startingWith: Array(prefix) + [.collapseMore])
            uiState.douyinItems = douyinRootItems
            menuIndex = toggle
        case .failure(let error):
            uiState.douyinMenuError = error.localizedDescription
        }
        showPanel()
        restartOverlayIdleTimer()
    }

    private func toggleDouyinMenuSize() {
        guard active == .douyinLive, let alternate = alternateDouyinItems else { return }
        invalidateDouyinRead()
        alternateDouyinItems = douyinRootItems
        douyinRootItems = alternate
        uiState.douyinMenuError = nil
        setDouyinItems(alternate, focusing: "native")
        if panel?.isVisible == true { sync(animated: false) }
        else { showPanel() }
        restartOverlayIdleTimer()
    }

    private func backFromDouyinMenu() {
        var group = douyinPendingGroup
        if group == nil, case .playerOption(let current, _) = uiState.douyinItems.first { group = current }
        if active == .douyinLive, let group {
            invalidateDouyinRead()
            setDouyinItems(douyinRootItems, focusing: group.id)
            uiState.douyinMenuError = nil
            showPanel()
            restartOverlayIdleTimer()
        } else if showsMoreDouyinSettings {
            toggleDouyinMenuSize()
        } else {
            close()
        }
    }

    private func reloadDouyinMenu(focusing groupID: String? = nil) {
        loadDouyinLiveMenu(focusing: groupID)
        restartOverlayIdleTimer()
    }

    private func performDouyinAction(_ item: DouyinMenuItem) {
        guard active?.isDouyinMenu == true, uiState.douyinItems.contains(item) else { return }
        switch item {
        case .playerGroup(let group):
            if group.id == "native", alternateDouyinItems != nil { toggleDouyinMenuSize() }
            else { openDouyinOptions(group) }
        case .playerOption(let group, let option):
            if group.id == "volume" || group.id.hasPrefix("danmaku.") || group.id.hasPrefix("gift.") {
                openDouyinOptions(group, applying: option)
            } else {
                performAfterDismissingDouyinMenu { DouyinLiveOptions.execute(option, in: group) }
            }
        case .collapseMore:
            toggleDouyinMenuSize()
        case .retryPlayerOptions:
            if showsMoreDouyinSettings, let compact = alternateDouyinItems,
               let group = compact.compactMap({ item -> DouyinLiveOptions.Group? in
                   if case .playerGroup(let group) = item, group.id == "native" { return group }
                   return nil
               }).first { openDouyinOptions(group) }
            else {
                alternateDouyinItems = nil
                reloadDouyinMenu()
            }
        case .returnToLargeWindow:
            performAfterDismissingDouyinMenu(DouyinLiveOptions.returnToLargeWindow)
        case .playback:
            performAfterDismissingDouyinMenu(DouyinControls.togglePlayback)
        case .enableSound:
            performAfterDismissingDouyinMenu(DouyinControls.enableSound)
        case .fullscreen:
            performAfterDismissingDouyinMenu(DouyinControls.enterFullscreen)
        case .category(let name):
            performAfterDismissingDouyinMenu { await DouyinFeedNavigation.openCategory(named: name) }
        case .room(let name):
            performAfterDismissingDouyinMenu { DouyinControls.enterLiveRoom(named: name) }
        case .clearClutter:
            performAfterDismissingDouyinMenu(DouyinLiveClutter.clear)
        case .chooseRoom:
            open(Kind.douyinRooms.rawValue)
        }
    }

    private func performAfterDismissingDouyinMenu(_ action: @escaping @MainActor () async -> String?) {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        dismissDouyinMenu()
        // Release the menu and its fading hint panel before querying the player's controls.
        hintPanel?.orderOut(nil)
        let generation = douyinMenuGeneration
        Task { @MainActor [weak self] in
            // Finishing a click in an AppKit overlay can deliver one final mouse-exit to Chromium.
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, self.active == nil, self.douyinMenuGeneration == generation,
                  let pid, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            self.reportDouyinError(await action())
        }
    }

    func reportDouyinError(_ message: String?) {
        guard let message else { return }
        log(message)
        CodexNavigation.showNotice(message)
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
        menuIndex = SystemMenuCatalog.move(menuIndex, key: key,
            rows: SystemMenuCatalog.rowWidths(favoriteCount: menuApps.count))
        sync()
    }

    private func selectMenuEntry(_ index: Int) {
        guard active == .systemMenu, (0..<(menuApps.count + SystemMenuCatalog.items.count)).contains(index) else { return }
        cancelConfirm(refresh: false)
        menuIndex = index
        sync()
    }

    private func activateMenuEntry(_ index: Int, confirmed: Bool = false) {
        guard active == .systemMenu else { return }
        if menuApps.indices.contains(index) {
            let app = menuApps[index]
            close()
            DockApplications.launch(app)
        } else if let systemIndex = SystemMenuCatalog.systemIndex(index, favoriteCount: menuApps.count) {
            let item = SystemMenuCatalog.items[systemIndex]
            if item.dangerous && !confirmed {
                beginConfirm(item: item)
            } else {
                close()
                runner.run(item.action)
            }
        }
    }

    private func handleMenuKey(_ key: RemoteKey) {
        switch key {
        case .up, .down, .left, .right:
            cancelConfirm(refresh: false)
            menuStep(key)
            startRepeat(key) { [weak self] in self?.menuStep(key) }
        case .ok:
            activateMenuEntry(menuIndex)
        case .back, .menu, .home:
            close()
        default:
            break
        }
    }

    // MARK: 危险动作 hold-to-confirm（OK 按住 0.6s 填充环，中途松开取消）

    private func beginConfirm(item: SystemMenuItem) {
        guard confirmingIndex == nil else { return }
        guard let systemIndex = SystemMenuCatalog.systemIndex(menuIndex, favoriteCount: menuApps.count) else { return }
        confirmingIndex = menuIndex
        let index = menuIndex
        sync()
        let t = Timer(timeInterval: SystemMenuCatalog.confirmHoldSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.confirmingIndex == index else { return }
                self.confirmingIndex = nil
                self.close()
                self.runner.run(SystemMenuCatalog.items[systemIndex].action)
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
        overlayIdleGeneration &+= 1
        guard active != nil else { return }
        // 系统可能正在等待 Automation 授权或保存文件，结果到达前保留反馈位置。
        if active == .computerPower, powerMenu.isExecuting { return }
        // 会话列表需要阅读标题；给它比图标菜单更长的空闲时间。
        var idleSeconds: TimeInterval = active == .televisionPower ? 30
            : active == .codexSessions ? 60 : (active == .computerPower || active == .douyinLive) ? 30 : Self.overlayIdleSeconds
        if let televisionDeadline, active == .televisionPower {
            let remaining = ContinuousClock().now.duration(to: televisionDeadline).components
            idleSeconds = min(idleSeconds, max(0.05, Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18))
        }
        let token = overlayIdleGeneration
        let timer = Timer(timeInterval: idleSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.overlayIdleGeneration == token else { return }
                self.close(dismissTelevisionMenu: self.active != .televisionPower)
            }
        }
        overlayIdleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func reloadPickerEntries() {
        pickerEntries = WindowSwitcher.pickerEntries(currentAppOnly: pickerCurrentAppOnly,
                                                     frontPid: frontApp?.processIdentifier)
        pickerIndex = 0
    }

    // MARK: 电脑电源列表

    private func handlePowerKey(_ key: RemoteKey) {
        if key == .menu, powerMenu.appOption == nil, case .launchApp(let id) = powerMenu.selection.command {
            cancelPowerConfirmation(refresh: false)
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .contains { !$0.isTerminated && $0.activationPolicy == .regular }
            powerMenu.showAppOptions(running: running)
            sync(animated: false)
            return
        }
        if key == .ok {
            guard !powerOKHeld else { return }
            powerOKHeld = true
            if powerMenu.selectedCommand?.requiresHoldConfirmation == true {
                beginPowerConfirmation()
                return
            }
        } else { cancelPowerConfirmation(refresh: false) }
        handlePowerEffect(powerMenu.handle(key))
    }

    private func selectPowerChoice(_ choice: PowerMenuState.Choice) {
        guard active == .computerPower else { return }
        cancelPowerConfirmation(refresh: false)
        if choice.command?.requiresHoldConfirmation == true {
            powerMenu.focus(choice)
            sync()
            return
        }
        handlePowerEffect(powerMenu.select(choice))
    }

    private func focusPowerChoice(_ choice: PowerMenuState.Choice) {
        guard active == .computerPower else { return }
        cancelPowerConfirmation(refresh: false)
        powerMenu.focus(choice)
        sync()
    }

    private func confirmPowerChoice(_ choice: PowerMenuState.Choice, generation: UInt64, inputGeneration: UInt64) {
        guard active == .computerPower, powerGeneration == generation,
              (engine?.inputGeneration ?? 0) == inputGeneration,
              powerMenu.selection.id == choice.id else { return }
        cancelPowerConfirmation(refresh: false)
        handlePowerEffect(powerMenu.select(choice))
    }

    private func beginPowerConfirmation() {
        guard powerConfirmingID == nil, !powerMenu.isExecuting else { return }
        let choice = powerMenu.selection
        let command = powerMenu.selectedCommand
        let token = powerGeneration
        let inputToken = engine?.inputGeneration ?? 0
        powerConfirmingID = choice.id
        sync(animated: false)
        let timer = Timer(timeInterval: SystemMenuCatalog.confirmHoldSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.powerOKHeld, self.powerConfirmingID == choice.id else { return }
                guard self.active == .computerPower, self.powerGeneration == token,
                      self.engine?.inputGeneration == inputToken, self.powerMenu.selection.id == choice.id,
                      self.powerMenu.selectedCommand == command else { return }
                self.handlePowerEffect(self.powerMenu.handle(.ok))
            }
        }
        powerConfirmTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelPowerConfirmation(refresh: Bool) {
        powerConfirmTimer?.invalidate()
        powerConfirmTimer = nil
        let changed = powerConfirmingID != nil
        powerConfirmingID = nil
        if refresh, changed { sync(animated: false) }
    }

    /// Input loss must abort holds even if the physical keyUp never arrives.
    func invalidateInputConfirmation() {
        let wasConfirming = powerConfirmingID != nil || confirmingIndex != nil || powerOKHeld
        powerOKHeld = false
        cancelPowerConfirmation(refresh: false)
        cancelConfirm(refresh: false)
        stopRepeat()
        if wasConfirming, active == .computerPower, !powerMenu.isExecuting { powerMenu.focus(.cancel) }
        sync(animated: false)
    }

    private func reloadControlApplications() {
        let ownID = Bundle.main.bundleIdentifier
        let running = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.activationPolicy == .regular
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                && $0.bundleIdentifier?.caseInsensitiveCompare(ownID ?? "") != .orderedSame
                && $0.bundleIdentifier != nil && $0.bundleURL != nil
        }
        let recent = services?.keyMapper?.mruExternalApplications ?? []
        let orderedRunning = recent + running.sorted {
            ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending
        }
        let allowedPIDs = Set(running.map(\.processIdentifier))
        var entries: [String: DockApplications.Entry] = [:]
        var runningIDs: [String] = []
        for app in orderedRunning where allowedPIDs.contains(app.processIdentifier) {
            guard let id = app.bundleIdentifier, let url = app.bundleURL, entries[id.lowercased()] == nil else { continue }
            runningIDs.append(id)
            entries[id.lowercased()] = DockApplications.Entry(id: id,
                name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                url: url, icon: NSWorkspace.shared.icon(forFile: url.path))
        }
        let availableFavorites: [DockApplications.Entry]
        if let ids = model?.config.menuFavoriteApps { availableFavorites = ids.compactMap { DockApplications.resolve($0) } }
        else { availableFavorites = Array(DockApplications.pinned().prefix(6)) }
        let favorites = availableFavorites.filter { $0.id.caseInsensitiveCompare(ownID ?? "") != .orderedSame }
        for entry in favorites where entries[entry.id.lowercased()] == nil { entries[entry.id.lowercased()] = entry }
        menuApps = PowerMenuCatalog.orderedAppIDs(running: runningIDs, favorites: favorites.map(\.id))
            .compactMap { entries[$0.lowercased()] }
        runningControlAppIDs = Set(runningIDs.map { $0.lowercased() })
    }

    private func controlPowerChoices() -> [PowerMenuState.Choice] {
        let douyinRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.bytedance.douyin.desktop")
            .contains { !$0.isTerminated && $0.activationPolicy == .regular }
        return PowerMenuCatalog.choices(televisionConfigured: XiaomiTVController.shared.isConfigured,
            currentAppName: powerApplication?.localizedName, douyinRunning: douyinRunning,
            apps: menuApps.map { (id: $0.id, title: $0.name) })
    }

    private func refreshControlApplications() {
        guard active == .computerPower, !powerMenu.isExecuting else { return }
        if powerApplication?.isTerminated == true { powerApplication = nil }
        reloadControlApplications()
        powerMenu.refreshChoices(controlPowerChoices())
        if powerMenu.appOption != nil, case .launchApp(let id) = powerMenu.selection.command {
            let running = runningControlAppIDs.contains(id.lowercased())
            if powerMenu.canQuitSelectedApp != running { powerMenu.showAppOptions(running: running) }
        }
    }

    /// terminate() 只确认请求已发送；实际退出后再更新绿点和退出可用性。
    /// 只在当前面板订阅，旧面板排队中的通知不能修改后来打开的面板。
    private func observeControlApplications() {
        let generation = powerGeneration
        let center = NSWorkspace.shared.notificationCenter
        controlApplicationObservers = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.powerGeneration == generation else { return }
                    self.refreshControlApplications()
                    self.sync(animated: false)
                }
            }
        }
    }

    private func handleTelevisionPowerKey(_ key: RemoteKey) {
        guard active == .televisionPower else { return }
        if let televisionDeadline, ContinuousClock().now >= televisionDeadline {
            close(dismissTelevisionMenu: false)
            return
        }
        guard XiaomiTVController.shared.matches(televisionMenuConfiguration) else {
            close(dismissTelevisionMenu: false)
            return
        }
        switch televisionMenu.handle(key) {
        case .none: sync(animated: false)
        case .cancel:
            close()
        case .send(let command):
            let token = powerGeneration
            XiaomiTVController.shared.perform(command, matching: televisionMenuConfiguration) { [weak self] result in
                guard let self, self.active == .televisionPower, self.powerGeneration == token else { return }
                self.televisionMenu.received(result, key: key)
                if TelevisionPowerMenuState.endsSession(result) {
                    self.close(dismissTelevisionMenu: false)
                }
            }
        }
    }

    /// Losing the display/remote context ends local routing without sending a
    /// late Back to a TV that may already have shut down or booted again.
    func invalidateTelevisionControlContext(reason: String) {
        televisionContextGeneration &+= 1
        guard active == .televisionPower else { return }
        log("结束电视控制：\(reason)")
        close(dismissTelevisionMenu: false)
    }

    private func startTelevisionMonitor() {
        televisionMonitor?.invalidate()
        let token = powerGeneration
        let configuration = televisionMenuConfiguration
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.active == .televisionPower, self.powerGeneration == token else { return }
                let client = XiaomiTVController.shared
                guard client.matches(configuration) else {
                    self.close(dismissTelevisionMenu: false)
                    return
                }
                guard !self.televisionCheckInFlight, client.isIdle else { return }
                self.televisionCheckInFlight = true
                client.checkConnection { [weak self] result in
                    guard let self, self.active == .televisionPower, self.powerGeneration == token else { return }
                    self.televisionCheckInFlight = false
                    if TelevisionPowerMenuState.endsSession(result) {
                        self.close(dismissTelevisionMenu: false)
                    }
                }
            }
        }
        televisionMonitor = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func handlePowerEffect(_ effect: PowerMenuState.Effect) {
        switch effect {
        case .none:
            sync(animated: false)
        case .dismiss:
            close()
        case .execute(let command):
            stopRepeat()
            cancelPowerConfirmation(refresh: false)
            switch command {
            case .tvOff:
                guard XiaomiTVController.shared.isIdle else {
                    _ = powerMenu.complete(.failure(.message("电视控制繁忙，请稍后再打开关机菜单。")))
                    sync(animated: false)
                    return
                }
                open("television_power")
                return
            case .launchApp, .systemAction, .focusInput, .openSettings:
                if command.keepsMenuOpen { break }
                close()
                PowerMenuActions.perform(command, currentApplication: nil) { _ in }
                return
            default: break
            }
            restartOverlayIdleTimer()
            sync(animated: false)
            let token = powerGeneration
            PowerMenuActions.perform(command, currentApplication: powerApplication) { [weak self] result in
                guard let self, self.active == .computerPower,
                      self.powerGeneration == token else { return }
                if self.powerMenu.complete(result) == .dismiss {
                    self.close()
                } else {
                    self.refreshControlApplications()
                    self.restartOverlayIdleTimer()
                    self.sync(animated: false)
                }
            }
        }
    }

    // MARK: Codex 项目会话列表

    private func codexStep(_ key: RemoteKey) {
        guard codexLaunchTask == nil else { return }
        browsedSessions = true
        codexSelection = codexList.moved(codexSelection, key: key)
        restartOverlayIdleTimer()
        sync()
    }

    private func selectCodexTab(_ index: Int) {
        guard active == .codexSessions, codexLaunchTask == nil, codexList.tabs.indices.contains(index), index != codexSelection.tab else { return }
        browsedSessions = true
        codexSelection = codexList.initialSelection(tab: index)
        restartOverlayIdleTimer()
        sync()
    }

    private func createCodexChat(tabID: String) {
        guard active == .codexSessions, codexLaunchTask == nil,
              codexList.tabs.indices.contains(codexSelection.tab) else { return }
        let tab = codexList.tabs[codexSelection.tab]
        guard !tab.isTools, tab.id == tabID else { return }
        launchCodexChat(selection: .init(tab: codexSelection.tab)) {
            let opened = await CodexSessions.openNew(in: tab.project)
            return opened ? nil : CodexSessions.newSessionFailure ?? "无法打开新会话，请重试。"
        }
    }

    private func openCodexDot() {
        guard active == .codexSessions, codexList.tabs[codexSelection.tab].isRecent else { return }
        launchCodexChat(selection: .dot) {
            await CodexDot.open() ? nil : "无法打开「你的 Dot」，请确认 Codex 侧栏中有此入口。"
        }
    }

    private func launchCodexChat(selection: CodexSessionList.Selection,
                                 action: @escaping @MainActor () async -> String?) {
        guard codexLaunchTask == nil else { return }
        browsedSessions = true
        codexSelection = selection
        restartOverlayIdleTimer()
        codexLaunchTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            let failure = await action()
            guard !Task.isCancelled, let self, self.active == .codexSessions else { return }
            self.codexLaunchTask = nil
            if let failure {
                self.codexSnapshot.error = failure
                self.sync(animated: false)
            } else {
                self.close()
            }
        }
        sync(animated: false)
    }

    private func runCodexTool(_ tool: CodexSessionList.Tool) {
        guard active == .codexSessions, codexList.tabs[codexSelection.tab].isTools else { return }
        if tool == .sessionSettings {
            open("codex_settings")
            return
        }
        close()
        Task { @MainActor in
            switch tool {
            case .sessionSettings: break
            case .updateCodex:
                if let message = await CodexAppUpdate.run() { CodexNavigation.showNotice(message) }
            }
        }
    }

    private func reloadCodexSettings() {
        guard !uiState.codexSettings.busy else { return }
        uiState.codexSettings.collapse()
        performCodexSettingsOperation {
            let snapshot = try await CodexSessionSettings.capture()
            try Task.checkCancellation()
            self.uiState.codexSettings.snapshot = snapshot
        }
    }

    private func performCodexSettingsOperation(_ operation: @escaping @MainActor () async throws -> Void) {
        guard active == .codexSettings, codexSettingsTask == nil else { return }
        codexSettingsEpoch &+= 1
        let epoch = codexSettingsEpoch
        uiState.codexSettings.busy = true
        uiState.codexSettings.error = nil
        panel?.orderOut(nil)
        codexSettingsTask = Task { @MainActor [weak self] in
            do { try await operation() }
            catch {
                guard let self, self.codexSettingsEpoch == epoch else { return }
                self.uiState.codexSettings.error = error.localizedDescription
            }
            guard let self, self.active == .codexSettings,
                  self.codexSettingsEpoch == epoch, !Task.isCancelled else { return }
            self.codexSettingsTask = nil
            self.uiState.codexSettings.busy = false
            self.panel?.orderFrontRegardless()
            self.restartOverlayIdleTimer()
        }
    }

    private func selectCodexSetting(_ field: CodexSessionSettings.Field) {
        guard active == .codexSettings, !uiState.codexSettings.busy,
              let context = uiState.codexSettings.snapshot?.context else { return }
        uiState.codexSettings.selected = field == .model ? 0 : field == .effort ? 1 : 2
        if uiState.codexSettings.expanded == field {
            uiState.codexSettings.collapse()
            return
        }
        performCodexSettingsOperation {
            let options = try await CodexSessionSettings.options(field, context: context)
            try Task.checkCancellation()
            self.uiState.codexSettings.expanded = field
            self.uiState.codexSettings.options = options
            self.uiState.codexSettings.optionIndex = options.firstIndex(where: \.isSelected) ?? 0
        }
    }

    private func openCodexPlugins() {
        selectCodexSetting(.plugins)
    }

    private func applyCodexSetting(_ option: CodexSessionSettings.Option) {
        guard active == .codexSettings, !uiState.codexSettings.busy, option.isEnabled,
              let field = uiState.codexSettings.expanded,
              let context = uiState.codexSettings.snapshot?.context else { return }
        performCodexSettingsOperation {
            do {
                let current = try await CodexSessionSettings.apply(field, option: option, context: context)
                try Task.checkCancellation()
                self.uiState.codexSettings.snapshot = current
                self.uiState.codexSettings.collapse()
            } catch {
                if field == .effort, !Task.isCancelled {
                    self.uiState.codexSettings.snapshot = try? CodexSessionSettings.snapshot(context)
                    self.uiState.codexSettings.collapse()
                }
                throw error
            }
        }
    }

    private func backFromCodexSettings() {
        guard active == .codexSettings else { return }
        if uiState.codexSettings.expanded != nil, !uiState.codexSettings.busy {
            uiState.codexSettings.collapse()
        } else {
            open("codex_sessions")
            codexSelection = codexList.initialSelection(tab: 0)
            browsedSessions = true
            sync(animated: false)
        }
    }

    private func handleCodexSettingsKey(_ key: RemoteKey) {
        switch key {
        case .back: backFromCodexSettings()
        case .home, .tv, .menu: close()
        case .up, .down, .left, .right:
            guard !uiState.codexSettings.busy else { return }
            let step = { [weak self] in
                guard let self, self.active == .codexSettings, !self.uiState.codexSettings.busy else { return }
                self.uiState.codexSettings.move(key)
            }
            step()
            startRepeat(key, step: step)
        case .ok:
            guard !uiState.codexSettings.busy else { return }
            if uiState.codexSettings.snapshot == nil { reloadCodexSettings(); return }
            if uiState.codexSettings.expanded != nil {
                let state = uiState.codexSettings
                if state.options.indices.contains(state.optionIndex) { applyCodexSetting(state.options[state.optionIndex]) }
            } else if uiState.codexSettings.selected == 2 {
                openCodexPlugins()
            } else {
                selectCodexSetting(uiState.codexSettings.selected == 0 ? .model : .effort)
            }
        default: break
        }
    }

    private func handleCodexKey(_ key: RemoteKey) {
        switch key {
        case .up, .down, .left, .right:
            codexStep(key)
            startRepeat(key) { [weak self] in self?.codexStep(key) }
        case .ok:
            if codexList.tabs[codexSelection.tab].isTools {
                if let row = codexSelection.row, CodexSessionList.Tool.allCases.indices.contains(row) {
                    runCodexTool(CodexSessionList.Tool.allCases[row])
                }
                return
            }
            if codexSelection.item == .dot { openCodexDot(); return }
            if codexSelection.row == nil {
                createCodexChat(tabID: codexList.tabs[codexSelection.tab].id)
                return
            }
            guard codexLaunchTask == nil, let target = codexList.entry(at: codexSelection) else { return }
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
            uiState.kind = active == .televisionPower ? nil : active
            uiState.pickerEntries = pickerEntries
            uiState.pickerIndex = pickerIndex
            uiState.pickerCurrentAppOnly = pickerCurrentAppOnly
            uiState.frontAppName = frontApp?.localizedName
            uiState.menuIndex = menuIndex
            uiState.menuConfirming = confirmingIndex != nil
            uiState.menuApps = menuApps
            uiState.runningControlAppIDs = runningControlAppIDs
            uiState.wheelEntries = wheelApps.map {
                AppWheelView.Entry(name: $0.localizedName ?? $0.bundleIdentifier ?? "App",
                                   bundleID: $0.bundleIdentifier)
            }
            uiState.wheelIndex = wheelIndex
            uiState.codexSnapshot = codexSnapshot
            uiState.codexList = codexList
            uiState.codexSelection = codexSelection
            uiState.isLaunchingCodexChat = codexLaunchTask != nil
            uiState.powerMenu = powerMenu
            uiState.televisionPowerStatus = televisionPowerStatus
            uiState.powerConfirmingID = powerConfirmingID
            uiState.powerGeneration = powerGeneration
            uiState.confirmationInputGeneration = engine?.inputGeneration ?? 0
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
            onDismiss: { [weak self] in self?.close() },
            onDouyinBack: { [weak self] in self?.backFromDouyinMenu() },
            onDouyinAction: { [weak self] in self?.performDouyinAction($0) },
            onCodexSettingsField: { [weak self] in self?.selectCodexSetting($0) },
            onCodexSettingsOption: { [weak self] in self?.applyCodexSetting($0) },
            onCodexPlugins: { [weak self] in self?.openCodexPlugins() },
            onCodexSettingsRetry: { [weak self] in self?.reloadCodexSettings() },
            onCodexSettingsBack: { [weak self] in self?.backFromCodexSettings() },
            onCodexTool: { [weak self] in self?.runCodexTool($0) },
            onCodexDot: { [weak self] in self?.openCodexDot() },
            onCodexNewChat: { [weak self] in self?.createCodexChat(tabID: $0) },
            onCodexTabSelected: { [weak self] in self?.selectCodexTab($0) },
            onMenuSelect: { [weak self] in self?.selectMenuEntry($0) },
            onMenuActivate: { [weak self] in self?.activateMenuEntry($0, confirmed: true) },
            onPowerSelect: { [weak self] in self?.selectPowerChoice($0) },
            onPowerFocus: { [weak self] in self?.focusPowerChoice($0) },
            onPowerConfirmed: { [weak self] in self?.confirmPowerChoice($0, generation: $1, inputGeneration: $2) }))
        panel = p
        return p
    }

    /// 全屏透明面板承载居中内容：不抢焦点；点空白（内容之外任意处）关闭。
    private func showPanel() {
        guard active != .televisionPower else { return }
        let p = ensurePanel()
        if let screen = NSScreen.main { p.setFrame(screen.frame, display: true) }
        let alreadyShowing = p.isVisible && uiState.kind == active
        sync(animated: false)
        p.orderFrontRegardless()
        if !alreadyShowing {
            uiState.kind = nil
            withAnimation(Motion.overlay) { uiState.kind = active }
        }
    }

    // MARK: per-app profile 切换提示（gamepad-ux ⑦：换布局要让用户知道）

    /// 提示条自动收起时长；令牌防止快速连切 App 时旧定时器收掉新提示。
    private static let profileHintMs = 2500

    /// 前台 App 切换：该 App 若显式改写了基础态键义（如飞书 OK=⌘Enter 发送），
    /// 闪一条提示条。基础态平时不常驻提示条，故到点自动收起。
    /// 浮层打开或已在功能层时不打扰——那两种状态的提示条另有主人。
    func noteProfileSwitch(_ bundleID: String?) {
        if bundleID != "com.bytedance.douyin.desktop" { invalidateDouyinHome() }
        if active?.isDouyinMenu == true, bundleID != "com.bytedance.douyin.desktop" { close() }
        guard active == nil, !dockNavigationActive, applicationNavigationMode == nil,
              mouseStatusText == nil, model?.activeLayer == 0 else { return }
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
        if dockNavigationActive {
            showHintBar([
                .init(keys: [.up, .down, .left, .right], text: "选择 Dock 应用"),
                .init(keys: [.ok], text: "打开"),
                .init(keys: [.back], text: "取消")])
        } else if let mode = applicationNavigationMode {
            let direction = applicationNavigationEditing ? "移动光标"
                : mode == .regions ? "左右切区 · 上下导航" : "选择按钮"
            showHintBar([
                .init(keys: [.up, .down, .left, .right], text: direction),
                .init(keys: [.ok], text: applicationNavigationEditing ? "回车" : "点击选中控件"),
                .init(keys: [.back], text: applicationNavigationEditing ? "退出输入" : "返回"),
                .init(keys: [.menu], text: "双击系统菜单 · 长按 Dock")])
        } else if let mouseStatusText {
            showHintBar(HintBarCatalog.hintsForMouse(status: mouseStatusText))
        } else if let model, model.activeLayer != 0 {
            showHintBar(HintBarCatalog.hints(forLayer: model.activeLayer, config: model.config,
                                             profile: frontApp?.bundleIdentifier ?? "global"))
        } else {
            hideHintBar()
        }
    }

    func noteDockNavigation(_ active: Bool) {
        dockNavigationActive = active
        profileHintToken &+= 1
        if self.active == nil { restoreContextHints() }
    }

    func noteApplicationNavigation(mode: AppNavigationMode?, editing: Bool) {
        guard applicationNavigationMode != mode || applicationNavigationEditing != editing else { return }
        applicationNavigationMode = mode
        applicationNavigationEditing = editing
        profileHintToken &+= 1
        if active == nil { restoreContextHints() }
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
            let dockAtBottom = (UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom") == "bottom"
            let y = dockNavigationActive && dockAtBottom ? f.maxY - size.height - 20 : f.minY + 16
            hintPanel.setFrame(NSRect(x: f.midX - size.width / 2, y: y,
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
        case .douyinLive, .douyinCategories, .douyinRooms:
            return [Hint(keys: [.up, .down], text: "选择"), Hint(keys: [.ok], text: "执行"),
                    Hint(keys: [.back], text: "关闭")]
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
        case .codexSettings:
            return []
        case .codexSessions:
            return [Hint(keys: [.up, .down], text: "选会话（按住加速）"),
                    Hint(keys: [.left, .right], text: "切换标签"),
                    Hint(keys: [.ok], text: "打开"),
                    Hint(keys: [.back, .home, .tv], text: "取消")]
        case .computerPower:
            return [Hint(keys: [.up, .down], text: "切分类"),
                    Hint(keys: [.left, .right], text: "选按钮"),
                    Hint(keys: [.ok], text: "确认"),
                    Hint(keys: [.back, .power], text: "取消")]
        case .televisionPower:
            return [Hint(keys: [.up, .down, .left, .right], text: "选择电视关机项"),
                    Hint(keys: [.ok], text: "电视确认"), Hint(keys: [.back], text: "取消电视菜单")]
        }
    }

    static func hintsForGlobal() -> [Hint] {
        [Hint(keys: [.left, .right], text: "长按 ⌃← / ⌃→"),
         Hint(keys: [.home], text: "双击显示桌面"),
         Hint(keys: [.menu], text: "双击系统面板 · 长按 Dock"),
         Hint(keys: [.tv], text: "单击 Codex · 双击上个 App"),
         Hint(keys: [.power], text: "电脑电源"),
         Hint(keys: [.back], text: "长按 1.2 秒退出当前应用")]
    }

    static func hintsForCodex() -> [Hint] {
        [Hint(keys: [.up, .down], text: "滚动对话 · 问题框内选答案"),
         Hint(keys: [.left, .right], text: "切换题目"),
         Hint(keys: [.menu], text: "会话列表"),
         Hint(keys: [.voice], text: "短按切输入位置 · 按住说话"),
         Hint(keys: [.ok], text: "单击选择 · 长按发送")]
    }

    static func hintsForMouse(status: String = "鼠标模式") -> [Hint] {
        [Hint(keys: [], text: status),
         Hint(keys: [.up, .down, .left, .right], text: "移动 · 左右双击 ⌃← / ⌃→"),
         Hint(keys: [.ok], text: "左键"),
         Hint(keys: [.menu], text: "单击右键 · 长按 Dock"),
         Hint(keys: [.back], text: "单击退出鼠标 · 长按退出应用")]
    }

    /// 基础态的 per-app 覆盖提示：切到该 App 时闪一下，告诉用户这颗键在这里变了。
    /// 只列 profile 显式声明且基础态确实生效的槽位；Back 必须额外 opt-in，
    /// 与 MappingEngine 的保护保持一致，避免提示条许诺引擎不认的绑定。
    static func hints(forBaseProfile bundleID: String, config: MappingConfig) -> [Hint] {
        if bundleID == "com.openai.codex", config.profiles[bundleID]?["ok"]?.hold == .system("codex_context_submit") { return hintsForCodex() }
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
    let onDouyinBack: () -> Void
    let onDouyinAction: (DouyinMenuItem) -> Void
    let onCodexSettingsField: (CodexSessionSettings.Field) -> Void
    let onCodexSettingsOption: (CodexSessionSettings.Option) -> Void
    let onCodexPlugins: () -> Void
    let onCodexSettingsRetry: () -> Void
    let onCodexSettingsBack: () -> Void
    let onCodexTool: (CodexSessionList.Tool) -> Void
    let onCodexDot: () -> Void
    let onCodexNewChat: (String) -> Void
    let onCodexTabSelected: (Int) -> Void
    let onMenuSelect: (Int) -> Void
    let onMenuActivate: (Int) -> Void
    let onPowerSelect: (PowerMenuState.Choice) -> Void
    let onPowerFocus: (PowerMenuState.Choice) -> Void
    let onPowerConfirmed: (PowerMenuState.Choice, UInt64, UInt64) -> Void

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
                case .douyinLive, .douyinCategories, .douyinRooms:
                    DouyinLiveMenu(items: state.douyinItems, selected: state.menuIndex, activate: onDouyinAction, onBack: onDouyinBack, message: state.douyinMenuError)
                case .windowPicker:
                    WindowPickerView(entries: state.pickerEntries,
                                     selected: state.pickerIndex,
                                     currentAppOnly: state.pickerCurrentAppOnly,
                                     frontAppName: state.frontAppName)
                case .systemMenu:
                    SystemMenuDashboardView(apps: state.menuApps, selected: state.menuIndex,
                        confirming: state.menuConfirming, onSelect: onMenuSelect, onActivate: onMenuActivate)
                case .appWheel:
                    AppWheelView(apps: state.wheelEntries, selected: state.wheelIndex)
                case .codexSettings:
                    CodexSessionSettingsView(state: state.codexSettings,
                        onField: onCodexSettingsField, onOption: onCodexSettingsOption,
                        onPlugins: onCodexPlugins, onBack: onCodexSettingsBack, onRetry: onCodexSettingsRetry)
                case .codexSessions:
                    CodexSessionsView(snapshot: state.codexSnapshot, list: state.codexList, tabIndex: state.codexSelection.tab,
                                      selected: state.codexSelection.row, dotSelected: state.codexSelection.item == .dot,
                                      onDot: onCodexDot, isLaunching: state.isLaunchingCodexChat, onTool: onCodexTool, onNewChat: onCodexNewChat, onTabSelected: onCodexTabSelected)
                case .computerPower:
                    let generation = state.powerGeneration
                    let inputGeneration = state.confirmationInputGeneration
                    PowerMenuView(state: state.powerMenu, onSelect: onPowerSelect,
                        televisionStatus: state.televisionPowerStatus, favoriteApps: state.menuApps,
                        runningAppIDs: state.runningControlAppIDs, onFocus: onPowerFocus,
                        onConfirmed: { choice in onPowerConfirmed(choice, generation, inputGeneration) },
                        confirmingID: state.powerConfirmingID, confirmationEpoch: inputGeneration)
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
