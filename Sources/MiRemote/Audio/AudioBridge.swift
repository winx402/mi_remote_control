import Foundation
import CoreAudio
import AudioToolbox

// 音频输出桥：把 ATVV 解码出的 16kHz Int16 单声道 PCM 实时播放到指定输出设备
// （典型用法：播到 "BlackHole 2ch"，由豆包输入法把它当麦克风识别成文字）。

// MARK: - CoreAudio 设备工具

private enum CoreAudioDevices {

    /// 枚举系统里所有音频设备的 AudioObjectID。
    static func allDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids
        )
        guard status == noErr else { return [] }
        return ids
    }

    /// 该设备是否有输出流（>0 个输出通道）。
    static func hasOutputStreams(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return false }

        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(
            capacity: Int(dataSize) / MemoryLayout<AudioBufferList>.stride + 1
        )
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferList) == noErr
        else { return false }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        var channels: UInt32 = 0
        for buffer in buffers { channels += buffer.mNumberChannels }
        return channels > 0
    }

    /// 设备名（kAudioObjectPropertyName）。
    static func name(of deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString? = nil
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, ptr)
        }
        guard status == noErr, let cf = name else { return nil }
        return cf as String
    }

    /// 所有带输出流的设备名。
    static func outputDeviceNames() -> [String] {
        allDeviceIDs()
            .filter { hasOutputStreams($0) }
            .compactMap { name(of: $0) }
    }

    /// 按名字前缀匹配第一个有输出流的设备。
    static func findOutputDevice(namePrefix: String) -> AudioObjectID? {
        for id in allDeviceIDs() where hasOutputStreams(id) {
            if let n = name(of: id), n.hasPrefix(namePrefix) {
                return id
            }
        }
        return nil
    }
}

// MARK: - AudioBridge

/// AudioQueue receives source-rate PCM and converts to the explicitly bound device format.
/// All state and output callbacks share stateQueue; no audio callback touches main-thread state.
final class AudioBridge: PCMSink, @unchecked Sendable {
    /// AudioQueueDispose waits for callbacks. It must never run on their dispatch queue.
    private final class QueueHandle: @unchecked Sendable {
        let queue: AudioQueueRef
        init(_ queue: AudioQueueRef) { self.queue = queue }
    }
    private static let disposalQueue = DispatchQueue(label: "com.miremote.audiobridge.dispose", qos: .userInitiated)

    private static func dispose(_ queue: AudioQueueRef, then completion: @escaping @Sendable () -> Void) {
        let handle = QueueHandle(queue)
        disposalQueue.async {
            let status = AudioQueueDispose(handle.queue, true)
            if status != noErr { NSLog("[AudioBridge] 清理播放队列失败 (\(status))") }
            completion()
        }
    }

    private let deviceName: String?
    private let requiresNamedDevice: Bool
    private let stateQueue = DispatchQueue(label: "com.miremote.audiobridge.state", qos: .userInitiated)
    private var audioQueue: AudioQueueRef?
    private var playback = AudioPlaybackBuffer()
    private var sourceSampleRate: Double = 16_000
    private var accepting = false
    private var stopping = false
    private var generation: UInt64 = 0
    private var drainDeadline: UInt64 = 0
    private var drainCallbacks: [@Sendable () -> Void] = []
    private var inFlight: [UInt: Int] = [:]

    init(deviceName: String?, requiresNamedDevice: Bool = false) {
        self.deviceName = deviceName
        self.requiresNamedDevice = requiresNamedDevice
    }

    deinit {
        if let queue = audioQueue { Self.dispose(queue) {} }
    }

    func streamStarted(sampleRate: Double) { streamStarted(sampleRate: sampleRate, onReady: nil) }

    /// Confirms only that the output queue is ready; the input method has its own startup gate.
    func streamStarted(sampleRate: Double, onReady: (@Sendable (Bool) -> Void)?) {
        stateQueue.async { [self] in
            guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate) else {
                onReady?(false)
                return
            }
            if accepting, sourceSampleRate == sampleRate { onReady?(true); return }
            if audioQueue != nil { finish(reason: "superseded", complete: false) }
            generation &+= 1
            sourceSampleRate = sampleRate
            playback = AudioPlaybackBuffer()
            inFlight.removeAll(keepingCapacity: true)
            stopping = false
            start(onReady: onReady)
        }
    }

    func write(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        // Dispatch preserves start/write/stop order, including a burst of cached pre-roll.
        stateQueue.async { [self] in
            guard accepting else { return }
            playback.append(samples)
        }
    }

    func streamStopped() { streamStopped(onDrained: nil) }

    /// Drains every accepted source sample, a 200ms silent tail, and the queue's converter.
    /// IsRunning=0 after AudioQueueStop(false), rather than an empty FIFO, proves completion.
    func streamStopped(onDrained: (@Sendable () -> Void)?) {
        stateQueue.async { [self] in
            guard audioQueue != nil else { onDrained?(); return }
            if let onDrained { drainCallbacks.append(onDrained) }
            guard accepting else { return }
            accepting = false
            playback.finish(silenceFrames: Int((sourceSampleRate * 0.2).rounded(.up)))
            // Backlog may exceed seconds after a gated start; its full duration is allowed.
            // A stalled/disconnected device still gets a bounded deadline, with explicit loss logging.
            let seconds = Double(playback.pendingFrames) / sourceSampleRate + 0.06 + 5.0
            drainDeadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
            pollDrain(generation: generation)
        }
    }

    func cancelStream() {
        stateQueue.async { [self] in
            guard audioQueue != nil else { return }
            finish(reason: "cancelled", complete: false)
        }
    }

    private func refill(_ queue: AudioQueueRef, _ buffer: AudioQueueBufferRef, generation token: UInt64) {
        guard generation == token, audioQueue == queue, !stopping else { return }
        let key = UInt(bitPattern: buffer)
        playback.completedFrames += inFlight.removeValue(forKey: key) ?? 0
        let count = Int(buffer.pointee.mAudioDataBytesCapacity) / MemoryLayout<Float>.size
        let speechFrames = playback.read(into: buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self), count: count)
        buffer.pointee.mAudioDataByteSize = buffer.pointee.mAudioDataBytesCapacity
        let status = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        guard status == noErr else {
            NSLog("[AudioBridge] 提交播放缓冲失败 (\(status))")
            stateQueue.async { [self] in
                guard generation == token else { return }
                finish(reason: "enqueue_failed", complete: false)
            }
            stopping = true
            return
        }
        inFlight[key] = speechFrames
        playback.submittedFrames += speechFrames
        if !accepting, playback.pendingFrames == 0 {
            // No more buffers are enqueued after this call. The queue also flushes its converter.
            stopping = true
            let status = AudioQueueStop(queue, false)
            if status != noErr {
                NSLog("[AudioBridge] 异步排空失败 (\(status))")
                stateQueue.async { [self] in
                    guard generation == token else { return }
                    finish(reason: "stop_failed", complete: false)
                }
            }
        }
    }

    private func pollDrain(generation token: UInt64) {
        guard token == generation, let queue = audioQueue, !accepting else { return }
        if stopping {
            var running: UInt32 = 1
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioQueueGetProperty(queue, kAudioQueueProperty_IsRunning, &running, &size)
            if status != noErr {
                finish(reason: "status_failed", complete: false)
                return
            }
            if running == 0 {
                // Stop(false) guarantees every submitted buffer played, even if its callback
                // has not been delivered on stateQueue yet.
                playback.completedFrames = playback.submittedFrames
                finish(reason: "drained", complete: playback.submittedFrames == playback.receivedFrames)
                return
            }
        }
        if DispatchTime.now().uptimeNanoseconds >= drainDeadline {
            finish(reason: "drain_timeout", complete: false)
            return
        }
        stateQueue.asyncAfter(deadline: .now() + .milliseconds(20)) { [self] in
            pollDrain(generation: token)
        }
    }

    private func finish(reason: String, complete: Bool) {
        generation &+= 1
        accepting = false
        stopping = true
        // Clear identity before disposal: synchronous disposal can itself deliver old callbacks.
        let queue = audioQueue
        audioQueue = nil
        let discarded = max(0, playback.receivedFrames - playback.completedFrames)
        NSLog("[AudioBridge] drain status=%@ rate=%.0f received=%ld submitted=%ld completed=%ld discarded=%ld truncated=%@",
              reason, sourceSampleRate, playback.receivedFrames, playback.submittedFrames,
              playback.completedFrames, discarded, complete ? "false" : "true")
        playback = AudioPlaybackBuffer()
        inFlight.removeAll(keepingCapacity: true)
        let callbacks = drainCallbacks
        drainCallbacks.removeAll()
        let callbackQueue = stateQueue
        if let queue {
            Self.dispose(queue) {
                // The detached queue remains alive until disposal finishes. New starts use a
                // different generation and never wait on this cleanup queue.
                callbackQueue.async { callbacks.forEach { $0() } }
            }
        } else {
            callbacks.forEach { $0() }
        }
    }

    private func start(onReady: (@Sendable (Bool) -> Void)?) {
        // PR14: unlike an AVAudioEngine I/O node, this queue keeps its explicit device UID
        // when an input method switches the system default microphone.
        var format = AudioStreamBasicDescription(
            mSampleRate: sourceSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
        )
        var created: AudioQueueRef?
        let token = generation
        do {
            try check(AudioQueueNewOutputWithDispatchQueue(&created, &format, 0, stateQueue) { [weak self] queue, buffer in
                self?.refill(queue, buffer, generation: token)
            }, "创建播放队列")
            guard let queue = created else {
                throw NSError(domain: "AudioBridge", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "未创建播放队列"])
            }
            if let name = deviceName {
                if let device = CoreAudioDevices.findOutputDevice(namePrefix: name) {
                    var address = AudioObjectPropertyAddress(
                        mSelector: kAudioDevicePropertyDeviceUID,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain)
                    var uid: CFString?
                    var size = UInt32(MemoryLayout<CFString?>.size)
                    try withUnsafeMutablePointer(to: &uid) { pointer in
                        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer), "读取输出设备 UID")
                        guard pointer.pointee != nil else {
                            throw NSError(domain: "AudioBridge", code: -4,
                                          userInfo: [NSLocalizedDescriptionKey: "输出设备 UID 为空"])
                        }
                        try check(AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice, pointer, size), "绑定输出设备")
                    }
                } else if requiresNamedDevice {
                    throw NSError(domain: "AudioBridge", code: -3,
                                  userInfo: [NSLocalizedDescriptionKey: "未找到指定的音频桥接设备"])
                } else {
                    NSLog("[AudioBridge] 未找到输出设备 %@，回退系统默认输出", name)
                }
            } else if requiresNamedDevice {
                throw NSError(domain: "AudioBridge", code: -3,
                              userInfo: [NSLocalizedDescriptionKey: "严格设备模式必须指定输出设备"])
            }
            // Exactly source-rate frames: never label 16k PCM as 48k (which plays only 1/3 as long).
            let bytes = UInt32((sourceSampleRate * 0.02).rounded(.up)) * UInt32(MemoryLayout<Float>.size)
            for _ in 0..<3 {
                var allocated: AudioQueueBufferRef?
                try check(AudioQueueAllocateBuffer(queue, bytes, &allocated), "分配播放缓冲")
                guard let buffer = allocated else {
                    throw NSError(domain: "AudioBridge", code: -2,
                                  userInfo: [NSLocalizedDescriptionKey: "未分配播放缓冲"])
                }
                memset(buffer.pointee.mAudioData, 0, Int(bytes))
                buffer.pointee.mAudioDataByteSize = bytes
                try check(AudioQueueEnqueueBuffer(queue, buffer, 0, nil), "提交初始播放缓冲")
            }
            audioQueue = queue
            try check(AudioQueueStart(queue, nil), "启动播放")
            accepting = true
            onReady?(true)
        } catch {
            audioQueue = nil
            NSLog("[AudioBridge] 启动失败: \(error)")
            let callbackQueue = stateQueue
            if let queue = created {
                Self.dispose(queue) { callbackQueue.async { onReady?(false) } }
            } else {
                onReady?(false)
            }
        }
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw NSError(domain: "AudioBridge", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "\(operation)失败 (\(status))"])
        }
    }

    static func listOutputDevices() -> [String] { CoreAudioDevices.outputDeviceNames() }

    /// Pure FIFO/rate/drain-accounting tests. Does not construct or start an audio device.
    static func selfTest() -> Bool { AudioPlaybackBuffer.selfTest() }
}

// MARK: - WAVSink（调试用）

/// 把整段流写成 16-bit 单声道 WAV 文件（streamStopped 时落盘）。
final class WAVSink: PCMSink {
    private let url: URL
    private var sampleRate: Double = 16000
    private var samples: [Int16] = []
    private let lock = NSLock()

    init(url: URL) {
        self.url = url
    }

    func streamStarted(sampleRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        self.sampleRate = sampleRate
        samples.removeAll(keepingCapacity: true)
    }

    func write(_ samples: [Int16]) {
        lock.lock()
        defer { lock.unlock() }
        self.samples.append(contentsOf: samples)
    }

    func streamStopped() {
        lock.lock()
        let snapshot = samples
        let sr = sampleRate
        lock.unlock()
        do {
            try Self.writeWAV(samples: snapshot, sampleRate: sr, to: url)
        } catch {
            NSLog("[WAVSink] 写文件失败: \(error)")
        }
    }

    /// 手写 44 字节 WAV 头 + PCM 数据。
    private static func writeWAV(samples: [Int16], sampleRate: Double, to url: URL) throws {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * MemoryLayout<Int16>.size)
        let chunkSize = 36 + dataSize

        var data = Data()
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        appendLE(chunkSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendLE(UInt32(16))                    // fmt chunk 大小
        appendLE(UInt16(1))                     // PCM
        appendLE(channels)
        appendLE(UInt32(sampleRate))
        appendLE(byteRate)
        appendLE(blockAlign)
        appendLE(bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        appendLE(dataSize)
        for s in samples { appendLE(s) }

        try data.write(to: url)
    }
}

// MARK: - TeeSink（广播）

/// 把 PCM 事件广播到多个 sink。
final class TeeSink: PCMSink {
    private let sinks: [PCMSink]

    init(_ sinks: [PCMSink]) {
        self.sinks = sinks
    }

    func streamStarted(sampleRate: Double) { sinks.forEach { $0.streamStarted(sampleRate: sampleRate) } }
    func write(_ samples: [Int16]) { sinks.forEach { $0.write(samples) } }
    func streamStopped() { streamStopped(onDrained: nil) }
    func streamStopped(onDrained: (@Sendable () -> Void)?) {
        let group = DispatchGroup()
        for sink in sinks {
            group.enter()
            sink.streamStopped { group.leave() }
        }
        if let onDrained { group.notify(queue: .global(qos: .userInitiated), execute: onDrained) }
    }
}
