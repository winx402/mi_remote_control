import AppKit
import ApplicationServices
import Carbon
import CoreAudio

/// Codex 专用的两按听写。这里只控制已配置的输入法／系统听写，绝不发送 Return。
/// 遥控器松手后的持续 PCM 尚未验证，因此仅使用当前真实默认输入设备，不重开遥控器麦克风。
enum CodexDictation {
    static let actionName = "codex_context_dictate"
    @MainActor static var onNotice: ((String) -> Void)?
    /// true 表示已投递开始动作；不能据此宣称第三方已经收音或成功识别。
    @MainActor static var onStateChanged: ((Bool) -> Void)?
    @MainActor private static var triggerConfig = VoiceTriggerConfig()

    private enum Route {
        case inputMethod(VoiceTriggerConfig)
        case system(AXUIElement)
    }
    private struct Session {
        let pid: pid_t
        let inputDevice: AudioDeviceID
        let route: Route
    }
    @MainActor private static var session: Session?
    @MainActor private static var preparing = false
    @MainActor private static var generation: UInt64 = 0
    @MainActor private static var savedInputSource: TISInputSource?
    @MainActor private static var selectedInputPrefix: String?
    @MainActor private static var restoreTask: Task<Void, Never>?
    @MainActor private static var contextTimer: Timer?
    @MainActor static var isActive: Bool { preparing || session != nil }

    @MainActor static func configure(triggerConfig: VoiceTriggerConfig) {
        self.triggerConfig = triggerConfig
    }

    @discardableResult static func perform(_ name: String) -> Bool {
        guard name == actionName else { return false }
        Task { @MainActor in toggleIfCurrent() }
        return true
    }

    /// 调度端已在主线程验证动作代次时直接调用，避免第二次异步跳转越过上下文边界。
    @MainActor static func toggleIfCurrent() {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.openai.codex" else { return }
        toggle()
    }

    static func cancel(reason: String = "上下文改变") {
        Task { @MainActor in stop(reason: reason, restoreImmediately: true) }
    }

    /// 生命周期主线程可同步清理，防止退出前 Task 尚未运行。
    @MainActor static func shutdown() { stop(reason: "服务停止", restoreImmediately: true) }

    @MainActor private static func toggle() {
        if preparing || session != nil {
            stop(reason: nil, restoreImmediately: false)
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              CodexNavigation.isAllowedBundle(app.bundleIdentifier) else {
            notice("请先将 Codex 切到前台，再使用听写。")
            return
        }
        guard AXIsProcessTrusted() else {
            notice("需要辅助功能权限，Codex 听写未开始。")
            return
        }
        guard CodexConversationControls.focusForDictation(), stillFrontmost(app.processIdentifier) else {
            notice("无法确认 Codex 当前可编辑的聊天／表单输入框，本次未开始听写。")
            return
        }
        guard let input = currentUsableInput() else {
            notice("输入框已聚焦，但未检测到可持续收音的默认麦克风。请连接并选择 Mac／外接／连续互通麦克风；遥控器松手后收音尚未验证，本次未开始听写。")
            return
        }
        generation &+= 1
        let token = generation
        restoreTask?.cancel()
        restoreTask = nil

        // 已启用且可选中的输入法优先；未启用微信时只尝试明确的系统听写菜单。
        let cfg = triggerConfig
        if let prefix = cfg.imeBundlePrefix,
           cfg.mode == .hold,
           VoiceTriggerConfig.keyTable[cfg.keyName] != nil,
           let source = enabledInputSource(prefix: prefix) {
            if savedInputSource == nil {
                savedInputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
            }
            guard TISSelectInputSource(source) == noErr else {
                restoreIME()
                notice("无法切换到已配置的语音输入法，本次未开始听写。")
                return
            }
            selectedInputPrefix = prefix
            preparing = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                guard preparing, generation == token else { return }
                guard stillFrontmost(app.processIdentifier),
                      currentUsableInput()?.id == input.id,
                      currentInputSourceMatches(prefix: prefix),
                      CodexConversationControls.focusForDictation(),
                      stillFrontmost(app.processIdentifier) else {
                    stop(reason: "输入框、输入法或音源已改变，听写未开始", restoreImmediately: true)
                    return
                }
                guard startHotkey(cfg) else {
                    stop(reason: "无法发送听写快捷键，听写未开始", restoreImmediately: true)
                    return
                }
                preparing = false
                session = Session(pid: app.processIdentifier, inputDevice: input.id, route: .inputMethod(cfg))
                didStart(inputName: input.name, method: "语音输入法快捷键已发送")
            }
            return
        }

        restoreIME()
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.05)
        guard let start = dictationMenuItem(in: axApp, stopping: false),
              stillFrontmost(app.processIdentifier),
              currentUsableInput()?.id == input.id,
              AXUIElementPerformAction(start, kAXPressAction as CFString) == .success else {
            let reason = cfg.mode != .hold ? "输入法未设置为可安全释放的“按住说话”触发方式"
                : cfg.imeBundlePrefix == nil ? "未配置可验证的语音输入法" : "未启用所选语音输入法"
            notice("\(reason)，Codex 也未提供可用的“开始听写”菜单。请启用微信语音输入并匹配按住快捷键，或在系统键盘设置中启用听写；本次未开始。")
            return
        }
        session = Session(pid: app.processIdentifier, inputDevice: input.id, route: .system(axApp))
        didStart(inputName: input.name, method: "系统开始听写已请求")
    }

    @MainActor private static func didStart(inputName: String, method: String) {
        onStateChanged?(true)
        notice("\(method) · 音源：\(inputName)。再按语音键结束，不会发送消息。")
        contextTimer?.invalidate()
        contextTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            Task { @MainActor in
                guard let session else { return }
                guard stillFrontmost(session.pid), currentUsableInput()?.id == session.inputDevice else {
                    stop(reason: "应用或默认麦克风已改变", restoreImmediately: true)
                    return
                }
                if case .inputMethod(let config) = session.route,
                   let prefix = config.imeBundlePrefix, !currentInputSourceMatches(prefix: prefix) {
                    stop(reason: "语音输入法已改变", restoreImmediately: true)
                }
            }
        }
    }

    @MainActor private static func stop(reason: String?, restoreImmediately: Bool) {
        let wasPreparing = preparing
        let old = session
        preparing = false
        session = nil
        generation &+= 1
        let token = generation
        contextTimer?.invalidate()
        contextTimer = nil
        var confirmedStop = true
        if let old {
            switch old.route {
            case .inputMethod(let cfg):
                // hold 只释放原按键；tap/double 必须仍在原 App／输入法中才发送结束单击。
                if cfg.mode == .hold { confirmedStop = post(down: false, config: cfg) }
                else if stillFrontmost(old.pid),
                        cfg.imeBundlePrefix.map({ currentInputSourceMatches(prefix: $0) }) == true {
                    confirmedStop = tap(cfg)
                } else {
                    confirmedStop = false
                }
            case .system(let axApp):
                // 针对原 Codex 的明确菜单收尾，不向新前台 App 投递猜测的快捷键。
                if let item = dictationMenuItem(in: axApp, stopping: true) {
                    confirmedStop = AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                } else {
                    // 开始菜单重新可用是已经结束的明确状态；两者都缺失时保留不确定会话。
                    confirmedStop = dictationMenuItem(in: axApp, stopping: false) != nil
                }
            }
        }
        if !confirmedStop { session = old }
        onStateChanged?(isActive)
        restoreTask?.cancel()
        restoreTask = nil
        if restoreImmediately { restoreIME() }
        else if savedInputSource != nil {
            restoreTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                guard generation == token, session == nil, !preparing else { return }
                restoreIME()
                restoreTask = nil
            }
        }
        guard old != nil || wasPreparing else { return }
        if !confirmedStop {
            notice("无法确认语音工具已停止，请在语音工具／系统听写浮层手动结束。本次没有发送消息。")
        } else if let reason {
            notice("\(reason)，已请求结束听写；没有发送消息。")
        } else {
            notice(wasPreparing ? "已取消听写开始；没有发送消息。" : "已发送结束听写动作；没有发送消息。")
        }
    }

    // MARK: - 只读音源与输入法检查

    struct InputDevice: Equatable { let id: AudioDeviceID; let name: String }

    /// 不枚举／打开录音流，不改系统默认设备。包括正常暴露的 iPhone 连续互通输入。
    static func currentUsableInput() -> InputDevice? {
        guard let device = DefaultInput.currentDefault() else { return nil }
        var aliveAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var alive: UInt32 = 0
        var aliveBytes = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &aliveAddress, 0, nil, &aliveBytes, &alive) == noErr,
              alive != 0 else { return nil }
        var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &bytes) == noErr, bytes > 0 else { return nil }
        var transportAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var transportBytes = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &transportAddress, 0, nil, &transportBytes, &transport) == noErr,
              transport != kAudioDeviceTransportTypeVirtual else { return nil }
        var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var nameBytes = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameBytes, &name) == noErr,
              let name else { return nil }
        let value = name.takeRetainedValue() as String
        guard !value.lowercased().contains("blackhole") else { return nil }
        return InputDevice(id: device, name: value)
    }

    @MainActor private static func enabledInputSource(prefix: String) -> TISInputSource? {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else { return nil }
        return list.first { source in
            guard sourceString(source, kTISPropertyBundleID)?.hasPrefix(prefix) == true,
                  sourceString(source, kTISPropertyInputSourceCategory) == (kTISCategoryKeyboardInputSource as String),
                  let enabled = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled) else { return false }
            return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(enabled).takeUnretainedValue())
        }
    }

    @MainActor private static func sourceString(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    @MainActor private static func currentInputSourceMatches(prefix: String) -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return false }
        return sourceString(source, kTISPropertyBundleID)?.hasPrefix(prefix) == true
    }

    @MainActor private static func restoreIME() {
        // 用户主动更换过输入法时保留用户选择，不覆盖成会话前的旧输入法。
        if let savedInputSource, let selectedInputPrefix,
           currentInputSourceMatches(prefix: selectedInputPrefix) {
            _ = TISSelectInputSource(savedInputSource)
        }
        savedInputSource = nil
        selectedInputPrefix = nil
    }

    @MainActor private static func stillFrontmost(_ pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    @MainActor private static func notice(_ message: String) {
        log("Codex 听写：\(message)")
        onNotice?(message)
    }

    // MARK: - 明确的系统菜单动作（不读取消息正文）

    static func menuTitleMatches(_ title: String, stopping: Bool) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".…"))
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let starts: Set<String> = ["start dictation", "开始听写", "開始聽寫"]
        let stops: Set<String> = ["stop dictation", "停止听写", "结束听写", "停止聽寫", "結束聽寫"]
        return (stopping ? stops : starts).contains(normalized)
    }

    private static func dictationMenuItem(in app: AXUIElement, stopping: Bool) -> AXUIElement? {
        var menu: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menu) == .success,
              let menu, CFGetTypeID(menu) == AXUIElementGetTypeID() else { return nil }
        var queue: [(AXUIElement, Int)] = [(menu as! AXUIElement, 0)]
        var cursor = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        while cursor < queue.count, cursor < 180, ProcessInfo.processInfo.systemUptime < deadline {
            let (element, depth) = queue[cursor]
            cursor += 1
            var title: CFTypeRef?
            var enabled: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success,
               let title = title as? String, menuTitleMatches(title, stopping: stopping),
               AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled) == .success,
               let enabled, CFGetTypeID(enabled) == CFBooleanGetTypeID(),
               CFBooleanGetValue((enabled as! CFBoolean)) { return element }
            guard depth < 5 else { continue }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let children = children as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(180).map { ($0, depth + 1) })
            }
        }
        return nil
    }

    // MARK: - 会话锁存的输入法触发键

    private static func startHotkey(_ cfg: VoiceTriggerConfig) -> Bool {
        switch cfg.mode {
        case .hold: return post(down: true, config: cfg)
        case .tap: return tap(cfg)
        case .double:
            guard tap(cfg) else { return false }
            usleep(80_000)
            return tap(cfg)
        }
    }

    private static func tap(_ cfg: VoiceTriggerConfig) -> Bool {
        guard post(down: true, config: cfg) else { return false }
        usleep(25_000)
        return post(down: false, config: cfg)
    }

    private static func post(down: Bool, config: VoiceTriggerConfig) -> Bool {
        guard let (keycode, flag, deviceBit) = VoiceTriggerConfig.keyTable[config.keyName],
              let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState),
                                  virtualKey: keycode, keyDown: down) else { return false }
        if let flag {
            event.type = .flagsChanged
            var flags: CGEventFlags = []
            if down {
                flags.insert(flag)
                if let deviceBit { flags.insert(CGEventFlags(rawValue: deviceBit)) }
            }
            event.flags = flags
        }
        event.post(tap: .cghidEventTap)
        return true
    }

    /// 纯菜单语义验收，不访问真实 Codex、不合成键盘或启动录音。
    static func selfCheck() -> Bool {
        menuTitleMatches("Start Dictation…", stopping: false)
            && menuTitleMatches("开始听写...", stopping: false)
            && menuTitleMatches("停止聽寫", stopping: true)
            && !menuTitleMatches("Start Dictation", stopping: true)
            && !menuTitleMatches("Send", stopping: true)
            && !menuTitleMatches("Stop", stopping: true)
            && !menuTitleMatches("Start Dictation and Send", stopping: false)
    }
}
