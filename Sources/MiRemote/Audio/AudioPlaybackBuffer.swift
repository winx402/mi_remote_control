import Foundation

/// Source-rate PCM FIFO, isolated by AudioBridge.stateQueue. Chunks preserve every cached
/// sample without a fixed four-second ring overwriting the beginning of a long utterance.
struct AudioPlaybackBuffer {
    private var chunks: [[Int16]] = []
    private var head = 0
    private var offset = 0
    private var speechPending = 0
    private var silencePending = 0
    private var sealed = false
    private(set) var receivedFrames = 0
    var submittedFrames = 0
    var completedFrames = 0

    var pendingFrames: Int { speechPending + silencePending }
    var isDrained: Bool { sealed && pendingFrames == 0 && completedFrames == receivedFrames }

    mutating func append(_ samples: [Int16]) {
        guard !sealed, !samples.isEmpty else { return }
        chunks.append(samples)
        speechPending += samples.count
        receivedFrames += samples.count
    }

    mutating func finish(silenceFrames: Int) {
        guard !sealed else { return }
        sealed = true
        silencePending = max(0, silenceFrames)
    }

    /// Always fills a complete output buffer, preserving original sample order and duration.
    /// Returns only speech frames; intentional silence is excluded from delivery diagnostics.
    mutating func read(into dst: UnsafeMutablePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var written = 0
        while written < count, speechPending > 0 {
            let available = min(count - written, chunks[head].count - offset)
            for i in 0..<available { dst[written + i] = Float(chunks[head][offset + i]) / 32768.0 }
            written += available
            offset += available
            speechPending -= available
            if offset == chunks[head].count {
                // Release consumed audio promptly, without removing the first array every frame.
                chunks[head] = []
                head += 1
                offset = 0
            }
        }
        if head > 64 {
            chunks.removeFirst(head)
            head = 0
        }
        let silence = min(count - written, silencePending)
        silencePending -= silence
        if written < count { dst.advanced(by: written).initialize(repeating: 0, count: count - written) }
        return written
    }

    /// Deterministic offline regression for burst loss, source-rate duration and trailing PCM.
    static func selfTest() -> Bool {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            print("\(condition ? "PASS" : "FAIL") AudioBridge: \(name)")
            if !condition { failures += 1 }
        }
        for rate in [16_000, 44_100, 48_000] {
            let frameCount = rate * 17 + 137
            let source = (0..<frameCount).map { Int16(($0 % 60_001) - 30_000) }
            var fifo = AudioPlaybackBuffer()
            // One burst exceeds the old 64k capacity many times. Mixed packet sizes exercise
            // boundaries and the chunk compaction path without using a real audio device.
            var start = 0
            while start < source.count {
                let end = min(source.count, start + 113)
                fifo.append(Array(source[start..<end]))
                start = end
            }
            expect(fifo.receivedFrames == frameCount && fifo.pendingFrames == frameCount,
                   "\(rate)Hz long pre-roll retains all \(frameCount) frames")
            let tail = rate / 5
            fifo.finish(silenceFrames: tail)
            fifo.finish(silenceFrames: tail) // duplicate stop adds no second tail
            fifo.append([123]) // post-stop writes are not accepted
            var buffer = [Float](repeating: -10, count: rate / 50)
            var rendered = 0
            var buffers = 0
            var correct = true
            while fifo.pendingFrames > 0 {
                let count = buffer.withUnsafeMutableBufferPointer { fifo.read(into: $0.baseAddress!, count: $0.count) }
                for i in 0..<count {
                    if buffer[i] != Float(source[rendered + i]) / 32768.0 { correct = false }
                }
                if buffer[count...].contains(where: { $0 != 0 }) { correct = false }
                rendered += count
                fifo.submittedFrames += count
                buffers += 1
            }
            expect(correct && rendered == frameCount, "\(rate)Hz every sample and final 137-frame tail delivered in order")
            let expectedBuffers = (frameCount + tail + buffer.count - 1) / buffer.count
            expect(buffers == expectedBuffers, "\(rate)Hz duration equals source PCM plus 200ms silence")
            expect(!fifo.isDrained, "empty FIFO alone cannot prove output drain")
            fifo.completedFrames = fifo.submittedFrames
            expect(fifo.isDrained && fifo.receivedFrames == frameCount, "completion requires confirmed queued output")
        }
        var empty = AudioPlaybackBuffer()
        empty.finish(silenceFrames: 0)
        expect(empty.isDrained, "empty stream completes without lost frames")
        var partial = AudioPlaybackBuffer()
        partial.append([Int16.min, 0, Int16.max])
        var output = [Float](repeating: 9, count: 5)
        let read = output.withUnsafeMutableBufferPointer { partial.read(into: $0.baseAddress!, count: $0.count) }
        expect(read == 3 && output == [-1, 0, Float(Int16.max) / 32768, 0, 0], "Int16 scaling and underrun padding")
        return failures == 0
    }
}
