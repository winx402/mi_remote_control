import AppKit
import SwiftUI

/// GUI 模式的应用委托：服务生命周期 + 双形态窗口（DESIGN §6.1）+ 状态反馈三件套。
/// --ui-preview：窗口照常，引擎不启动（开发验证专用）。
@MainActor
final class GUIAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private let uiPreview: Bool
    private var services: AppServices?
    private var model: AppModel!
    private var window: NSWindow?
    private var statusController: StatusItemController?
    private var badgeController: FloatingBadgeController?
    private var overlayCenter: OverlayCenter?
    private var shutdownSignals: [DispatchSourceSignal] = []
    private var voiceProbePanel: NSPanel?
    private var voiceProbeLabel: NSTextField?
    private var voiceProbeRunning = false
    private var voiceProbeGeneration: UInt64 = 0
    private let dockNavigation = DockNavigationController()
    private let applicationNavigation = ApplicationNavigationController()
    private var dockReturnApplication: NSRunningApplication?

    init(uiPreview: Bool) {
        self.uiPreview = uiPreview
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        // 本地重建会发送 TERM；先走正常清理，避免留下设备级按键中转。
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                self?.applicationNavigation.stop()
                self?.dockNavigation.close()
                self?.services?.stop()
                NSApp.terminate(nil)
            }
            source.resume()
            shutdownSignals.append(source)
        }
        configureMainMenu()
        // Dock + 菜单栏双入口：服务运行期间始终保留 Dock 图标，
        // 关闭设置窗口也不退出；点 Dock 图标由 applicationShouldHandleReopen 重开窗口。
        NSApp.setActivationPolicy(.regular)

        var opts = AppServices.Options()
        opts.keys = true
        opts.perAppVoiceRouting = true
        let levelSink = LevelMeterSink()
        opts.levelSink = levelSink
        let services = AppServices(options: opts)
        self.services = services

        model = AppModel(services: services)

        // M5 v2 浮层体系：窗口选择器 / 系统功能菜单 / 教程浮层（捕获式）+ 控制模式 HUD。
        let center = OverlayCenter(model: model, services: services)
        overlayCenter = center
        center.onActiveChanged = { [weak self] in self?.updateNavigationSuspension() }
        center.onOpenSettings = { [weak self] in self?.showWindow() }
        dockNavigation.onActiveChanged = { [weak self, weak center] active in
            center?.noteDockNavigation(active)
            self?.model.dockNavigationStatus = active ? "正在打开 Dock…" : "已退出 Dock 选择"
            self?.updateNavigationSuspension()
        }
        dockNavigation.onSelectionChanged = { [weak self] name in
            self?.model.dockNavigationStatus = "正在选择：\(name)"
        }
        dockNavigation.onUnavailable = { [weak self] text in
            self?.model.dockNavigationStatus = text
            CodexNavigation.showNotice(text)
        }
        model.onMouseStatus = { [weak self, weak center] text in
            center?.updateMouseStatus(text: text)
            self?.updateNavigationSuspension()
        }
        CodexNavigation.onUnavailable = { [weak self, weak center] name, message in
            if name == "codex_previous_chat" || name == "codex_next_chat" {
                self?.dockNavigation.close()
                center?.ensureOpen("codex_sessions")
            } else {
                CodexNavigation.showNotice(message)
            }
        }
        ActionRunner.onOverlay = { [weak self] name in
            // ActionRunner 已切主线程投递
            MainActor.assumeIsolated { self?.openOverlay(name) }
        }

        // 服务事件 → 主线程 → AppModel
        wireCallbacks(services: services, levelSink: levelSink)

        // 状态三件套
        statusController = StatusItemController(model: model)
        statusController?.onOpenWindow = { [weak self] in self?.showWindow() }
        statusController?.onQuit = { NSApp.terminate(nil) }
        badgeController = FloatingBadgeController(model: model)

        if uiPreview {
            log("UI 预览模式：引擎不启动")
        } else {
            model.applyVoiceMode()   // 语音模式偏好落到服务开关
            services.start()
        }

        showWindow()
    }

    /// 纯代码创建 NSApplication 时系统不会自动生成主菜单；显式补齐标准快捷键，
    /// 否则菜单栏里的 App 菜单为空，⌘Q/⌘H/⌘W 都不会生效。
    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let appRoot = NSMenuItem()
        let appMenu = NSMenu(title: "MiRemote")
        let about = NSMenuItem(title: "关于 MiRemote",
                               action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                               keyEquivalent: "")
        about.target = NSApp
        appMenu.addItem(about)
        appMenu.addItem(.separator())

        let sessions = NSMenuItem(title: "Codex 会话列表",
                                  action: #selector(showCodexSessions), keyEquivalent: "")
        sessions.target = self
        appMenu.addItem(sessions)
        let systemMenu = NSMenuItem(title: "系统功能菜单…", action: #selector(showSystemMenu), keyEquivalent: "")
        systemMenu.target = self
        appMenu.addItem(systemMenu)
        let dockMenu = NSMenuItem(title: "Dock 应用选择…", action: #selector(showDockPicker), keyEquivalent: "")
        let powerMenu = NSMenuItem(title: "电源与应用…", action: #selector(showPowerMenu), keyEquivalent: "")
        powerMenu.target = self
        appMenu.addItem(powerMenu)
        dockMenu.target = self
        appMenu.addItem(dockMenu)
        let diagnostics = NSMenuItem(title: "检查抖音导航…", action: #selector(diagnoseDouyinNavigation), keyEquivalent: "")
        diagnostics.target = self
        appMenu.addItem(diagnostics)
        let probe = NSMenuItem(title: "验证遥控器连续收音…",
                               action: #selector(startVoiceProbe), keyEquivalent: "")
        probe.target = self
        appMenu.addItem(probe)
        appMenu.addItem(.separator())

        let hide = NSMenuItem(title: "隐藏 MiRemote",
                              action: #selector(NSApplication.hide(_:)),
                              keyEquivalent: "h")
        hide.target = NSApp
        appMenu.addItem(hide)
        appMenu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 MiRemote",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(quit)
        appRoot.submenu = appMenu
        mainMenu.addItem(appRoot)

        let windowRoot = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        let close = NSMenuItem(title: "关闭窗口",
                               action: #selector(NSWindow.performClose(_:)),
                               keyEquivalent: "w")
        windowMenu.addItem(close)
        let minimize = NSMenuItem(title: "最小化",
                                  action: #selector(NSWindow.performMiniaturize(_:)),
                                  keyEquivalent: "m")
        windowMenu.addItem(minimize)
        windowRoot.submenu = windowMenu
        mainMenu.addItem(windowRoot)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        applicationNavigation.stop()
        dockNavigation.close()
        services?.bridge.cancelVoiceContinuityProbe()
        // 退出前清理：恢复 hidutil 中转、断开语音链路（AppServices.stop 幂等）。
        services?.stop()
    }

    @objc private func showCodexSessions() {
        openOverlay("codex_sessions")
    }

    @objc private func showSystemMenu() { openOverlay("system_menu") }
    @objc private func showPowerMenu() { openOverlay("computer_power") }
    @objc private func showDockPicker() { openOverlay("dock_picker") }

    @objc private func diagnoseDouyinNavigation() {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.bytedance.douyin.desktop")
            .first(where: { !$0.isTerminated }) else {
            model.applicationNavigationDiagnostics = "请先打开抖音，再检查导航。"
            return
        }
        model.applicationNavigationDiagnostics = "正在检查；结果显示在通用 → 应用内遥控 → 导航诊断结果。"
        let settleDelay: TimeInterval = app.isActive ? 0 : 0.8
        WindowSwitcher.activateApplication(app) { [weak self] _ in
            // Fullscreen activation can deliver a later Space notification. Let the
            // controller establish the final session before a read-only scan.
            DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) { [weak self] in
                self?.applicationNavigation.diagnoseDouyin { [weak self] production in
                    self?.model.applicationNavigationDiagnostics = production
                }
            }
        }
    }

    private func openOverlay(_ name: String) {
        if name == "dock_picker" {
            overlayCenter?.close()
            if !dockNavigation.isActive { dockReturnApplication = NSWorkspace.shared.frontmostApplication }
            dockNavigation.toggle()
        } else {
            dockNavigation.close()
            overlayCenter?.open(name)
        }
    }

    private func updateNavigationSuspension() {
        applicationNavigation.setSuspended(
            overlayCenter?.hasActiveOverlay == true || dockNavigation.isActive
                || MouseMode.shared.isActive || services?.keyMapper?.engine.isSuspended == true)
    }

    @objc private func startVoiceProbe() {
        guard services != nil else { return }
        if voiceProbeRunning { voiceProbePanel?.makeKeyAndOrderFront(nil); return }
        if voiceProbePanel == nil {
            let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 650, height: 370),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "遥控器连续收音验证"
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            let label = NSTextField(wrappingLabelWithString: "")
            label.frame = CGRect(x: 24, y: 70, width: 602, height: 272)
            label.font = .systemFont(ofSize: 14)
            panel.contentView?.addSubview(label)
            let cancel = NSButton(title: "结束测试", target: self, action: #selector(cancelVoiceProbe))
            cancel.frame = CGRect(x: 510, y: 22, width: 116, height: 32)
            panel.contentView?.addSubview(cancel)
            let start = NSButton(title: "开始测试", target: self, action: #selector(beginVoiceProbe))
            start.frame = CGRect(x: 380, y: 22, width: 116, height: 32)
            panel.contentView?.addSubview(start)
            voiceProbePanel = panel
            voiceProbeLabel = label
        }
        voiceProbeLabel?.stringValue = "仅统计本机音频帧和电平，不保存或识别声音。\n准备好后点“开始测试”：按住语音键说话约 2 秒，再松开。松手 1 秒后继续说话，看到测试完成即可停止。"
        voiceProbePanel?.center()
        voiceProbePanel?.makeKeyAndOrderFront(nil)
    }

    @objc private func beginVoiceProbe() {
        guard let services, !voiceProbeRunning else { return }
        voiceProbeGeneration &+= 1
        let token = voiceProbeGeneration
        voiceProbeRunning = true
        // 诊断期间只禁用语音键的普通应用动作，避免测试松手后移动输入焦点。
        var quiet = model.config
        for name in quiet.profiles.keys {
            quiet.profiles[name]?["voice"] = KeyBinding(tap: Action.none, hold: Action.none)
        }
        services.keyMapper?.engine.setConfig(quiet)
        services.bridge.startVoiceContinuityProbe(onUpdate: { [weak self] text in
            guard let self, self.voiceProbeGeneration == token, self.voiceProbeRunning else { return }
            self.voiceProbeLabel?.stringValue = text
        }, completion: { [weak self] report in
            guard let self, self.voiceProbeGeneration == token else { return }
            self.voiceProbeRunning = false
            self.voiceProbeLabel?.stringValue = report.summary
            self.services?.keyMapper?.engine.setConfig(self.model.config)
        })
    }

    @objc private func cancelVoiceProbe() {
        guard voiceProbeRunning else { return }
        // 等 bridge 完成关闭与回声隔离后，由同一 completion 恢复映射。
        // 关闭窗口只隐藏面板，不能抢先允许下一次测试。
        services?.bridge.cancelVoiceContinuityProbe()
        voiceProbeLabel?.stringValue = "正在关闭麦克风并恢复普通语音，请稍候。"
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 退出确认（可在通用页关闭）：仅在引擎真的在跑时提示。
        guard model.exitConfirm, let services, services.started, !uiPreview else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "退出 MiRemote？"
        alert.informativeText = "退出后遥控器将不再控制这台 Mac，按键中转会恢复，真实键盘不受影响。"
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    // MARK: 窗口双形态

    private func showWindow() {
        if window == nil {
            let root = RootView().environmentObject(model!)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "MiRemote 设置"
            w.contentView = NSHostingView(rootView: root)
            w.center()
            w.isReleasedWhenClosed = false
            w.delegate = self
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === voiceProbePanel {
            cancelVoiceProbe()
            return true
        }
        // 首次关窗说明「关窗 ≠ 退出」（N-10/25/27 心智坑）：一次性面板 + 不再提示
        let d = UserDefaults.standard
        if !d.bool(forKey: Prefs.closeNoticeAcknowledged) {
            let alert = NSAlert()
            alert.messageText = "MiRemote 常驻 Dock 与菜单栏，继续工作"
            alert.informativeText = """
            关闭窗口不会退出：MiRemote 会保留在 Dock 和菜单栏，继续控制遥控器。
            · 想再打开设置：点 Dock 中的 MiRemote，或点菜单栏遥控器图标。
            · 想真正退出：菜单栏图标 →「退出 MiRemote」（退出时自动恢复真实键盘）。
            · 卸载前请务必先退出，否则按键中转可能残留、影响真实键盘。
            """
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "不再提示"
            alert.addButton(withTitle: "知道了")
            alert.runModal()
            if alert.suppressionButton?.state == .on {
                d.set(true, forKey: Prefs.closeNoticeAcknowledged)
            }
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        // 关窗不退出：Dock/菜单栏入口保留，服务照跑。
    }

    // MARK: 服务事件接线

    private func wireCallbacks(services: AppServices, levelSink: LevelMeterSink) {
        let healthConnection = services.voiceApp.onConnection
        services.voiceApp.onConnection = { [weak self] ok, name in
            healthConnection?(ok, name)
            DispatchQueue.main.async {
                self?.model.noteConnection(ok, name: name)
                if !ok { self?.dockNavigation.close() }
            }
        }
        services.voiceApp.onVoiceActive = { [weak self] active in
            DispatchQueue.main.async { self?.model.noteVoice(active) }
        }
        services.bridge.onBatteryLevel = { [weak self] pct in
            DispatchQueue.main.async { self?.model.noteBattery(pct) }
        }
        levelSink.onLevel = { [weak self] rms in
            DispatchQueue.main.async { self?.model.noteLevel(rms) }
        }
        services.health.onChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.model.degraded = state != .healthy
            }
        }
        // show_ui 事件（第二实例经 events.sock 请求弹设置窗口）：start() 里会重设 onEvent，
        // 延后一拍再包一层，拦截 show_ui、其余事件照旧走通知。
        DispatchQueue.main.async { [weak self] in
            let previous = services.eventListener.onEvent
            services.eventListener.onEvent = { [weak self] event in
                if event.kind == .showUI {
                    DispatchQueue.main.async { self?.showWindow() }
                    return
                }
                previous?(event)
            }
        }
        // keys 链路的钩子要等 start() 建好 keyMapper 才能挂——start 是同步的，这里延后一拍挂。
        DispatchQueue.main.async { [weak self] in
            guard let self, let km = services.keyMapper, let filter = services.hidFilter else { return }
            self.dockNavigation.engine = km.engine
            km.engine.onApplicationNavigation = { [weak self] key, down in
                MainActor.assumeIsolated { self?.applicationNavigation.handle(key, isDown: down) }
            }
            km.engine.onApplicationNavigationReservedDirection = { [weak self] key, phase in
                MainActor.assumeIsolated { self?.applicationNavigation.handleReservedDirection(key, phase: phase) }
            }
            self.applicationNavigation.onCaptureChanged = { [weak self, weak km] enabled in
                km?.engine.setApplicationNavigationEnabled(enabled)
                guard let self else { return }
                self.overlayCenter?.noteApplicationNavigation(
                    mode: enabled ? self.applicationNavigation.navigationMode : nil,
                    editing: self.applicationNavigation.isEditing)
            }
            self.applicationNavigation.onStatusChanged = { [weak self] text in
                self?.model.applicationNavigationStatus = text
                guard let self else { return }
                self.overlayCenter?.noteApplicationNavigation(
                    mode: self.applicationNavigation.isEnabled ? self.applicationNavigation.navigationMode : nil,
                    editing: self.applicationNavigation.isEditing)
            }
            self.applicationNavigation.configure(self.model.config.appNavigationProfiles ?? [:])
            self.model.onApplicationNavigationConfigChanged = { [weak self] profiles in
                self?.applicationNavigation.configure(profiles)
            }
            FocusInput.onDidFocusInput = { [weak self] in
                MainActor.assumeIsolated { self?.applicationNavigation.enterEditing() }
            }
            let previousSuspend = km.engine.onSuspendChanged
            km.engine.onSuspendChanged = { [weak self] suspended in
                previousSuspend?(suspended)
                if suspended { DispatchQueue.main.async { self?.dockNavigation.close() } }
                DispatchQueue.main.async { self?.updateNavigationSuspension() }
            }
            if let hid = services.hidEngine {
                let previousRemoved = hid.onDeviceRemoved
                hid.onDeviceRemoved = { [weak self] in
                    previousRemoved?()
                    DispatchQueue.main.async { self?.dockNavigation.close() }
                    DispatchQueue.main.async { self?.applicationNavigation.invalidateSelection() }
                }
            }
            km.onLayerChanged = { [weak self] layer in
                DispatchQueue.main.async {
                    self?.model.noteLayer(layer)
                    self?.overlayCenter?.noteLayer(layer)   // 层2=App 控制模式 HUD
                }
            }
            // 全局逃生键（长按菜单 1.5s）：引擎已自清层态与捕获态，主线程回调；
            // UI 侧同步收掉全部浮层/HUD（角标随 onLayerChanged 归零自动消失）。
            km.engine.onEscapeHatch = { [weak self] in
                MainActor.assumeIsolated {
                    self?.dockNavigation.close()
                    self?.applicationNavigation.invalidateSelection()
                    if self?.voiceProbeRunning == true { self?.cancelVoiceProbe() }
                    self?.overlayCenter?.escapeHatch()
                }
            }
            km.engine.onGlobalAction = { [weak self] action in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch action {
                    case .overlay, .openApp, .mouseMode, .system("quit_app"), .system("app_mru_back"),
                         .system("space_left"), .system("space_right"), .system("show_desktop"):
                        self.applicationNavigation.invalidateSelection()
                    default: break
                    }
                    switch action {
                    case .overlay(let name): self.openOverlay(name)
                    case .mouseMode:
                        self.dockNavigation.close()
                        self.overlayCenter?.close()
                        MouseMode.shared.toggle()
                        self.updateNavigationSuspension()
                    case .system("quit_app"):
                        // Capture the foreground application before closing panels.
                        if self.dockNavigation.isActive {
                            let target = self.dockReturnApplication
                            self.dockNavigation.close()
                            WorkspaceActions.requestQuit(target)
                        } else { ActionRunner().run(action) }
                        self.overlayCenter?.close()
                        MouseMode.shared.deactivate()
                    case .openApp, .system("app_mru_back"), .system("show_desktop"):
                        self.dockNavigation.close()
                        self.overlayCenter?.close()
                        MouseMode.shared.deactivate()
                        ActionRunner().run(action)
                    default:
                        self.dockNavigation.close()
                        ActionRunner().run(action)
                    }
                }
            }
            // model.degraded 只经 services.health.onChange（下方已接线）单一来源写入——
            // 它汇总 tap/映射/权限/蓝牙四个健康源；km.onSeizeState 在 AppServices.start()
            // 里已接到 health.setTapAlive，这里不再叠加一层直接覆盖 degraded 的旁路，
            // 否则两个写者互相打架：tap 一恢复就把「映射仍缺失」的真实故障态错误地清成正常。
            // per-app profile 切换提示（切到飞书闪「OK=⌘Return」这类）。
            // 链式包裹：AppServices 已经把语音规则切换挂在这个钩子上，直接赋值会把它顶掉。
            let previousActiveApp = km.onActiveApplication
            km.onActiveApplication = { [weak self] bundleID in
                previousActiveApp?(bundleID)
                DispatchQueue.main.async { self?.overlayCenter?.noteProfileSwitch(bundleID) }
            }
            km.onButtonEvent = { [weak self] ev in
                DispatchQueue.main.async { self?.model.noteButton(ev) }
            }
            // IOHID 原始通道：全部 13 键的「按下即亮」与识别按键都靠它。
            filter.onRawButton = { [weak self] ev in
                DispatchQueue.main.async { self?.model.noteButton(ev) }
            }
        }
    }
}
