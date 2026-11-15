import AVFoundation
import Speech
import os

/// ATVV 已解码 PCM 的本机听写。不会打开系统麦克风、播放声音或上传音频。
/// 所有识别状态及 append 均在主线程，取消后旧回调由调用方的会话 token 隔离。
@MainActor final class RemoteSpeechTranscriber {
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private var task: SFSpeechRecognitionTask?
    private let recognizer: SFSpeechRecognizer
    private static let trace = Logger(subsystem: "com.miremote.controller", category: "RemoteSpeech")
    private var acceptsAudio = true
    private var sampleCount = 0
    private var peak = 0
    private var squares = 0.0
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: 16_000, channels: 1, interleaved: false)!

    static func availabilityNotice() -> String? {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: break
        case .notDetermined:
            // 回调只报告权限结果，绝不在用户松手后自动开启识别。
            SFSpeechRecognizer.requestAuthorization { status in
                let approved = status == .authorized
                Task { @MainActor in
                    CodexDictation.reportPermissionResult(approved: approved)
                }
            }
            return "请在 macOS 提示中允许语音识别，然后重新按住语音键。本次未开始听写。"
        case .denied:
            return "语音识别权限未开启。请在系统设置 → 隐私与安全性 → 语音识别中允许米控，再重新按住语音键。"
        case .restricted:
            return "此 Mac 的语音识别受到系统限制，本次未开始听写。"
        @unknown default:
            return "无法确认语音识别权限，本次未开始听写。"
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              recognizer.supportsOnDeviceRecognition else {
            return "此 Mac 尚不支持中文本机语音识别。请在系统键盘听写设置中添加／下载中文识别资源，或切换到 Mac 麦克风与已启用的语音输入法。"
        }
        guard recognizer.isAvailable else {
            return "本机中文语音识别暂不可用，请检查系统听写语言资源后重试。"
        }
        return nil
    }

    init?(completion: @escaping @MainActor (String?, String?) -> Void) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else { return nil }
        self.recognizer = recognizer
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        task = recognizer.recognitionTask(with: request) { result, error in
            let final = result?.isFinal == true ? result?.bestTranscription.formattedString : nil
            let failure = error.map { error -> String in
                let ns = error as NSError
                Self.trace.notice("recognition error domain=\(ns.domain, privacy: .public) code=\(ns.code)")
                if ns.domain == "kLSRErrorDomain", ns.code == 201 { return "请在系统设置 → 键盘中启用听写。" }
                return "本机语音识别未完成（\(ns.domain) \(ns.code)）。"
            }
            if let final { Self.trace.notice("recognition final characters=\(final.count)") }
            guard final != nil || failure != nil else { return }
            Task { @MainActor in completion(final, failure) }
        }
    }

    func append(_ samples: [Int16]) {
        guard acceptsAudio, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        sampleCount += samples.count
        for (index, sample) in samples.enumerated() {
            channel[index] = Float(sample) / 32768
            peak = max(peak, abs(Int(sample)))
            squares += Double(sample) * Double(sample)
        }
        request.append(buffer)
    }

    func endAudio() {
        guard acceptsAudio else { return }
        acceptsAudio = false
        let rms = Int(sqrt(squares / Double(max(1, sampleCount))))
        Self.trace.notice("end audio samples=\(self.sampleCount) peak=\(self.peak) rms=\(rms)")
        request.endAudio()
    }

    func cancel() {
        acceptsAudio = false
        task?.cancel()
        task = nil
    }
}
