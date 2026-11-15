import AppKit
import os
import ApplicationServices
import Carbon
import CoreAudio

/// Codex 听写：新预设按住遥控器说话、松手结束；旧两按动作保留兼容。
/// 微信输入法通过 BlackHole 接收遥控器 PCM；系统本机识别为可选回退。
/// 两条路径均锁存原输入框，绝不发送 Return。
enum CodexDictation {
    static let actionName = "codex_context_dictate"
    @MainActor static var onNotice: ((String) -> Void)?
    /// true 表示已投递开始动作；不能据此宣称第三方已经收音或成功识别。
    @MainActor static var onStateChanged: ((Bool) -> Void)?
    @MainActor private static var triggerConfig = VoiceTriggerConfig()
    /// 服务容器同步打开／关闭遥控器 PCM 交付；映射引擎是长按判定的唯一来源。
    @MainActor static var onPhysicalHoldState: ((Bool) -> Void)?
    /// HID 松手只请求收尾；ATVV STOP／有界等待及已排队 PCM 交付后才结束识别。
    @MainActor static var onPhysicalHoldRelease: ((UInt64) -> Void)?
    /// 新 Codex 会话开始前，清理通用语音工具仍在持有的键／延迟恢复。
    @MainActor static var onPhysicalHoldPrepare: (() -> Void)?
    @MainActor private static var voiceEngine: CodexVoiceEngine = .wechat
    @MainActor private static var bridgeDeviceName = "BlackHole 2ch"
    @MainActor private static var remoteIME: RemoteInputMethodSession?
    @MainActor private static var remoteIMEFinishing: RemoteInputMethodSession?
    @MainActor private static var remoteIMEFinishingTimer: Timer?
    @MainActor private static var remoteIMETransportToken: UInt64?
    @MainActor private static var remoteIMEStopID: UUID?
    @MainActor private static var remoteIMEStartTask: Task<Void, Never>?
    @MainActor private static var remoteIMEReadyTimeout: Task<Void, Never>?
    @MainActor private static var remoteIMEStartup = RemotePCMStartupGate()
    @MainActor private static var remoteIMEOutputWarmup: AudioBridge?
    @MainActor private static var remoteIMEOutputWarmupDevice: String?
    @MainActor private static var bridgeRestoreTask: Task<Void, Never>?
    @MainActor private static var bridgePreviousInput: AudioDeviceID?
    @MainActor private static var bridgeInput: AudioDeviceID?
    private struct RemoteInputMethodSession {
        let target: RemoteTarget
        let config: VoiceTriggerConfig
        let sink: AudioBridge
        let inputMethodPID: pid_t?
        var keyDown = false
        var captureWasStoppedBeforeStart = false
        var outputReady = false
        var captureReady: InputCaptureState?
    }
    @MainActor private static var useRemoteMicrophone = true
    @MainActor private static var inputEnabled = true
    @MainActor private static var physicalHoldActive = false
    @MainActor private static var physicalHoldStartedAt: TimeInterval?
    @MainActor private static var remoteReleaseRequested = false
    @MainActor private static var remotePCMSamples = 0
    @MainActor private static var remoteGeneration: UInt64 = 0
    @MainActor private static var remoteSession: RemoteSession?
    @MainActor private static var remoteTimer: Timer?
    @MainActor private static var remoteContext = RemoteDictationContextGuard()
    @MainActor private static var remoteContextQuarantined = false
    @MainActor private static var remoteContextTransportEnded = false
    @MainActor private static var finalTimeout: Task<Void, Never>?
    @MainActor private static var remotePasteTask: Task<Void, Never>?
    @MainActor private static var pasteboardLease: PasteboardLease?

    enum TargetScope { case codex, douyinLive }
    @MainActor private static var activeScope: TargetScope = .codex
    @MainActor private static var douyinTriggerConfig = VoiceTriggerConfig()
    @MainActor private static var targetLabel: String { activeScope == .codex ? "Codex" : "抖音直播" }
    @MainActor static var activeBundleID: String {
        activeScope == .codex ? "com.openai.codex" : DouyinLiveDictation.bundleID
    }
    @MainActor static func configureDouyin(triggerConfig: VoiceTriggerConfig) {
        douyinTriggerConfig = triggerConfig
    }
    @MainActor private static func focus(_ scope: TargetScope) -> Bool {
        scope == .codex ? CodexConversationControls.focusForDictation() : DouyinLiveDictation.focusForDictation()
    }
    @MainActor private static func resolvedField(_ scope: TargetScope) -> AXUIElement? {
        scope == .codex ? CodexConversationControls.resolvedDictationField() : DouyinLiveDictation.resolvedDictationField()
    }
    private struct RemoteTarget {
        let scope: TargetScope
        let contextID: String?
        let pid: pid_t
        let element: AXUIElement
        let window: AXUIElement
        let selection: CFRange?
        let characterCount: Int?
    }
    private struct RemoteSession {
        let target: RemoteTarget
        let recognizer: RemoteSpeechTranscriber
        var released = false
        var finalText: String?
    }

    /// Materialize every representation before taking ownership. A promised type
    /// that cannot be read makes this operation unavailable; it must not be lost.
    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
        let changeCount: Int
    }
    private struct PasteboardLease {
        let snapshot: PasteboardSnapshot
        let changeCount: Int
        let marker: Data
    }
    private static let pasteboardMarker = NSPasteboard.PasteboardType("com.miremote.dictation-paste-owner")

    private enum InsertionEvidence: Equatable {
        case textVerified, changeVerified, unconfirmed
    }

    private enum Route {
        case inputMethod(VoiceTriggerConfig)
        case system(AXUIElement)
    }
    private struct Session {
        let pid: pid_t
        let target: RemoteTarget?
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
    @MainActor static var isActive: Bool { preparing || session != nil || physicalHoldActive || remoteSession != nil || remoteIME != nil || remoteIMEFinishing != nil }

    @MainActor static func configure(triggerConfig: VoiceTriggerConfig) {
        self.triggerConfig = triggerConfig
    }

    @MainActor static func configureInput(remoteMicrophone: Bool, enabled: Bool,
                                              engine: CodexVoiceEngine = .wechat,
                                              bridgeDeviceName: String = "BlackHole 2ch") {
        if useRemoteMicrophone != remoteMicrophone || inputEnabled != enabled
            || voiceEngine != engine || self.bridgeDeviceName != bridgeDeviceName {
            stop(reason: "音源设置改变", restoreImmediately: true, showError: false)
        }
        useRemoteMicrophone = remoteMicrophone
        inputEnabled = enabled
        voiceEngine = engine
        self.bridgeDeviceName = bridgeDeviceName
        prewarmRemoteInputMethodOutput()
    }

    /// Pay the process's first AudioQueue initialization cost without selecting a
    /// microphone, sending an IME key, or retaining an idle output queue.
    @MainActor private static func prewarmRemoteInputMethodOutput() {
        guard useRemoteMicrophone, inputEnabled, voiceEngine == .wechat else {
            remoteIMEOutputWarmup?.cancelStream()
            remoteIMEOutputWarmup = nil
            return
        }
        guard remoteIMEOutputWarmupDevice != bridgeDeviceName else { return }
        remoteIMEOutputWarmup?.cancelStream()
        let sink = AudioBridge(deviceName: bridgeDeviceName, requiresNamedDevice: true)
        remoteIMEOutputWarmupDevice = bridgeDeviceName
        remoteIMEOutputWarmup = sink
        sink.streamStarted(sampleRate: 16_000) { [weak sink] ready in
            Task { @MainActor in
                guard let sink, remoteIMEOutputWarmup === sink else { return }
                remoteIMEOutputWarmup = nil
                sink.cancelStream()
                status("输出预热 engine=wechat ready=\(ready)；已请求释放纯输出队列")
            }
        }
    }

    /// 仅由映射引擎确认长按后调用；短按不会请求识别、切换输入法或写入文本。
    @MainActor static func beginPhysicalHold(scope: TargetScope = .codex) {
        // A second confirmed hold may supersede a released session still waiting
        // for cold startup; stop() below invalidates its callbacks and backlog.
        guard inputEnabled, !physicalHoldActive || remoteReleaseRequested else { return }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == (scope == .codex ? "com.openai.codex" : DouyinLiveDictation.bundleID) else { return }
        // 新一次按住不能把上次尚在等待的识别结果写进新上下文。
        stop(reason: nil, restoreImmediately: true)
        guard remoteIMEFinishing == nil else { return }
        activeScope = scope
        onPhysicalHoldPrepare?()
        guard useRemoteMicrophone else {
            physicalHoldActive = true
            physicalHoldStartedAt = ProcessInfo.processInfo.systemUptime
            toggle(scope: scope)
            return
        }
        guard AXIsProcessTrusted() else {
            notice("需要辅助功能权限，\(targetLabel)听写未开始。")
            return
        }
        guard focus(scope), let target = captureRemoteTarget(scope: scope) else {
            notice("请点一下要输入的位置，再按住说话。")
            return
        }
        if voiceEngine == .wechat {
            beginRemoteInputMethod(target: target)
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
            physicalHoldStartedAt = ProcessInfo.processInfo.systemUptime
            onPhysicalHoldState?(true)
            onStateChanged?(true)
            status("引擎开始 engine=system source=remote；松开语音键结束，文字不会自动发送。")
            remoteTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                Task { @MainActor in
                    guard let remoteSession else { return }
                    guard remoteTargetIsCurrent(remoteSession.target) else {
                        stop(reason: "应用、窗口或输入焦点改变", restoreImmediately: true, showError: false)
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
        status("松手请求 source=hid elapsed=\(holdElapsed())s samples=\(remotePCMSamples)")
        if useRemoteMicrophone, remoteIME != nil || remoteSession != nil {
            guard !remoteReleaseRequested else { return }
            remoteReleaseRequested = true
            if let onPhysicalHoldRelease {
                onPhysicalHoldRelease(remoteGeneration)
                return
            }
            endRemoteTransport(token: remoteGeneration, reason: "hid-no-service")
            return
        }
        finishPhysicalHold()
    }

    /// 必须在同一会话最后一个 PCM 的主队列交付之后调用。
    @MainActor private static func finishPhysicalHold() {
        guard physicalHoldActive else { return }
        physicalHoldActive = false
        remoteReleaseRequested = false
        onPhysicalHoldState?(false)
        if useRemoteMicrophone {
            status("音频交付结束 source=remote samples=\(remotePCMSamples) duration=\(String(format: "%.3f", Double(remotePCMSamples) / 16000))s")
        }
        if remoteIME != nil {
            stop(reason: nil, restoreImmediately: false)
            return
        }
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
        status("引擎结束 engine=system reason=release；正在等待最终识别结果，不会自动发送。")
        let token = remoteGeneration
        finalTimeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, remoteGeneration == token, remoteSession != nil else { return }
            stop(reason: "未及时取得最终识别结果，本次文字已丢弃", restoreImmediately: true)
        }
    }

    // MARK: - 微信输入法遥控器音频桥

    @MainActor private static func beginRemoteInputMethod(target: RemoteTarget) {
        let prefix = "com.tencent.inputmethod.wetype"
        let configured = target.scope == .codex ? triggerConfig : douyinTriggerConfig
        let cfg = VoiceTriggerConfig(keyName: configured.keyName, mode: .hold, imeBundlePrefix: prefix)
        guard configured.mode == .hold, VoiceTriggerConfig.keyTable[cfg.keyName] != nil else {
            notice("请将\(targetLabel)语音快捷键设为与微信输入法一致的“按住说话”键。")
            return
        }
        guard let source = enabledInputSource(prefix: prefix) else {
            notice("未找到已启用的微信输入法，请先在系统键盘设置中添加微信输入法。")
            return
        }
        guard let input = DefaultInput.findInputDevice(named: bridgeDeviceName),
              AudioBridge.listOutputDevices().contains(where: { $0.hasPrefix(bridgeDeviceName) }),
              let previousInput = DefaultInput.currentDefault() else {
            notice("未检测到可用的 \(bridgeDeviceName) 输入／输出设备，请确认 BlackHole 已安装并可用。")
            return
        }
        let switchesDevice = previousInput != input
        let previousSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        let switchesSource = previousSource.flatMap { sourceString($0, kTISPropertyBundleID) }?.hasPrefix(prefix) != true
        guard !switchesDevice || DefaultInput.setDefault(input) else {
            notice("无法将默认麦克风切换到 \(bridgeDeviceName)，微信听写未开始。")
            return
        }
        bridgePreviousInput = switchesDevice ? previousInput : nil
        bridgeInput = input
        savedInputSource = switchesSource ? previousSource : nil
        selectedInputPrefix = switchesSource ? prefix : nil
        guard !switchesSource || TISSelectInputSource(source) == noErr else {
            restoreBridgeInput()
            restoreIME()
            notice("无法切换到微信输入法，本次听写未开始。")
            return
        }
        remoteGeneration &+= 1
        let token = remoteGeneration
        remoteIMETransportToken = token
        // A hold during prewarming adopts the in-flight queue. The warmup's
        // identity check then leaves this session's queue alone.
        let sink = remoteIMEOutputWarmup ?? AudioBridge(deviceName: bridgeDeviceName, requiresNamedDevice: true)
        remoteIMEOutputWarmup = nil
        let inputMethodPID = NSRunningApplication.runningApplications(withBundleIdentifier: prefix).first?.processIdentifier
        remoteIME = RemoteInputMethodSession(target: target, config: cfg, sink: sink, inputMethodPID: inputMethodPID)
        remoteIMEStartup = RemotePCMStartupGate()
        physicalHoldActive = true
        physicalHoldStartedAt = ProcessInfo.processInfo.systemUptime
        // Long-press confirmation owns the audio now, independently of BlackHole's
        // cold startup. STOP may arrive before onReady and must keep this backlog.
        onPhysicalHoldState?(true)
        onStateChanged?(true)
        status("引擎准备 engine=wechat source=remote bridge=\(bridgeDeviceName) settle=\(switchesDevice || switchesSource ? 180 : 0)ms")
        remoteTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                guard token == remoteGeneration, let current = remoteIME else { return }
                monitorRemoteInputMethodContext(current.target)
            }
        }
        if let remoteTimer { RunLoop.main.add(remoteTimer, forMode: .common) }
        remoteIMEReadyTimeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, token == remoteGeneration,
                  remoteIME != nil, !remoteIMEStartup.isReady else { return }
            stop(reason: "微信音频桥启动超时，请重新按住语音键重试", restoreImmediately: true)
        }
        sink.streamStarted(sampleRate: 16_000) { ready in
            Task { @MainActor in
                guard token == remoteGeneration, physicalHoldActive, var current = remoteIME else { return }
                guard ready else {
                    stop(reason: "BlackHole 音频输出引擎启动失败", restoreImmediately: true)
                    return
                }
                current.outputReady = true
                remoteIME = current
                status("引擎准备阶段 engine=wechat stage=output elapsed=\(holdElapsed())s")
                completeRemoteInputMethodStartup(token: token)
            }
        }
        // Input-source settling and WeType capture do not depend on the output
        // queue. Run them alongside cold AudioQueue initialization, while the
        // existing PCM gate still waits for both readiness conditions.
        remoteIMEStartTask = Task { @MainActor in
            if switchesDevice || switchesSource {
                try? await Task.sleep(for: .milliseconds(180))
            }
            guard !Task.isCancelled, token == remoteGeneration, physicalHoldActive,
                  var current = remoteIME else { return }
            guard remoteTargetIsCurrent(current.target), currentInputSourceMatches(prefix: prefix),
                  DefaultInput.currentDefault() == input else {
                stop(reason: "输入框、输入法或音源改变，微信听写未开始", restoreImmediately: true)
                return
            }
            let captureBefore = current.inputMethodPID.map { InputCaptureState.read(pid: $0, device: input) } ?? .unknown
            current.captureWasStoppedBeforeStart = captureBefore == .stopped
            guard captureBefore != .running else {
                stop(reason: "微信输入法已在采集，请先在微信语音浮层暂停后重试", restoreImmediately: true)
                return
            }
            guard startHotkey(current.config) else {
                stop(reason: "无法发送微信输入法开始快捷键", restoreImmediately: true)
                return
            }
            current.keyDown = true
            remoteIME = current
            let captureStart = DispatchTime.now().uptimeNanoseconds
            var captureAfter = InputCaptureState.unknown
            while true {
                guard !Task.isCancelled, token == remoteGeneration, remoteIME != nil else { return }
                guard remoteTargetIsCurrent(current.target), currentInputSourceMatches(prefix: prefix),
                      DefaultInput.currentDefault() == input else {
                    stop(reason: "输入框、输入法或音源改变，微信听写未开始", restoreImmediately: true)
                    return
                }
                captureAfter = current.inputMethodPID.map { InputCaptureState.read(pid: $0, device: input) } ?? .unknown
                let wait = InputCaptureStartWait.decision(capture: captureAfter,
                    elapsedNs: DispatchTime.now().uptimeNanoseconds - captureStart)
                if wait != .wait { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            remoteIMEStartTask = nil
            guard var readySession = remoteIME else { return }
            readySession.captureReady = captureAfter
            remoteIME = readySession
            status("引擎准备阶段 engine=wechat stage=capture elapsed=\(holdElapsed())s capture=\(captureAfter.rawValue)")
            completeRemoteInputMethodStartup(token: token)
        }
    }

    @MainActor private static func completeRemoteInputMethodStartup(token: UInt64) {
        guard token == remoteGeneration, physicalHoldActive, let current = remoteIME,
              current.outputReady, let capture = current.captureReady, !remoteIMEStartup.isReady else { return }
        remoteIMEReadyTimeout?.cancel()
        remoteIMEReadyTimeout = nil
        let startup = remoteIMEStartup.markReady()
        deliverRemoteInputMethodPCM(startup.samples, token: token)
        guard token == remoteGeneration, remoteIME != nil else { return }
        status("引擎开始 engine=wechat source=remote trigger=\(current.config.keyName) hold capture=\(capture.rawValue)；未验证第三方识别结果")
        // PCM is enqueued before STOP, including a release during either startup.
        if startup.transportEnded { endRemoteTransport(token: token, reason: "startup-ready") }
    }

    @MainActor private static func endRemoteInputMethod(restoreImmediately: Bool) {
        remoteIMEStartTask?.cancel()
        remoteIMEStartTask = nil
        remoteIMEReadyTimeout?.cancel()
        remoteIMEReadyTimeout = nil
        bridgeRestoreTask?.cancel()
        bridgeRestoreTask = nil
        if restoreImmediately {
            remoteIMETransportToken = nil
            remoteIMEFinishingTimer?.invalidate()
            remoteIMEFinishingTimer = nil
            remoteIMEStopID = nil
            if let pending = remoteIMEFinishing {
                let released = releaseRemoteInputMethodKey(pending)
                pending.sink.cancelStream()
                remoteIMEFinishing = released ? nil : pending
                if released { status("引擎结束 engine=wechat reason=cancel；已发送原触发键释放") }
            }
        }
        guard let current = remoteIME else {
            if restoreImmediately { restoreBridgeInput() }
            return
        }
        remoteIME = nil
        if restoreImmediately || !current.keyDown {
            let released = releaseRemoteInputMethodKey(current)
            if !released { remoteIMEFinishing = current }
            current.sink.cancelStream()
            remoteIMETransportToken = nil
            restoreBridgeInput()
            status("引擎结束 engine=wechat reason=\(current.keyDown ? "cancel" : "released-before-ready")")
            return
        }
        // 传输结束标记已在最后一个 PCM 后到达；排空完整音频与静音尾后才松开触发键。
        remoteIMEFinishing = current
        let stopID = UUID()
        remoteIMEStopID = stopID
        remoteIMEFinishingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                guard remoteIMEStopID == stopID else { return }
                monitorRemoteInputMethodContext(current.target)
            }
        }
        if let remoteIMEFinishingTimer { RunLoop.main.add(remoteIMEFinishingTimer, forMode: .common) }
        status("收音结束 engine=wechat；正在排空已采集音频")
        current.sink.streamStopped {
            Task { @MainActor in
                guard remoteIMEStopID == stopID else { return }
                // 播放排空只证明 PCM 已送给 BlackHole；继续保留原触发键，让微信消费尾部。
                // 这不是第三方完成识别的确认；上下文监视器可随时取消这段有界等待。
                status("音频排空 engine=wechat；保留 500ms 触发键收尾窗口")
                try? await Task.sleep(for: .milliseconds(500))
                guard remoteIMEStopID == stopID, var pending = remoteIMEFinishing else { return }
                guard releaseRemoteInputMethodKey(pending) else {
                    restoreBridgeInput()
                    return
                }
                pending.keyDown = false
                remoteIMEFinishing = pending
                status("触发键释放 engine=wechat key=\(pending.config.keyName)；等待采集停止证据")
                // A keyUp can leave WeType in hands-free recording (observed in real
                // CoreAudio logs). Never blindly toggle: wait for normal shutdown,
                // then retry once only with positive evidence on this exact bridge.
                try? await Task.sleep(for: .milliseconds(350))
                guard remoteIMEStopID == stopID else { return }
                var recovery = InputCaptureStopRecovery()
                guard let capture = await waitForRemoteInputMethodStop(pending, stopID: stopID) else { return }
                let sameContext = remoteTargetHasFocus(pending.target)
                    && currentInputSourceMatches(prefix: "com.tencent.inputmethod.wetype")
                    && DefaultInput.currentDefault() == bridgeInput
                    && NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.inputmethod.wetype")
                        .contains(where: { $0.processIdentifier == pending.inputMethodPID })
                if pending.config.keyName == "fn",
                   recovery.shouldRetry(keyReleased: !pending.keyDown,
                                        captureStartedHere: pending.captureWasStoppedBeforeStart,
                                        contextMatches: sameContext, capture: capture) {
                    status("结束校验 engine=wechat capture=running；原上下文补发一次 Fn 暂停")
                    _ = tap(pending.config)
                    try? await Task.sleep(for: .milliseconds(350))
                    guard remoteIMEStopID == stopID else { return }
                }
                guard let stopped = await waitForRemoteInputMethodStop(pending, stopID: stopID) else { return }
                remoteIMEStopID = nil
                remoteIMEFinishingTimer?.invalidate()
                remoteIMEFinishingTimer = nil
                status("引擎收尾 engine=wechat reason=release capture=\(stopped.rawValue) recovery=\(recovery.attempted)；未自动发送")
                if stopped == .running {
                    notice("微信输入法仍在采集，请在微信语音浮层暂停；本次未自动发送。")
                }
                onStateChanged?(isActive)
                bridgeRestoreTask = Task { @MainActor in
                    // 输入法仍可能整理最终文字；这段时间不重新聚焦，焦点改变便提前收尾。
                    for _ in 0..<60 {
                        try? await Task.sleep(for: .milliseconds(50))
                        guard !Task.isCancelled else { return }
                        if !remoteTargetHasFocus(pending.target)
                            || !currentInputSourceMatches(prefix: "com.tencent.inputmethod.wetype")
                            || DefaultInput.currentDefault() != bridgeInput { break }
                    }
                    remoteIMEFinishingTimer?.invalidate()
                    remoteIMEFinishingTimer = nil
                    restoreBridgeInput()
                    restoreIME()
                    remoteIMETransportToken = nil
                    remoteIMEFinishing = nil
                    onStateChanged?(isActive)
                    bridgeRestoreTask = nil
                }
            }
        }
    }

    /// CoreAudio input-running can lag a released WeType hotkey while final text
    /// is committed. Give that positive evidence a bounded settling window before
    /// attempting the existing single recovery tap or reporting lingering capture.
    @MainActor private static func waitForRemoteInputMethodStop(_ pending: RemoteInputMethodSession,
                                                               stopID: UUID) async -> InputCaptureState? {
        for attempt in 0...20 {
            guard remoteIMEStopID == stopID else { return nil }
            let capture = pending.inputMethodPID.flatMap { pid in
                bridgeInput.map { InputCaptureState.read(pid: pid, device: $0) }
            } ?? .unknown
            guard capture == .running, attempt < 20 else { return capture }
            // The existing context monitor cancels the generation on a real
            // app/window/room/input change throughout this asynchronous wait.
            try? await Task.sleep(for: .milliseconds(100))
        }
        return .unknown
    }

    @MainActor private static func releaseRemoteInputMethodKey(_ current: RemoteInputMethodSession) -> Bool {
        guard current.keyDown else { return true }
        guard post(down: false, config: current.config) else {
            notice("无法发送微信输入法结束快捷键，请手动结束微信语音输入。")
            return false
        }
        return true
    }

    @MainActor private static func restoreBridgeInput() {
        // 用户在会话中主动更换音源时保留其选择。
        if let previous = bridgePreviousInput, let owned = bridgeInput,
           DefaultInput.currentDefault() == owned {
            _ = DefaultInput.setDefault(previous)
        }
        bridgePreviousInput = nil
        bridgeInput = nil
    }

    /// AppServices 在主线程按 ATVV 顺序投递；HID 松手后仍允许最后一批已采集尾帧。
    @MainActor static func receiveRemotePCM(_ samples: [Int16], token: UInt64) {
        guard token == remoteGeneration, physicalHoldActive else { return }
        if let current = remoteIME {
            // Workspace evidence is cheap and rejects an app switch before this
            // packet can be queued. AX/TIS/CoreAudio run only on the monitor.
            guard stillFrontmost(current.target.pid) else {
                cancelForRemoteContext("frontmost-application")
                return
            }
            switch remoteIMEStartup.receive(samples) {
            case .buffered:
                remotePCMSamples += samples.count
            case .deliver:
                remotePCMSamples += samples.count
                deliverRemoteInputMethodPCM(samples, token: token)
            case .overflow:
                stop(reason: "微信音频桥启动前缓存已满，请重新按住语音键重试", restoreImmediately: true)
            case .ended:
                break
            }
            return
        }
        if let current = remoteSession {
            remotePCMSamples += samples.count
            current.recognizer.append(samples)
        }
    }

    @MainActor static func endRemoteTransport(token: UInt64, reason: String = "transport") {
        guard token == remoteGeneration else { return }
        status("传输结束 source=\(reason) hidRelease=\(remoteReleaseRequested) elapsed=\(holdElapsed())s samples=\(remotePCMSamples)")
        if remoteIME != nil, !remoteIMEStartup.end() {
            status("音频已保留 engine=wechat；等待音频桥就绪后排空")
            return
        }
        if let current = remoteIME {
            if remoteContext.needsRefresh(now: ProcessInfo.processInfo.systemUptime) {
                monitorRemoteInputMethodContext(current.target)
                guard token == remoteGeneration, remoteIME != nil else { return }
            }
            switch remoteContext.decision(now: ProcessInfo.processInfo.systemUptime) {
            case .allow: break
            case .quarantine:
                remoteContextTransportEnded = true
                status("上下文复核 engine=wechat state=waiting-for-stop；尾部音频暂存，未送入音频桥")
                return
            case .cancel(let issue):
                cancelForRemoteContext(issue)
                return
            }
        }
        finishPhysicalHold()
    }

    /// Also used by cold startup when its backlog becomes ready. It never counts
    /// samples twice and never bypasses a pending context check.
    @MainActor static func deliverRemoteInputMethodPCM(_ samples: [Int16], token: UInt64) {
        guard token == remoteGeneration, let current = remoteIME else { return }
        guard stillFrontmost(current.target.pid) else {
            cancelForRemoteContext("frontmost-application")
            return
        }
        // A delayed main run loop must get a fresh observation before old
        // timestamps alone can cancel an otherwise valid recording.
        if remoteContext.needsRefresh(now: ProcessInfo.processInfo.systemUptime) {
            monitorRemoteInputMethodContext(current.target)
            guard token == remoteGeneration, remoteIME != nil else { return }
        }
        switch remoteContext.receive(samples, now: ProcessInfo.processInfo.systemUptime) {
        case .deliver(let verified): current.sink.write(verified)
        case .buffered: break
        case .cancel(let issue): cancelForRemoteContext(issue)
        }
    }

    @MainActor private static func monitorRemoteInputMethodContext(_ target: RemoteTarget) {
        let evidence = remoteInputMethodContext(target)
        let decision = remoteContext.observe(evidence, now: ProcessInfo.processInfo.systemUptime)
        switch decision {
        case .allow:
            if remoteContextQuarantined {
                status("上下文复核 engine=wechat state=recovered；原输入框已核实")
            }
            remoteContextQuarantined = false
            if remoteIMEStartup.isReady {
                deliverRemoteInputMethodPCM([], token: remoteGeneration)
                if remoteContextTransportEnded, remoteIME != nil {
                    remoteContextTransportEnded = false
                    finishPhysicalHold()
                }
            }
        case .quarantine:
            if !remoteContextQuarantined {
                if case .unavailable(let issue) = evidence {
                    status("上下文复核 engine=wechat state=quarantine issue=\(issue)；暂存音频")
                }
            }
            remoteContextQuarantined = true
        case .cancel(let issue): cancelForRemoteContext(issue)
        }
    }

    @MainActor private static func cancelForRemoteContext(_ issue: String) {
        status("上下文取消 engine=wechat issue=\(issue)")
        stop(reason: "输入上下文改变或持续无法核实（\(issue)）", restoreImmediately: true, showError: false)
    }

    @MainActor private static func remoteInputMethodContext(_ target: RemoteTarget) -> RemoteDictationContextGuard.Observation {
        let focus = remoteTargetFocus(target)
        let source: RemoteDictationContextGuard.Observation
        if let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let bundle = sourceString(current, kTISPropertyBundleID) {
            source = bundle.hasPrefix("com.tencent.inputmethod.wetype") ? .matched : .changed("input-source")
        } else { source = .unavailable("input-source") }
        let input: RemoteDictationContextGuard.Observation
        if let expected = bridgeInput, let current = DefaultInput.currentDefault() {
            input = current == expected ? .matched : .changed("default-input-device")
        } else { input = .unavailable("default-input-device") }
        return RemoteDictationContextGuard.combined([focus, source, input])
    }

    @MainActor private static func holdElapsed() -> String {
        guard let physicalHoldStartedAt else { return "unknown" }
        return String(format: "%.3f", ProcessInfo.processInfo.systemUptime - physicalHoldStartedAt)
    }

    @MainActor static func cancelRemoteTransport(token: UInt64) {
        // 正常松手隔离了 PCM 代次，BlackHole 排空／输入法整理期间仍须响应断连取消。
        guard token == remoteGeneration || token == remoteIMETransportToken else { return }
        stop(reason: "遥控器音频链路停止", restoreImmediately: true)
    }

    @MainActor static func reportPermissionResult(approved: Bool) {
        if approved { status("语音识别已获允许；请重新按住语音键说话。") }
        else { notice("未获得语音识别权限；可在系统设置 → 隐私与安全性 → 语音识别中开启。") }
    }

    @MainActor private static func receiveRecognition(text: String?, failure: String?, token: UInt64) {
        guard token == remoteGeneration, remotePasteTask == nil, var current = remoteSession else { return }
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
        guard let current = remoteSession, current.released, remotePasteTask == nil,
              pasteboardLease == nil else { return }
        let safeText = sanitizedText(text)
        guard !safeText.isEmpty, safeText.utf16.count <= 8_192 else {
            stop(reason: "没有识别到可安全插入的文字", restoreImmediately: true)
            return
        }
        guard remoteTargetIsCurrent(current.target), preparePasteboard(text: safeText) else {
            stop(reason: "原输入框已改变或无法完整保留剪贴板，本次未粘贴", restoreImmediately: true)
            return
        }
        // Once an action is attempted it is never retried: a delayed Electron
        // handler could otherwise consume both actions and duplicate the text.
        remoteTimer?.invalidate()
        remoteTimer = nil
        finalTimeout?.cancel()
        finalTimeout = nil
        guard insertRemoteText(target: current.target) else {
            stop(reason: "输入焦点或剪贴板已改变，本次未粘贴", restoreImmediately: true)
            return
        }
        let token = remoteGeneration
        remotePasteTask = Task { @MainActor in
            var evidence = InsertionEvidence.unconfirmed
            // Keep our clipboard alive until the app has consumed it, or until a
            // bounded timeout. Cancellation/shutdown restores it synchronously.
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled, remoteGeneration == token else { return }
                guard remoteTargetHasFocus(current.target) else {
                    evidence = .unconfirmed
                    break
                }
                evidence = insertionEvidence(text: safeText, target: current.target)
                if evidence == .textVerified { break }
            }
            guard !Task.isCancelled, remoteGeneration == token else { return }
            clearRemote()
            onStateChanged?(false)
            switch evidence {
            case .textVerified:
                status("已核实文字进入原输入框，尚未发送。")
            case .changeVerified:
                status("已核实原输入框的选区／字数按预期变化，但无法读取插入文字核对；尚未发送。")
            case .unconfirmed:
                notice("已尝试一次粘贴，但无法确认文字进入原输入框；未自动重试或发送，请检查输入框。")
            }
        }
    }

    @MainActor private static func clearRemote() {
        remoteGeneration &+= 1
        remotePasteTask?.cancel()
        remotePasteTask = nil
        restorePasteboard()
        let hadPhysicalSession = physicalHoldActive || remoteSession != nil
        physicalHoldActive = false
        physicalHoldStartedAt = nil
        remoteReleaseRequested = false
        remotePCMSamples = 0
        remoteIMEStartup = RemotePCMStartupGate()
        remoteContext = RemoteDictationContextGuard()
        remoteContextQuarantined = false
        remoteContextTransportEnded = false
        if hadPhysicalSession { onPhysicalHoldState?(false) }
        remoteSession?.recognizer.cancel()
        remoteSession = nil
        remoteTimer?.invalidate()
        remoteTimer = nil
        finalTimeout?.cancel()
        finalTimeout = nil
    }

    @MainActor private static func captureRemoteTarget(scope: TargetScope = .codex) -> RemoteTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == (scope == .codex ? "com.openai.codex" : DouyinLiveDictation.bundleID),
              let resolved = resolvedField(scope),
              systemFocusAllows(resolved),
              let appFocused = axElement(AXUIElementCreateApplication(app.processIdentifier), attribute: kAXFocusedUIElementAttribute),
              CFEqual(appFocused, resolved),
              let window = axElement(resolved, attribute: kAXWindowAttribute),
              let frontWindow = axElement(AXUIElementCreateApplication(app.processIdentifier), attribute: kAXFocusedWindowAttribute),
              CFEqual(window, frontWindow) else { return nil }
        let selection = selectedRange(resolved)
        if let selection, !validRange(selection) { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(resolved, &pid) == .success, pid == app.processIdentifier else { return nil }
        return RemoteTarget(scope: scope, contextID: scope == .douyinLive ? DouyinLiveDictation.contextID() : nil, pid: pid, element: resolved, window: window, selection: selection,
                            characterCount: characterCount(resolved))
    }

    @MainActor private static func remoteTargetHasFocus(_ target: RemoteTarget) -> Bool {
        remoteTargetFocus(target) == .matched
    }

    @MainActor private static func remoteTargetFocus(_ target: RemoteTarget) -> RemoteDictationContextGuard.Observation {
        guard stillFrontmost(target.pid) else { return .changed("frontmost-application") }
        let app = AXUIElementCreateApplication(target.pid)
        // Keep an unresponsive Electron AX server from blocking every queued PCM.
        AXUIElementSetMessagingTimeout(app, 0.04)
        func compare(_ element: AXUIElement, attribute: String, expected: AXUIElement,
                     issue: String, optional: Bool = false,
                     allowPlaceholder: Bool = false, allowIMEOverlay: Bool = false) -> RemoteDictationContextGuard.Observation {
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            if optional, result == .attributeUnsupported || result == .noValue { return .matched }
            guard result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return .unavailable("\(issue):\(result.rawValue)")
            }
            let actual = value as! AXUIElement
            if CFEqual(actual, expected) { return .matched }
            if allowPlaceholder {
                let role = axString(actual, attribute: kAXRoleAttribute)
                let sameWindow = CFEqual(actual, target.window)
                    || axElement(actual, attribute: kAXWindowAttribute).map { CFEqual($0, target.window) } == true
                if RemoteDictationContextGuard.isTransientWindowPlaceholder(role: role, originalWindowMatches: sameWindow) {
                    return .unavailable("\(issue):original-window-placeholder")
                }
            }
            if allowIMEOverlay, let expectedPID = remoteIME?.inputMethodPID ?? remoteIMEFinishing?.inputMethodPID {
                var actualPID: pid_t = 0
                if AXUIElementGetPid(actual, &actualPID) == .success, actualPID == expectedPID,
                   NSRunningApplication(processIdentifier: actualPID)?.bundleIdentifier == "com.tencent.inputmethod.wetype" {
                    return .unavailable("\(issue):input-method-overlay")
                }
            }
            return .changed(issue)
        }
        let resolved: RemoteDictationContextGuard.Observation
        if target.scope == .douyinLive {
            resolved = DouyinLiveDictation.targetObservation(target.element, window: target.window, contextID: target.contextID)
        } else if let element = CodexConversationControls.resolvedDictationField() {
            resolved = CFEqual(element, target.element) ? .matched : .changed("resolved-input-field")
        } else { resolved = .unavailable("resolved-input-field") }
        let system = AXUIElementCreateSystemWide()
        // A timeout on the system-wide element would change this process's
        // global AX timeout, so only the private app handle is configured above.
        // Read independent witnesses even if one is unavailable: a real mismatch
        // must cancel immediately rather than enter a grace period.
        let window = compare(app, attribute: kAXFocusedWindowAttribute, expected: target.window, issue: "app-focused-window")
        let focus = compare(app, attribute: kAXFocusedUIElementAttribute, expected: target.element,
                            issue: "app-focused-element", allowPlaceholder: true)
        let originalWindowIsCurrent = window == .matched
        return RemoteDictationContextGuard.combined([
            resolved, focus, window,
            compare(target.element, attribute: kAXWindowAttribute, expected: target.window, issue: "target-window"),
            compare(system, attribute: kAXFocusedUIElementAttribute, expected: target.element,
                    issue: "system-focused-element", optional: true, allowPlaceholder: originalWindowIsCurrent,
                    allowIMEOverlay: originalWindowIsCurrent)
        ])
    }

    @MainActor private static func remoteTargetIsCurrent(_ target: RemoteTarget) -> Bool {
        guard remoteTargetHasFocus(target) else { return false }
        if let expected = target.selection {
            guard let range = selectedRange(target.element), range.location == expected.location,
                  range.length == expected.length else { return false }
        }
        // A same-position edit is still a changed context whenever AX exposes a count.
        if let expected = target.characterCount { return characterCount(target.element) == expected }
        return true
    }

    static func sanitizedText(_ text: String) -> String {
        text.components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func snapshotPasteboard(_ board: NSPasteboard) -> PasteboardSnapshot? {
        let count = board.changeCount
        let sourceItems = board.pasteboardItems ?? []
        guard !sourceItems.isEmpty || (board.types ?? []).isEmpty else { return nil }
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        for source in sourceItems {
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in source.types {
                guard let data = source.data(forType: type) else { return nil }
                representations[type] = data
            }
            guard !representations.isEmpty else { return nil }
            items.append(representations)
        }
        guard board.changeCount == count else { return nil }
        return PasteboardSnapshot(items: items, changeCount: count)
    }

    @MainActor private static func preparePasteboard(text: String) -> Bool {
        let board = NSPasteboard.general
        guard let snapshot = snapshotPasteboard(board), board.changeCount == snapshot.changeCount else { return false }
        let marker = Data(UUID().uuidString.utf8)
        // declareTypes returns our exact ownership count. setData does not declare
        // new types, so a concurrent copy cannot be adopted as our own generation.
        let ownedCount = board.declareTypes([.string, pasteboardMarker], owner: nil)
        let lease = PasteboardLease(snapshot: snapshot, changeCount: ownedCount, marker: marker)
        pasteboardLease = lease
        guard board.changeCount == ownedCount, board.setData(marker, forType: pasteboardMarker) else {
            // A failed initial marker write still owns the declared generation.
            _ = restoreContents(board, lease: lease, requireMarker: false)
            pasteboardLease = nil
            return false
        }
        guard board.changeCount == ownedCount, board.setString(text, forType: .string), ownsPasteboard() else {
            restorePasteboard()
            return false
        }
        return true
    }

    private static func ownsPasteboard(_ board: NSPasteboard, lease: PasteboardLease) -> Bool {
        pasteboardCanRestore(expected: lease.changeCount, actual: board.changeCount,
                             expectedMarker: lease.marker, actualMarker: board.data(forType: pasteboardMarker))
    }

    @MainActor private static func ownsPasteboard() -> Bool {
        guard let lease = pasteboardLease else { return false }
        return ownsPasteboard(NSPasteboard.general, lease: lease)
    }

    static func pasteboardCanRestore(expected: Int, actual: Int, expectedMarker: Data, actualMarker: Data?) -> Bool {
        expected == actual && actualMarker == expectedMarker
    }

    private static func restoreContents(_ board: NSPasteboard, lease: PasteboardLease, requireMarker: Bool = true) -> Bool {
        let items = lease.snapshot.items.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        // Do the ownership check after preparing all items, immediately before
        // mutation. A newer copy (including one with the same text) always wins.
        guard board.changeCount == lease.changeCount,
              !requireMarker || ownsPasteboard(board, lease: lease) else { return false }
        let clearedCount = board.clearContents()
        guard board.changeCount == clearedCount else { return false }
        return items.isEmpty || board.writeObjects(items)
    }

    @MainActor private static func restorePasteboard() {
        guard let lease = pasteboardLease else { return }
        pasteboardLease = nil
        _ = restoreContents(NSPasteboard.general, lease: lease)
    }

    /// Uses an isolated named board only; never touches the user's general board.
    static func pasteboardSelfCheck() -> Bool {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let binaryType = NSPasteboard.PasteboardType("com.miremote.self-check-binary")
        let first = NSPasteboardItem()
        let second = NSPasteboardItem()
        guard first.setString("fixture", forType: .string),
              first.setData(Data([0, 255, 1, 128]), forType: binaryType),
              second.setData(Data([4, 3, 2, 1]), forType: .tiff),
              board.writeObjects([first, second]), let snapshot = snapshotPasteboard(board) else { return false }
        let marker = Data("test-lease".utf8)
        let count = board.declareTypes([.string, pasteboardMarker], owner: nil)
        let lease = PasteboardLease(snapshot: snapshot, changeCount: count, marker: marker)
        guard board.setData(marker, forType: pasteboardMarker), board.setString("insert", forType: .string),
              board.changeCount == count, ownsPasteboard(board, lease: lease),
              restoreContents(board, lease: lease), let restored = snapshotPasteboard(board),
              restored.items == snapshot.items else { return false }
        let foreignCount = board.declareTypes([.string], owner: nil)
        guard board.setString("newer copy", forType: .string),
              !restoreContents(board, lease: lease), board.changeCount == foreignCount,
              board.string(forType: .string) == "newer copy" else { return false }
        // Even a retained marker must not permit restoring across generations.
        let newerCount = board.declareTypes([.string, pasteboardMarker], owner: nil)
        guard board.setData(marker, forType: pasteboardMarker), board.setString("newer copy", forType: .string),
              !restoreContents(board, lease: lease), board.changeCount == newerCount,
              board.string(forType: .string) == "newer copy" else { return false }
        // Empty clipboard restoration and rollback after a failed marker write.
        _ = board.clearContents()
        guard let empty = snapshotPasteboard(board), empty.items.isEmpty else { return false }
        let rollbackCount = board.declareTypes([pasteboardMarker], owner: nil)
        let rollback = PasteboardLease(snapshot: empty, changeCount: rollbackCount, marker: marker)
        return restoreContents(board, lease: rollback, requireMarker: false)
            && (board.types ?? []).isEmpty
    }

    /// Returns true after ONE attempt, never a claim that text was inserted.
    @MainActor private static func insertRemoteText(target: RemoteTarget) -> Bool {
        guard remoteTargetIsCurrent(target), ownsPasteboard() else { return false }
        if let item = pasteMenuItem(in: AXUIElementCreateApplication(target.pid)) {
            guard remoteTargetIsCurrent(target), ownsPasteboard() else { return false }
            _ = AXUIElementPerformAction(item, kAXPressAction as CFString)
            return true // Even an AX error may follow delivery; never retry it.
        }
        guard CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty,
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false),
              remoteTargetIsCurrent(target), ownsPasteboard() else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func pasteMenuItem(in app: AXUIElement) -> AXUIElement? {
        guard let bar = axElement(app, attribute: kAXMenuBarAttribute) else { return nil }
        let editTitles: Set<String> = ["edit", "编辑", "編輯"]
        let pasteTitles: Set<String> = ["paste", "粘贴", "粘貼", "貼上"]
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        guard let children = axChildren(bar), let edit = children.first(where: {
            guard let title = axString($0, attribute: kAXTitleAttribute) else { return false }
            return editTitles.contains(title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }) else { return nil }
        var queue: [(AXUIElement, Int)] = [(edit, 0)]
        var cursor = 0
        while cursor < queue.count, cursor < 90, ProcessInfo.processInfo.systemUptime < deadline {
            let (element, depth) = queue[cursor]
            cursor += 1
            if let title = axString(element, attribute: kAXTitleAttribute),
               pasteTitles.contains(title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
               axBool(element, attribute: kAXEnabledAttribute) == true { return element }
            if depth < 3, let children = axChildren(element) {
                queue.append(contentsOf: children.prefix(90).map { ($0, depth + 1) })
            }
        }
        return nil
    }

    private static func insertionEvidence(text: String, target: RemoteTarget) -> InsertionEvidence {
        let units = text.utf16.count
        let selection = selectedRange(target.element)
        let newCount = characterCount(target.element)
        let changed: Bool
        let range: CFRange?
        if let original = target.selection {
            changed = insertionChangeMatches(original: original, insertedUTF16Count: units,
                                              selection: selection, originalCount: target.characterCount, currentCount: newCount)
            range = CFRange(location: original.location, length: units)
        } else {
            // Missing AXSelectedTextRange must not prevent ordinary Electron paste.
            // Without an original range, only an exact count increase can provide
            // independent evidence; a newly available caret can then locate text.
            if let before = target.characterCount, let after = newCount, before <= Int.max - units {
                changed = after == before + units
            } else { changed = false }
            if let selection, selection.length == 0, selection.location >= units {
                range = CFRange(location: selection.location - units, length: units)
            } else { range = nil }
        }
        guard let range, validRange(range) else { return changed ? .changeVerified : .unconfirmed }
        // Never read AXValue or the whole composer. This request covers only the
        // exact range that this single paste was meant to insert.
        var requestedRange = range
        guard let parameter = AXValueCreate(.cfRange, &requestedRange) else { return .unconfirmed }
        var value: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(target.element, kAXStringForRangeParameterizedAttribute as CFString,
                                                                parameter, &value)
        if result == .success, let inserted = value as? String {
            return changed && inserted == text ? .textVerified : .unconfirmed
        }
        return changed ? .changeVerified : .unconfirmed
    }

    private static func systemFocusAllows(_ target: AXUIElement) -> Bool {
        // Some Electron builds omit the system-wide focused attribute. An actual
        // different focused element is never ignored; app/window checks remain mandatory.
        guard let focused = axElement(AXUIElementCreateSystemWide(), attribute: kAXFocusedUIElementAttribute) else { return true }
        return CFEqual(focused, target)
    }

    static func insertionChangeMatches(original: CFRange, insertedUTF16Count: Int, selection: CFRange?,
                                       originalCount: Int?, currentCount: Int?) -> Bool {
        guard validRange(original), insertedUTF16Count > 0,
              original.location <= Int.max - insertedUTF16Count else { return false }
        let selectionMatches = selection.map {
            $0.location == original.location + insertedUTF16Count && $0.length == 0
        } ?? false
        let countMatches: Bool
        if let old = originalCount, let new = currentCount, old >= original.length,
           old - original.length <= Int.max - insertedUTF16Count {
            countMatches = new == old - original.length + insertedUTF16Count
                && new != old
            // Any available contradictory count rejects otherwise plausible caret movement.
            if new != old - original.length + insertedUTF16Count { return false }
        } else { countMatches = false }
        return selectionMatches || countMatches
    }

    private static func validRange(_ range: CFRange) -> Bool {
        range.location >= 0 && range.length >= 0 && range.location <= Int.max - range.length
    }

    private static func characterCount(_ element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &value) == .success,
              let count = value as? NSNumber, count.intValue >= 0 else { return nil }
        return count.intValue
    }

    private static func axString(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func axBool(_ element: AXUIElement, attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue(value as! CFBoolean)
    }

    private static func axChildren(_ element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
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
        Task { @MainActor in stop(reason: reason, restoreImmediately: true, showError: false) }
    }

    @MainActor static func cancelCurrent(reason: String) {
        stop(reason: reason, restoreImmediately: true, showError: false)
    }

    /// 生命周期主线程可同步清理，防止退出前 Task 尚未运行。
    @MainActor static func shutdown() { stop(reason: "服务停止", restoreImmediately: true, showError: false) }

    @MainActor private static func toggle(scope: TargetScope = .codex) {
        if (preparing || session != nil || remoteIME != nil || remoteSession != nil), activeScope == scope {
            stop(reason: nil, restoreImmediately: false)
            return
        }
        if preparing || session != nil || remoteIME != nil || remoteSession != nil || remoteIMEFinishing != nil {
            stop(reason: nil, restoreImmediately: true, showError: false)
        }
        guard remoteIMEFinishing == nil else { return }
        activeScope = scope
        guard let app = NSWorkspace.shared.frontmostApplication,
              scope == .codex ? CodexNavigation.isAllowedBundle(app.bundleIdentifier) : app.bundleIdentifier == DouyinLiveDictation.bundleID else {
            notice("请先将\(targetLabel)切到前台，再使用听写。")
            return
        }
        guard AXIsProcessTrusted() else {
            notice("需要辅助功能权限，\(targetLabel)听写未开始。")
            return
        }
        guard focus(scope), stillFrontmost(app.processIdentifier) else {
            notice("无法确认\(targetLabel)当前可编辑的输入框，本次未开始听写。")
            return
        }
        let lockedTarget = scope == .douyinLive ? captureRemoteTarget(scope: scope) : nil
        guard scope != .douyinLive || lockedTarget != nil else {
            notice("无法锁存抖音直播聊天输入框，本次未开始听写。")
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
        let cfg = scope == .codex ? triggerConfig : douyinTriggerConfig
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
                      (lockedTarget.map { remoteTargetHasFocus($0) } ?? focus(scope)),
                      stillFrontmost(app.processIdentifier) else {
                    stop(reason: "输入框、输入法或音源已改变，听写未开始", restoreImmediately: true)
                    return
                }
                guard startHotkey(cfg) else {
                    stop(reason: "无法发送听写快捷键，听写未开始", restoreImmediately: true)
                    return
                }
                preparing = false
                session = Session(pid: app.processIdentifier, target: lockedTarget, inputDevice: input.id, route: .inputMethod(cfg))
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
            notice("\(reason)，\(targetLabel)也未提供可用的“开始听写”菜单。请启用微信语音输入并匹配按住快捷键，或在系统键盘设置中启用听写；本次未开始。")
            return
        }
        session = Session(pid: app.processIdentifier, target: lockedTarget, inputDevice: input.id, route: .system(axApp))
        didStart(inputName: input.name, method: "系统开始听写已请求")
    }

    @MainActor private static func didStart(inputName: String, method: String) {
        onStateChanged?(true)
        status("引擎开始 source=mac · \(method) · 音源：\(inputName)；不会发送消息。")
        contextTimer?.invalidate()
        contextTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            Task { @MainActor in
                guard let session else { return }
                guard stillFrontmost(session.pid), currentUsableInput()?.id == session.inputDevice else {
                    stop(reason: "应用或默认麦克风已改变", restoreImmediately: true)
                    return
                }
                if let target = session.target, !remoteTargetHasFocus(target) {
                    stop(reason: "直播间、窗口或输入焦点改变", restoreImmediately: true, showError: false)
                    return
                }
                if case .inputMethod(let config) = session.route,
                   let prefix = config.imeBundlePrefix, !currentInputSourceMatches(prefix: prefix) {
                    stop(reason: "语音输入法已改变", restoreImmediately: true)
                }
            }
        }
    }

    @MainActor private static func stop(reason: String?, restoreImmediately: Bool, showError: Bool = true) {
        let hadRemote = remoteSession != nil
        let hadRemoteIME = remoteIME != nil
        endRemoteInputMethod(restoreImmediately: restoreImmediately)
        let hadPhysical = physicalHoldActive
        clearRemote()
        if hadRemote || hadRemoteIME, let reason {
            if showError { notice("\(reason)；没有发送消息。") }
            else { status("\(reason)；没有发送消息。") }
        }
        if hadRemote || hadRemoteIME || hadPhysical { onStateChanged?(isActive) }
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
        else if savedInputSource != nil, !hadRemoteIME {
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
            if showError { notice("\(reason)，已请求结束听写；没有发送消息。") }
            else { status("\(reason)，已请求结束听写；没有发送消息。") }
        } else {
            status(wasPreparing ? "已取消听写开始；没有发送消息。" : "引擎结束 source=mac；已发送结束听写动作，没有发送消息。")
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
        status("错误：\(message)")
        onNotice?(message)
    }

    /// 常规状态仅日志；内容来自固定状态字符串，不包含音频／听写正文。
    @MainActor private static func status(_ message: String) {
        Logger(subsystem: "com.miremote.controller", category: "RemoteSpeech").notice("\(message, privacy: .public)")
        log("\(activeScope == .codex ? "Codex" : "抖音直播") 听写：\(message)")
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
            && RemotePCMStartupGate.selfCheck()
            && InputCaptureStartWait.selfCheck()
            && InputCaptureStopRecovery.selfCheck()
            && RemoteDictationContextGuard.selfCheck()
            && sanitizedText("hello\r\nworld\t\u{1B}") == "hello  world"
            && insertionChangeMatches(original: CFRange(location: 2, length: 0), insertedUTF16Count: 6,
                                      selection: CFRange(location: 8, length: 0), originalCount: 10, currentCount: 16)
            && !insertionChangeMatches(original: CFRange(location: 2, length: 0), insertedUTF16Count: 6,
                                       selection: CFRange(location: 8, length: 0), originalCount: 10, currentCount: 10)
            && insertionChangeMatches(original: CFRange(location: 2, length: 6), insertedUTF16Count: 6,
                                      selection: CFRange(location: 8, length: 0), originalCount: 10, currentCount: 10)
            && !insertionChangeMatches(original: CFRange(location: 2, length: 0), insertedUTF16Count: 6,
                                       selection: CFRange(location: 2, length: 0), originalCount: 10, currentCount: 10)
            && !pasteboardCanRestore(expected: 2, actual: 3, expectedMarker: Data([1]), actualMarker: Data([1]))
            && !pasteboardCanRestore(expected: 2, actual: 2, expectedMarker: Data([1]), actualMarker: Data([2]))
            && menuTitleMatches("Start Dictation…", stopping: false)
            && menuTitleMatches("开始听写...", stopping: false)
            && menuTitleMatches("停止聽寫", stopping: true)
            && !menuTitleMatches("Start Dictation", stopping: true)
            && !menuTitleMatches("Send", stopping: true)
            && !menuTitleMatches("Stop", stopping: true)
            && !menuTitleMatches("Start Dictation and Send", stopping: false)
    }
}
