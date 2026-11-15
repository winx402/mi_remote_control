import AppKit
import os
import ApplicationServices
import Carbon
import CoreAudio

/// Codex 听写：新预设按住遥控器说话、松手结束；旧两按动作保留兼容。
/// 遥控器 PCM 直接本机识别，识别结果只写回原输入框，绝不发送 Return。
enum CodexDictation {
    static let actionName = "codex_context_dictate"
    @MainActor static var onNotice: ((String) -> Void)?
    /// true 表示已投递开始动作；不能据此宣称第三方已经收音或成功识别。
    @MainActor static var onStateChanged: ((Bool) -> Void)?
    @MainActor private static var triggerConfig = VoiceTriggerConfig()
    /// 服务容器同步打开／关闭遥控器 PCM 交付；映射引擎是长按判定的唯一来源。
    @MainActor static var onPhysicalHoldState: ((Bool) -> Void)?
    @MainActor private static var useRemoteMicrophone = true
    @MainActor private static var inputEnabled = true
    @MainActor private static var physicalHoldActive = false
    @MainActor private static var remoteGeneration: UInt64 = 0
    @MainActor private static var remoteSession: RemoteSession?
    @MainActor private static var remoteTimer: Timer?
    @MainActor private static var finalTimeout: Task<Void, Never>?

    private struct RemoteTarget {
        let pid: pid_t
        let element: AXUIElement
        let window: AXUIElement
        let selection: CFRange?
    }
    private struct RemoteSession {
        let target: RemoteTarget
        let recognizer: RemoteSpeechTranscriber
        var released = false
        var finalText: String?
    }

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
    @MainActor static var remotePCMToken: UInt64 { remoteGeneration }
    @MainActor static var isActive: Bool { preparing || session != nil || physicalHoldActive || remoteSession != nil }

    @MainActor static func configure(triggerConfig: VoiceTriggerConfig) {
        self.triggerConfig = triggerConfig
    }

    @MainActor static func configureInput(remoteMicrophone: Bool, enabled: Bool) {
        if useRemoteMicrophone != remoteMicrophone || inputEnabled != enabled {
            stop(reason: "音源设置改变", restoreImmediately: true)
        }
        useRemoteMicrophone = remoteMicrophone
        inputEnabled = enabled
    }

    /// 仅由映射引擎确认长按后调用；短按不会请求识别、切换输入法或写入文本。
    @MainActor static func beginPhysicalHold() {
        guard inputEnabled, !physicalHoldActive else { return }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.openai.codex" else { return }
        // 新一次按住不能把上次尚在等待的识别结果写进新上下文。
        stop(reason: nil, restoreImmediately: true)
        guard useRemoteMicrophone else {
            physicalHoldActive = true
            toggle()
            return
        }
        guard AXIsProcessTrusted(), CodexConversationControls.focusForDictation(),
              let target = captureRemoteTarget() else {
            notice("无法确认 Codex 当前可编辑的输入框或辅助功能权限，本次未开始听写。")
            return
        }
        guard let unavailable = RemoteSpeechTranscriber.availabilityNotice() else {
            remoteGeneration &+= 1
            let token = remoteGeneration
            guard let recognizer = RemoteSpeechTranscriber(completion: { text, failure in
                receiveRecognition(text: text, failure: failure, token: token)
            }) else {
                notice("本机中文语音识别暂不可用，本次未开始听写。")
                return
            }
            remoteSession = RemoteSession(target: target, recognizer: recognizer)
            physicalHoldActive = true
            onPhysicalHoldState?(true)
            onStateChanged?(true)
            notice("遥控器听写中；松开语音键结束，文字不会自动发送。")
            remoteTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                Task { @MainActor in
                    guard let remoteSession else { return }
                    guard remoteTargetIsCurrent(remoteSession.target) else {
                        stop(reason: "应用、窗口或输入焦点改变", restoreImmediately: true)
                        return
                    }
                }
            }
            return
        }
        notice(unavailable)
    }

    @MainActor static func endPhysicalHold() {
        guard physicalHoldActive else { return }
        physicalHoldActive = false
        onPhysicalHoldState?(false) // 立即拒绝松手后的 PCM，再等待已采集音频的最终结果。
        guard var current = remoteSession else {
            stop(reason: nil, restoreImmediately: false)
            return
        }
        current.released = true
        remoteSession = current
        current.recognizer.endAudio()
        if let text = current.finalText {
            finishRemote(text: text)
            return
        }
        notice("已停止收音，正在整理文字；不会自动发送。")
        let token = remoteGeneration
        finalTimeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, remoteGeneration == token, remoteSession != nil else { return }
            stop(reason: "未及时取得最终识别结果，本次文字已丢弃", restoreImmediately: true)
        }
    }

    /// AppServices 在主线程按 ATVV 顺序投递；松手及取消后不再接收。
    @MainActor static func receiveRemotePCM(_ samples: [Int16], token: UInt64) {
        guard token == remoteGeneration, physicalHoldActive, let current = remoteSession else { return }
        current.recognizer.append(samples)
    }

    @MainActor static func endRemoteTransport(token: UInt64) {
        guard token == remoteGeneration else { return }
        endPhysicalHold()
    }

    @MainActor static func cancelRemoteTransport(token: UInt64) {
        guard token == remoteGeneration else { return }
        stop(reason: "遥控器音频链路停止", restoreImmediately: true)
    }

    @MainActor static func reportPermissionResult(approved: Bool) {
        notice(approved ? "语音识别已获允许；请重新按住语音键说话。"
               : "未获得语音识别权限；可在系统设置 → 隐私与安全性 → 语音识别中开启。")
    }

    @MainActor private static func receiveRecognition(text: String?, failure: String?, token: UInt64) {
        guard token == remoteGeneration, var current = remoteSession else { return }
        guard remoteTargetIsCurrent(current.target) else {
            stop(reason: "识别期间输入上下文改变，文字已丢弃", restoreImmediately: true)
            return
        }
        if let text {
            current.finalText = text
            remoteSession = current
            if current.released { finishRemote(text: text) }
        } else if let failure {
            stop(reason: failure, restoreImmediately: true)
        }
    }

    @MainActor private static func finishRemote(text: String) {
        guard let current = remoteSession, current.released else { return }
        let safeText = sanitizedText(text)
        guard !safeText.isEmpty else {
            stop(reason: "没有识别到文字", restoreImmediately: true)
            return
        }
        // 优先直接写原控件；Chromium 未实现 AXSelectedText 时，向原 pid 投递无修饰键 Unicode。
        guard remoteTargetIsCurrent(current.target), insertRemoteText(safeText, target: current.target) else {
            stop(reason: "原输入框已改变或不支持安全写入，识别文字已丢弃", restoreImmediately: true)
            return
        }
        clearRemote()
        onStateChanged?(false)
        notice("已向 Codex 原输入框投递文字，尚未发送。")
    }

    @MainActor private static func clearRemote() {
        remoteGeneration &+= 1
        let hadPhysicalSession = physicalHoldActive || remoteSession != nil
        physicalHoldActive = false
        if hadPhysicalSession { onPhysicalHoldState?(false) }
        remoteSession?.recognizer.cancel()
        remoteSession = nil
        remoteTimer?.invalidate()
        remoteTimer = nil
        finalTimeout?.cancel()
        finalTimeout = nil
    }

    @MainActor private static func captureRemoteTarget() -> RemoteTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.openai.codex" else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused = axElement(axApp, attribute: kAXFocusedUIElementAttribute),
              let window = axElement(focused, attribute: kAXWindowAttribute) else { return nil }
        return RemoteTarget(pid: app.processIdentifier, element: focused, window: window, selection: selectedRange(focused))
    }

    @MainActor private static func remoteTargetIsCurrent(_ target: RemoteTarget) -> Bool {
        guard stillFrontmost(target.pid),
              let focused = axElement(AXUIElementCreateApplication(target.pid), attribute: kAXFocusedUIElementAttribute),
              CFEqual(focused, target.element),
              let window = axElement(focused, attribute: kAXWindowAttribute), CFEqual(window, target.window) else { return false }
        if let expected = target.selection {
            guard let range = selectedRange(focused), range.location == expected.location,
                  range.length == expected.length else { return false }
        }
        return true
    }

    static func sanitizedText(_ text: String) -> String {
        text.components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor private static func insertRemoteText(_ text: String, target: RemoteTarget) -> Bool {
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(target.element, kAXSelectedTextAttribute as CFString, &settable) == .success,
           settable.boolValue,
           AXUIElementSetAttributeValue(target.element, kAXSelectedTextAttribute as CFString, text as CFString) == .success {
            return true
        }
        // 一次有界 Unicode 事件，避免分段投递期间焦点变化。绝不使用 Return、粘贴或全局事件 tap。
        let unicode = Array(text.utf16)
        guard !unicode.isEmpty, unicode.count <= 8_192, remoteTargetIsCurrent(target),
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
        down.flags = []
        up.flags = []
        down.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode)
        up.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode)
        guard remoteTargetIsCurrent(target) else { return false }
        down.postToPid(target.pid)
        up.postToPid(target.pid)
        return true
    }

    private static func axElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var range = CFRange()
        guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
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
        notice("\(method) · 音源：\(inputName)。松开语音键结束；旧版两按动作可再按结束，不会发送消息。")
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
        let hadRemote = remoteSession != nil
        let hadPhysical = physicalHoldActive
        clearRemote()
        if hadRemote, let reason { notice("\(reason)；没有发送消息。") }
        if hadRemote || hadPhysical { onStateChanged?(false) }
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
        Logger(subsystem: "com.miremote.controller", category: "RemoteSpeech").notice("\(message, privacy: .public)")
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
        RemotePCMHoldGate.selfCheck()
            && sanitizedText("hello\r\nworld\t\u{1B}") == "hello  world"
            && menuTitleMatches("Start Dictation…", stopping: false)
            && menuTitleMatches("开始听写...", stopping: false)
            && menuTitleMatches("停止聽寫", stopping: true)
            && !menuTitleMatches("Start Dictation", stopping: true)
            && !menuTitleMatches("Send", stopping: true)
            && !menuTitleMatches("Stop", stopping: true)
            && !menuTitleMatches("Start Dictation and Send", stopping: false)
    }
}
