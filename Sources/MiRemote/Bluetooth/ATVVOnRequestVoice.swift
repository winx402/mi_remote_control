import Foundation

/// Opt-in v1.0 experiment. A physical down owns exactly one host OPEN; release
/// closes even an unacknowledged OPEN. No BLE event can manufacture a new down.
struct ATVVOnRequestVoice {
    enum Effect: Equatable {
        case open, begin, end, close(UInt16), extend(UInt16), fallback(String)
    }
    private enum Mode { case standard, negotiating, onRequest }
    private enum Phase { case idle, opening, streaming }
    static let responseNs: UInt64 = 3_000_000_000
    static let extendNs: UInt64 = 8_000_000_000
    private var mode = Mode.standard
    private var phase = Phase.idle
    private(set) var heldToken: UInt64?
    private var deadline: UInt64 = 0
    private var lastAudio: UInt64 = 0
    private var nextExtend: UInt64 = 0
    private var hasAudio = false
    private var pressStartNs: UInt64 = 0
    private var requestDeadline: UInt64?
    private var lastReleaseNs: UInt64?
    var isEnabled: Bool { mode != .standard }
    var isOnRequest: Bool { mode == .onRequest }
    var needsTick: Bool { mode == .negotiating || (mode == .onRequest && (phase != .idle || requestDeadline != nil)) }

    mutating func negotiate(nowNs: UInt64) {
        mode = .negotiating
        phase = .idle
        deadline = nowNs &+ Self.responseNs
    }

    mutating func capabilities(version: UInt16, interactionModel: UInt8?, nowNs: UInt64) -> [Effect] {
        guard mode == .negotiating else { return [] }
        guard version >= 0x0100, interactionModel == 0 else {
            return fail("CAP_RESP未接受v1 On-request interaction model")
        }
        mode = .onRequest
        return openIfHeld(nowNs: nowNs)
    }

    mutating func button(held: Bool, token: UInt64, nowNs: UInt64) -> [Effect] {
        if held {
            guard heldToken == nil else { return [] } // HID repeats cannot OPEN twice.
            heldToken = token
            pressStartNs = nowNs
            requestDeadline = nil
            return openIfHeld(nowNs: nowNs)
        }
        guard heldToken == token else { return [] } // An old cancellation cannot release a new press.
        heldToken = nil
        lastReleaseNs = nowNs
        requestDeadline = nil
        guard mode == .onRequest, phase != .idle else { return [] }
        if !hasAudio, nowNs >= pressStartNs, nowNs - pressStartNs >= 600_000_000 {
            return fail("实体长按松手前主机请求未产生完整音频；恢复标准模式")
        }
        return finish()
    }

    mutating func remoteRequest(nowNs: UInt64) {
        guard isEnabled, heldToken == nil else { return }
        // A request that trails a very short UP is not a new physical press.
        if let lastReleaseNs, nowNs >= lastReleaseNs, nowNs - lastReleaseNs < 500_000_000 { return }
        if requestDeadline == nil { requestDeadline = nowNs &+ 500_000_000 }
    }

    mutating func started(reason: UInt8?, streamID: UInt16?, nowNs: UInt64) -> [Effect] {
        guard mode == .onRequest else { return [] }
        if reason == 1 || reason == 3 {
            // This is an explicitly physical PTT/HTT stream, not our host OPEN.
            // Hand it back intact: CLOSE(0) could truncate this very press.
            let effects: [Effect] = phase == .streaming ? [.end] : []
            phase = .idle
            mode = .standard
            return effects + [.fallback("实际START仍为物理PTT/HTT；本轮交回标准模式")]
        }
        // OPEN streams use ID zero. A delayed START after UP must only CLOSE,
        // including when UP beat the first START and the transport was never begun.
        guard heldToken != nil, phase != .idle else { return [.close(streamID.flatMap { $0 < 0xff ? $0 : nil } ?? 0)] }
        guard reason == 0, streamID == 0 else {
            // The device may have assigned an unexpected unicast ID. Close the
            // reported stream as well as retiring the assumed host ID zero.
            let effects = fail("START不符合On-request reason=00/streamID=00")
            if let streamID, streamID != 0, streamID < 0xff {
                return [.close(streamID)] + effects
            }
            return effects
        }
        guard phase == .opening else { return [] }
        phase = .streaming
        deadline = nowNs &+ Self.responseNs
        lastAudio = nowNs
        return [.begin]
    }

    mutating func audioFrame(nowNs: UInt64) {
        guard mode == .onRequest, phase == .streaming, heldToken != nil else { return }
        hasAudio = true
        lastAudio = nowNs
    }

    mutating func stopped() -> [Effect] {
        guard mode == .onRequest, phase != .idle else { return [] }
        if !hasAudio { return fail("On-request流在首个完整音频帧前停止") }
        // A release/timeout cannot be distinguished from a real physical release.
        // End normally; never reopen, even while the HID UP is still in flight.
        return finish()
    }

    mutating func error(_ reason: String) -> [Effect] {
        guard isEnabled else { return [] }
        return fail(reason)
    }

    mutating func advance(nowNs: UInt64, extensionAuthorized: Bool = false) -> [Effect] {
        if mode == .negotiating, nowNs >= deadline { return fail("On-request能力协商3秒无响应") }
        if mode == .onRequest, let requestDeadline, nowNs >= requestDeadline {
            return fail("On-request MIC_REQUEST在500ms内没有配对实体HID按下")
        }
        guard mode == .onRequest, phase != .idle else { return [] }
        guard heldToken != nil else { return finish() }
        if !hasAudio, nowNs >= deadline { return fail("On-request START或首帧3秒无响应") }
        if hasAudio, nowNs >= lastAudio, nowNs - lastAudio >= Self.responseNs {
            return fail("On-request连续3秒没有完整音频帧")
        }
        if hasAudio, extensionAuthorized, nowNs >= nextExtend {
            nextExtend = nowNs &+ Self.extendNs
            return [.extend(0)]
        }
        return []
    }

    private mutating func openIfHeld(nowNs: UInt64) -> [Effect] {
        guard mode == .onRequest, phase == .idle, heldToken != nil else { return [] }
        phase = .opening
        hasAudio = false
        deadline = nowNs &+ Self.responseNs
        nextExtend = nowNs &+ Self.extendNs
        return [.open]
    }

    private mutating func finish() -> [Effect] {
        guard phase != .idle else { return [] }
        let effects: [Effect] = phase == .streaming ? [.end, .close(0)] : [.close(0)]
        phase = .idle
        hasAudio = false
        return effects
    }

    private mutating func fail(_ reason: String) -> [Effect] {
        let effects = finish()
        mode = .standard
        requestDeadline = nil
        return effects + [.fallback(reason)]
    }

    static func selfCheck() -> Bool {
        func fallback(_ effects: [Effect]) -> Bool {
            effects.contains { if case .fallback = $0 { return true }; return false }
        }
        func ready() -> Self {
            var value = Self()
            value.negotiate(nowNs: 0)
            _ = value.capabilities(version: 0x0100, interactionModel: 0, nowNs: 0)
            return value
        }
        let s: UInt64 = 1_000_000_000
        var standard = Self()
        guard standard.button(held: true, token: 1, nowNs: 0) == [], !standard.isEnabled else { return false }
        for model: UInt8? in [nil, 1, 3] {
            var rejected = Self()
            rejected.negotiate(nowNs: 0)
            guard fallback(rejected.capabilities(version: 0x0100, interactionModel: model, nowNs: 0)),
                  !rejected.needsTick, rejected.advance(nowNs: 99 * s) == [] else { return false }
        }
        var negotiationTimeout = Self()
        negotiationTimeout.negotiate(nowNs: 0)
        guard fallback(negotiationTimeout.advance(nowNs: 3 * s)) else { return false }
        var early = Self()
        early.negotiate(nowNs: 0)
        guard early.button(held: true, token: 2, nowNs: 0) == [],
              early.button(held: false, token: 2, nowNs: 1) == [],
              early.capabilities(version: 0x0100, interactionModel: 0, nowNs: 2) == [] else { return false }
        var value = ready()
        guard value.button(held: true, token: 3, nowNs: 0) == [.open],
              value.button(held: true, token: 3, nowNs: 1) == [],
              value.button(held: false, token: 2, nowNs: 1) == [],
              value.started(reason: 0, streamID: 0, nowNs: 1) == [.begin] else { return false }
        for now: UInt64 in 1...80 { // 80 seconds, then real UP: no fixed minute cap.
            value.audioFrame(nowNs: now * s)
            let expected: [Effect] = now.isMultiple(of: 8) ? [.extend(0)] : []
            guard value.advance(nowNs: now * s, extensionAuthorized: true) == expected else { return false }
        }
        guard value.button(held: false, token: 3, nowNs: 81 * s) == [.end, .close(0)],
              value.started(reason: 0, streamID: 0, nowNs: 82 * s) == [.close(0)],
              value.advance(nowNs: 100 * s) == [],
              value.button(held: true, token: 4, nowNs: 101 * s) == [.open] else { return false }
        for reason: UInt8? in [nil, 1, 3] {
            var wrong = ready()
            _ = wrong.button(held: true, token: 1, nowNs: 0)
            let effects = wrong.started(reason: reason, streamID: 1, nowNs: 1)
            guard fallback(effects), reason == nil || !effects.contains(.close(0)) else { return false }
        }
        var wrongID = ready()
        _ = wrongID.button(held: true, token: 1, nowNs: 0)
        let wrongEffects = wrongID.started(reason: 0, streamID: 7, nowNs: 1)
        guard wrongEffects.contains(.close(7)), fallback(wrongEffects) else { return false }
        var tap = ready()
        _ = tap.button(held: true, token: 1, nowNs: 0)
        guard tap.button(held: false, token: 1, nowNs: 130_000_000) == [.close(0)], tap.isOnRequest,
              tap.started(reason: 0, streamID: 0, nowNs: s) == [.close(0)],
              tap.button(held: true, token: 2, nowNs: 2 * s) == [.open] else { return false }
        var unleased = ready()
        _ = unleased.button(held: true, token: 1, nowNs: 0)
        _ = unleased.started(reason: 0, streamID: 0, nowNs: 1)
        unleased.audioFrame(nowNs: 8 * s)
        guard unleased.advance(nowNs: 8 * s) == [],
              unleased.advance(nowNs: 8 * s, extensionAuthorized: true) == [.extend(0)] else { return false }
        var noHID = ready()
        noHID.remoteRequest(nowNs: 0)
        guard noHID.needsTick, noHID.advance(nowNs: 499_000_000) == [],
              fallback(noHID.advance(nowNs: 500_000_000)), !noHID.needsTick else { return false }
        var paired = ready()
        paired.remoteRequest(nowNs: 0)
        guard paired.button(held: true, token: 1, nowNs: 31_000_000) == [.open],
              paired.advance(nowNs: 500_000_000) == [] else { return false }
        for acknowledge in [false, true] {
            var short = ready()
            _ = short.button(held: true, token: 1, nowNs: 0)
            if acknowledge { _ = short.started(reason: 0, streamID: 0, nowNs: 1) }
            let effects = short.button(held: false, token: 1, nowNs: s)
            guard effects.contains(.close(0)), fallback(effects),
                  short.advance(nowNs: 10 * s) == [],
                  short.button(held: true, token: 2, nowNs: 11 * s) == [] else { return false }
            var timeout = ready()
            _ = timeout.button(held: true, token: 1, nowNs: 0)
            if acknowledge { _ = timeout.started(reason: 0, streamID: 0, nowNs: 1) }
            guard fallback(timeout.advance(nowNs: 4 * s)) else { return false }
        }
        var stopped = ready()
        _ = stopped.button(held: true, token: 1, nowNs: 0)
        _ = stopped.started(reason: 0, streamID: 0, nowNs: 1)
        stopped.audioFrame(nowNs: 2)
        return stopped.stopped() == [.end, .close(0)] && stopped.advance(nowNs: 60 * s) == []
            && stopped.button(held: true, token: 1, nowNs: 60 * s) == []
    }
}
