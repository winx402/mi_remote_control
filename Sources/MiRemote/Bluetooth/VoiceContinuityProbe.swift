import Foundation

/// Queue-confined, bounded ATVV experiment. Effects are interpreted by ATVVBridge;
/// this type cannot write Bluetooth, play audio, invoke an input method, or persist audio.
final class VoiceContinuityProbe {
    struct Statistics: Sendable {
        fileprivate(set) var notifications = 0
        fileprivate(set) var bytes = 0
        fileprivate(set) var lateNotifications = 0
        fileprivate(set) var lateBytes = 0
        fileprivate(set) var lateFrames = 0
        fileprivate(set) var validPCMFrames = 0
        fileprivate(set) var pcmSamples = 0
        fileprivate(set) var pcmPeak = 0
        fileprivate(set) var energeticFrames = 0
        fileprivate var squareSum = 0.0
        fileprivate var firstRawNs: UInt64?
        fileprivate var lastRawNs: UInt64?
        fileprivate var firstEnergyNs: UInt64?
        fileprivate var lastEnergyNs: UInt64?

        var pcmSeconds: Double { Double(pcmSamples) / 16_000 }
        var rms: Double { pcmSamples == 0 ? 0 : sqrt(squareSum / Double(pcmSamples)) }
        var signalSpanSeconds: Double {
            guard let firstEnergyNs, let lastEnergyNs else { return 0 }
            return Double(lastEnergyNs - firstEnergyNs) / 1_000_000_000
        }
        /// Conservative signal evidence, not recognition or a long-duration guarantee.
        var hasSustainedSignal: Bool {
            guard let firstRawNs, let lastRawNs else { return false }
            return pcmSamples >= 16_000 && energeticFrames >= 10 &&
                lastRawNs - firstRawNs >= 1_000_000_000 && signalSpanSeconds >= 1
        }

        var summary: String {
            "raw \(notifications)包/\(bytes)B；1秒后 \(lateNotifications)包/\(lateBytes)B、" +
            "组帧\(lateFrames)、有效PCM \(validPCMFrames)帧；" +
            String(format: "PCM %.2fs、峰值%d、RMS %.1f、非静音跨度%.2fs",
                   pcmSeconds, pcmPeak, rms, signalSpanSeconds)
        }
    }

    struct Report: Sendable {
        enum Outcome: String, Sendable {
            case signalAfterRelease, signalAfterHostOpen, noSignal, inconclusive
            case notReady, busy, timedOut, cancelled, disconnected, interrupted
        }
        let outcome: Outcome
        let phaseA: Statistics
        let phaseB: Statistics
        let baselinePCMFrames: Int
        let hostOpenAttempted: Bool
        let detail: String

        /// Confirms only sustained non-silent PCM in this bounded experiment.
        /// It does not certify speech content, long recording, toggle UX, or WeType.
        var isSupportConfirmed: Bool {
            outcome == .signalAfterRelease || outcome == .signalAfterHostOpen
        }
        var summary: String {
            let result: String
            switch outcome {
            case .signalAfterRelease: result = "A：本次检测到松手后的持续非静音PCM"
            case .signalAfterHostOpen: result = "B：本次检测到主动开麦后的持续非静音PCM"
            case .noSignal: result = "本次未检测到松手后的持续声音"
            case .inconclusive: result = "证据不足，不能确认持续收音"
            case .notReady: result = "遥控器语音链路未就绪，未发送诊断命令"
            case .busy: result = "当前语音或诊断会话忙，未开始新诊断"
            case .timedOut: result = "等待实体按键或松键超时"
            case .cancelled: result = "诊断已取消"
            case .disconnected: result = "诊断因蓝牙断连结束"
            case .interrupted: result = "诊断被新按键或异常控制事件打断"
            }
            let b = hostOpenAttempted ? "\nB：\(phaseB.summary)" : "\nB：未执行"
            return "\(result)。\(detail)\nA：\(phaseA.summary)\(b)\n" +
                "仅验证本次短窗口的帧与能量；未保存、播放或识别音频，未验收长期收音或微信输入法。"
        }

        static func unavailable(_ outcome: Outcome, _ detail: String) -> Report {
            Report(outcome: outcome, phaseA: Statistics(), phaseB: Statistics(),
                   baselinePCMFrames: 0, hostOpenAttempted: false, detail: detail)
        }
    }

    enum Effect {
        case update(String)
        case openMicrophone
        case closeMicrophone
        case finished(Report)
    }
    private enum Phase { case armed, physical, afterRelease, closingPhysical, host, finished }
    private var phase: Phase = .armed
    private var phaseStartNs: UInt64
    private var deadlineNs: UInt64
    private let frameSize: Int
    private let supportsPlainSync: Bool
    private let decoder = ADPCMDecoder()
    private var synchronized = false
    private var framingUnknown = false
    private var partial = Data()
    private var partialStartNs: UInt64?
    private var baselinePCMFrames = 0
    private var phaseA = Statistics()
    private var phaseB = Statistics()
    private var hostOpenAttempted = false
    private var hostStarted = false
    private var requestedPhysicalOpen = false
    private var decodeNote = "尚未收到可验证的同步PCM"

    var isFinished: Bool { phase == .finished }

    init(version: UInt16, frameSize: Int, nowNs: UInt64) {
        self.frameSize = frameSize
        supportsPlainSync = version >= 0x0100 && frameSize == 120
        phaseStartNs = nowNs
        deadlineNs = nowNs + 15_000_000_000
    }

    func advance(nowNs: UInt64) -> [Effect] {
        guard phase != .finished, nowNs >= deadlineNs else { return [] }
        switch phase {
        case .armed:
            return finish(.timedOut, "15秒内未观察到实体语音流。")
        case .physical:
            return finish(.timedOut, "实体语音流开始15秒后仍未观察到松键；请松开语音键。")
        case .afterRelease:
            if baselinePCMFrames > 0 && phaseA.hasSustainedSignal {
                return finish(.signalAfterRelease, "A窗口6秒；已排除最初1秒。")
            }
            phase = .closingPhysical
            phaseStartNs = nowNs
            deadlineNs = nowNs + 300_000_000
            resetDecode()
            return [.closeMicrophone,
                    .update("A未检测到持续有效声音。关闭旧流后，仅主动开麦一次观察5秒；请保持语音键松开并说话。")]
        case .closingPhysical:
            phase = .host
            phaseStartNs = nowNs
            deadlineNs = nowNs + 5_000_000_000
            hostOpenAttempted = true
            hostStarted = false
            resetDecode()
            return [.openMicrophone]
        case .host:
            if baselinePCMFrames > 0 && hostStarted && phaseB.hasSustainedSignal {
                return finish(.signalAfterHostOpen, "B窗口5秒；已排除主动开麦后的最初1秒。")
            }
            let hasUnverifiedData = phaseA.lateBytes > 0 || phaseB.lateBytes > 0
            return finish(hasUnverifiedData || baselinePCMFrames == 0 ? .inconclusive : .noSignal,
                          "\(decodeNote)。开麦写入或STREAM_START不作为声音证据。")
        case .finished: return []
        }
    }

    func physicalRequest(nowNs: UInt64) -> [Effect] {
        if phase == .afterRelease || phase == .closingPhysical || phase == .host {
            return finish(.interrupted, "观察窗口内再次收到实体开麦请求，本次不判定支持。")
        }
        let effects = advance(nowNs: nowNs)
        guard effects.isEmpty, phase != .finished else { return effects }
        switch phase {
        case .armed:
            guard !requestedPhysicalOpen else { return [] }
            requestedPhysicalOpen = true
            return [.openMicrophone]
        case .physical: return []
        default: return finish(.interrupted, "观察窗口内再次收到实体开麦请求，本次不判定支持。")
        }
    }

    func streamStarted(nowNs: UInt64) -> [Effect] {
        if phase == .physical || phase == .afterRelease || phase == .closingPhysical {
            return finish(.interrupted, "出现意外的新语音流，本次不判定支持。")
        }
        let effects = advance(nowNs: nowNs)
        guard effects.isEmpty, phase != .finished else { return effects }
        switch phase {
        case .armed:
            phase = .physical
            phaseStartNs = nowNs
            deadlineNs = nowNs + 15_000_000_000
            resetDecode()
            return [.update("已观察到实体语音流。请短说一句后松开语音键；松手1秒后再继续说话约5秒。")]
        case .host:
            guard !hostStarted else { return finish(.interrupted, "B出现重复STREAM_START，流代际不明确。") }
            hostStarted = true
            resetDecode()
            return []
        default: return finish(.interrupted, "出现意外的新语音流，本次不判定支持。")
        }
    }

    func streamStopped(nowNs: UInt64) -> [Effect] {
        let effects = advance(nowNs: nowNs)
        guard effects.isEmpty, phase != .finished else { return effects }
        if phase == .physical {
            phase = .afterRelease
            phaseStartNs = nowNs
            deadlineNs = nowNs + 6_000_000_000
            // Keep only this decoder's state for A; the production stream has ended.
            return [.update("A：已观察到松键，暂不发MIC_CLOSE，观察6秒。请在松手1秒后说话。")]
        }
        // CLOSE may itself produce STOP. Never respond with another CLOSE here.
        return []
    }

    func sync(predictor: Int16, stepIndex: Int) {
        guard phase == .physical || phase == .afterRelease || (phase == .host && hostStarted) else { return }
        partial.removeAll(keepingCapacity: false)
        partialStartNs = nil
        guard supportsPlainSync, (0...88).contains(stepIndex), !framingUnknown else {
            synchronized = false
            decodeNote = "同步或帧格式无法验证，有效PCM未知"
            return
        }
        decoder.reset(predictor: predictor, stepIndex: stepIndex)
        synchronized = true
        decodeNote = "已使用合法AUDIO_SYNC解码v1.0裸120字节帧"
    }

    func audio(_ data: Data, nowNs: UInt64) -> [Effect] {
        let effects = advance(nowNs: nowNs)
        guard effects.isEmpty, !data.isEmpty,
              phase == .physical || phase == .afterRelease || phase == .host else { return effects }
        let eligible = phase != .physical && nowNs >= phaseStartNs + 1_000_000_000
        if phase == .afterRelease {
            observeRaw(&phaseA, data: data, eligible: eligible, nowNs: nowNs)
        } else if phase == .host {
            observeRaw(&phaseB, data: data, eligible: eligible, nowNs: nowNs)
        }
        // Only exact 120-byte v1 notifications plus a valid sync qualify as PCM.
        // Reassembling arbitrary BLE fragments cannot by itself disambiguate the
        // repository's unverified 6-byte-header layout, so those remain raw evidence.
        if !supportsPlainSync || data.count != frameSize {
            framingUnknown = true
            synchronized = false
            decodeNote = "不是可验证的v1裸120字节通知布局；仅统计raw，有效PCM未知"
        }
        guard data.count <= 4096 else { return [] }
        guard frameSize > 0, frameSize <= 4096 else { return [] }
        var offset = data.startIndex
        while offset < data.endIndex {
            if partial.isEmpty { partialStartNs = nowNs }
            let size = min(frameSize - partial.count, data.distance(from: offset, to: data.endIndex))
            let end = data.index(offset, offsetBy: size)
            partial.append(data[offset..<end])
            offset = end
            guard partial.count == frameSize else { continue }
            let whollyLate = eligible && (partialStartNs ?? 0) >= phaseStartNs + 1_000_000_000
            let canDecode = synchronized && (phase != .host || hostStarted)
            // PCM exists only in this call, then is discarded. Decode the excluded
            // first second too, to preserve the predictor for later valid frames.
            let pcm = canDecode ? decoder.decode(partial) : []
            if phase == .physical {
                if canDecode { baselinePCMFrames += 1 }
            } else if whollyLate {
                if phase == .afterRelease { observeFrame(&phaseA, pcm: pcm, nowNs: nowNs) }
                else { observeFrame(&phaseB, pcm: pcm, nowNs: nowNs) }
            }
            partial.removeAll(keepingCapacity: false)
            partialStartNs = nil
        }
        return []
    }

    func stop(_ outcome: Report.Outcome, detail: String) -> [Effect] {
        guard phase != .finished else { return [] }
        return finish(outcome, detail)
    }

    private func observeRaw(_ stats: inout Statistics, data: Data, eligible: Bool, nowNs: UInt64) {
        stats.notifications += 1
        stats.bytes += data.count
        if eligible {
            stats.lateNotifications += 1
            stats.lateBytes += data.count
            if stats.firstRawNs == nil { stats.firstRawNs = nowNs }
            stats.lastRawNs = nowNs
        }
    }

    private func observeFrame(_ stats: inout Statistics, pcm: [Int16], nowNs: UInt64) {
        stats.lateFrames += 1
        guard !pcm.isEmpty else { return }
        stats.validPCMFrames += 1
        stats.pcmSamples += pcm.count
        var sum = 0.0
        var square = 0.0
        var peak = 0
        for sample in pcm {
            let value = Double(sample)
            sum += value
            square += value * value
            peak = max(peak, abs(Int(sample)))
        }
        stats.pcmPeak = max(stats.pcmPeak, peak)
        stats.squareSum += square
        // AC RMS excludes constant decoder/DC output; a lone codec spike cannot
        // establish sustained signal because at least ten energetic frames are needed.
        let mean = sum / Double(pcm.count)
        let acRMS = sqrt(max(0, square / Double(pcm.count) - mean * mean))
        if acRMS >= 64 && peak >= 128 {
            stats.energeticFrames += 1
            if stats.firstEnergyNs == nil { stats.firstEnergyNs = nowNs }
            stats.lastEnergyNs = nowNs
        }
    }

    private func resetDecode() {
        synchronized = false
        framingUnknown = false
        partial.removeAll(keepingCapacity: false)
        partialStartNs = nil
        decoder.reset(predictor: 0, stepIndex: 0)
        decodeNote = "尚未收到可验证的同步PCM"
    }

    private func finish(_ outcome: Report.Outcome, _ detail: String) -> [Effect] {
        phase = .finished
        resetDecode()
        return [.finished(Report(outcome: outcome, phaseA: phaseA, phaseB: phaseB,
                                 baselinePCMFrames: baselinePCMFrames,
                                 hostOpenAttempted: hostOpenAttempted, detail: detail))]
    }

    /// Pure state and fake-effect checks. No CB/CG, input method, file or sound I/O.
    static func selfCheck() -> Bool {
        func report(_ effects: [Effect]) -> Report? {
            for case .finished(let value) in effects { return value }
            return nil
        }
        let timeout = VoiceContinuityProbe(version: 0x0100, frameSize: 120, nowNs: 0)
        guard report(timeout.advance(nowNs: 15_000_000_000))?.outcome == .timedOut,
              timeout.advance(nowNs: 30_000_000_000).isEmpty else { return false }

        let raw = VoiceContinuityProbe(version: 0x0100, frameSize: 120, nowNs: 0)
        _ = raw.streamStarted(nowNs: 10)
        _ = raw.streamStopped(nowNs: 100)
        _ = raw.audio(Data(repeating: 0, count: 120), nowNs: 500_000_100)
        _ = raw.audio(Data(repeating: 0, count: 120), nowNs: 1_500_000_100)
        let closing = raw.advance(nowNs: 6_000_000_100)
        guard closing.contains(where: { if case .closeMicrophone = $0 { return true }; return false }) else { return false }
        let opening = raw.advance(nowNs: 6_300_000_100)
        guard opening.count == 1, case .openMicrophone = opening[0] else { return false }
        _ = raw.streamStarted(nowNs: 6_400_000_100) // ACK/start is not audio proof.
        guard let noPCM = report(raw.advance(nowNs: 11_300_000_100)),
              !noPCM.isSupportConfirmed, noPCM.phaseA.notifications == 2,
              noPCM.phaseA.lateNotifications == 1, noPCM.phaseA.validPCMFrames == 0,
              raw.physicalRequest(nowNs: 12_000_000_000).isEmpty else { return false }

        let split = VoiceContinuityProbe(version: 0x0100, frameSize: 120, nowNs: 0)
        _ = split.streamStarted(nowNs: 1)
        split.sync(predictor: 0, stepIndex: 40)
        _ = split.audio(Data(repeating: 0x77, count: 120), nowNs: 2)
        _ = split.streamStopped(nowNs: 100)
        _ = split.audio(Data(repeating: 0x77, count: 60), nowNs: 900_000_100)
        _ = split.audio(Data(repeating: 0x77, count: 60), nowNs: 1_100_000_100)
        guard let cancelled = report(split.stop(.cancelled, detail: "test")),
              cancelled.phaseA.lateFrames == 0,
              !cancelled.isSupportConfirmed,
              split.advance(nowNs: 60_000_000_000).isEmpty else { return false }

        let signal = VoiceContinuityProbe(version: 0x0100, frameSize: 120, nowNs: 0)
        _ = signal.streamStarted(nowNs: 1)
        signal.sync(predictor: 0, stepIndex: 40)
        _ = signal.audio(Data(repeating: 0x77, count: 120), nowNs: 2)
        _ = signal.streamStopped(nowNs: 100)
        for index in 0..<90 {
            let time = 1_100_000_100 + UInt64(index) * 15_000_000
            signal.sync(predictor: 0, stepIndex: 40)
            _ = signal.audio(Data(repeating: 0x77, count: 120), nowNs: time)
        }
        guard let sustained = report(signal.advance(nowNs: 6_000_000_100)),
              sustained.isSupportConfirmed, !sustained.hostOpenAttempted,
              sustained.phaseA.validPCMFrames == 90 else { return false }

        let unknown = VoiceContinuityProbe(version: 0x0100, frameSize: 120, nowNs: 0)
        _ = unknown.streamStarted(nowNs: 1)
        unknown.sync(predictor: 0, stepIndex: 89)
        _ = unknown.streamStopped(nowNs: 100)
        _ = unknown.audio(Data(repeating: 0x77, count: 120), nowNs: 1_100_000_100)
        guard let invalid = report(unknown.stop(.cancelled, detail: "test")),
              invalid.phaseA.validPCMFrames == 0 else { return false }
        return true
    }
}
