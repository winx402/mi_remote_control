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
    @MainActor private static var remotePasteTask: Task<Void, Never>?
    @MainActor private static var pasteboardLease: PasteboardLease?

    private struct RemoteTarget {
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
                notice("已核实文字进入 Codex 原输入框，尚未发送。")
            case .changeVerified:
                notice("已核实原输入框的选区／字数按预期变化，但无法读取插入文字核对；尚未发送，请检查内容。")
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
        if hadPhysicalSession { onPhysicalHoldState?(false) }
        remoteSession?.recognizer.cancel()
        remoteSession = nil
        remoteTimer?.invalidate()
        remoteTimer = nil
        finalTimeout?.cancel()
        finalTimeout = nil
    }

    @MainActor private static func captureRemoteTarget() -> RemoteTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.openai.codex",
              let resolved = CodexConversationControls.resolvedDictationField(),
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
        return RemoteTarget(pid: pid, element: resolved, window: window, selection: selection,
                            characterCount: characterCount(resolved))
    }

    @MainActor private static func remoteTargetHasFocus(_ target: RemoteTarget) -> Bool {
        guard stillFrontmost(target.pid),
              let resolved = CodexConversationControls.resolvedDictationField(), CFEqual(resolved, target.element),
              systemFocusAllows(target.element),
              let focused = axElement(AXUIElementCreateApplication(target.pid), attribute: kAXFocusedUIElementAttribute),
              CFEqual(focused, target.element),
              let window = axElement(focused, attribute: kAXWindowAttribute), CFEqual(window, target.window),
              let frontWindow = axElement(AXUIElementCreateApplication(target.pid), attribute: kAXFocusedWindowAttribute),
              CFEqual(frontWindow, target.window) else { return false }
        return true
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
