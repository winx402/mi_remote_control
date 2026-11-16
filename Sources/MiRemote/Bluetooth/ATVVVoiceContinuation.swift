import Foundation

/// Transport segments are shorter than a physical hold. Only an expiring lease
/// from the HID/context owner permits one OPEN after a firmware-length segment.
/// This value has no timers, Bluetooth or UI dependencies; the bridge applies its
/// effects on the same serial queue as incoming control/audio notifications.
struct ATVVVoiceContinuation {
    enum Effect: Equatable { case begin, segment, open, close, end, extend(UInt16), failed(String) }
    enum StopReason: Equatable {
        case unspecified, timeout, release, hostClose, upcomingStart, notificationsOff, fault
        init(byte: UInt8?) {
            switch byte {
            case nil: self = .unspecified
            case 0x08: self = .timeout
            case 0x02: self = .release
            case 0x00: self = .hostClose
            case 0x04: self = .upcomingStart
            case 0x10: self = .notificationsOff
            default: self = .fault
            }
        }
    }
    private enum Phase { case idle, streaming, confirmingHold, waitingForStart, waitingForAudio }
    static let leaseNs: UInt64 = 500_000_000
    static let extendIntervalNs: UInt64 = 8_000_000_000
    static let recoveryNs: UInt64 = 3_000_000_000
    static let minimumSegmentNs: UInt64 = 50_000_000_000
    static let holdConfirmationNs: UInt64 = 200_000_000

    private var phase = Phase.idle
    private var grant: (token: UInt64, expires: UInt64)?
    private var boundToken: UInt64?
    private var retiredToken: UInt64?
    private var extensionSession: UInt16?
    private var nextExtend: UInt64 = 0
    private var segmentStart: UInt64 = 0
    private var lastAudio: UInt64 = 0
    private var recoveryDeadline: UInt64 = 0
    private var hasAudio = false
    private var continuationOpened = false
    private var allowUnrequestedAfterQuarantine = true
    private var startQuarantineDeadline: UInt64 = 0
    private var lastEventNs: UInt64 = 0
    private var startArmed = true // Retain ordinary unsolicited START compatibility on connection.
    var isActive: Bool { phase != .idle }

    mutating func authorize(token: UInt64, nowNs: UInt64) {
        guard token != retiredToken, boundToken == nil || boundToken == token else { return }
        grant = (token, nowNs &+ Self.leaseNs)
        if isActive { boundToken = token }
        else { startArmed = true } // A fresh physical/context token can rearm a cancelled transport.
    }

    mutating func revoke(token: UInt64, nowNs: UInt64? = nil) -> [Effect] {
        if let nowNs { lastEventNs = nowNs }
        guard boundToken == token || grant?.token == token else { return [] }
        grant = nil
        retiredToken = token
        guard boundToken == token else { return [] }
        if phase != .streaming || continuationOpened { return finish() }
        // Preserve original STOP/HID-tail delivery when a normal physical press ends.
        boundToken = nil
        return []
    }

    /// Repeated requests inside one logical hold must not send extra OPENs.
    mutating func physicalRequest() -> Bool {
        guard !isActive else { return false }
        startArmed = true
        return true
    }

    mutating func started(sessionID: UInt16?, supportsExtension: Bool = false, physicalStart: Bool = false, nowNs: UInt64) -> [Effect] {
        lastEventNs = nowNs
        switch phase {
        case .idle:
            guard startArmed || physicalStart || (allowUnrequestedAfterQuarantine && nowNs >= startQuarantineDeadline) else { return [] }
            startArmed = false
            phase = .streaming
            extensionSession = supportsExtension ? sessionID : nil
            nextExtend = nowNs &+ Self.extendIntervalNs
            segmentStart = nowNs
            lastAudio = nowNs
            hasAudio = false
            continuationOpened = false
            if let grant, grant.expires > nowNs { boundToken = grant.token }
            else { grant = nil }
            return [.begin]
        case .confirmingHold:
            return []
        case .waitingForStart:
            guard authorized(nowNs), nowNs < recoveryDeadline else { return fail("续接启动时授权已失效或已超时") }
            extensionSession = supportsExtension ? sessionID : nil
            nextExtend = nowNs &+ Self.extendIntervalNs
            segmentStart = nowNs
            lastAudio = nowNs
            hasAudio = false
            phase = .waitingForAudio
            // START is only acknowledgement: preserve the original recovery deadline.
            return [.segment]
        case .streaming, .waitingForAudio:
            // Duplicate or delayed START cannot reset decoder, audio evidence or timeouts.
            return []
        }
    }

    mutating func audioFrame(nowNs: UInt64) -> [Effect] {
        lastEventNs = nowNs
        guard phase == .streaming || phase == .waitingForAudio else { return [] }
        if phase == .waitingForAudio, !authorized(nowNs) { return fail("续接音频到达时授权已失效") }
        if phase == .waitingForAudio, nowNs >= recoveryDeadline { return fail("续接音频未在3秒内到达") }
        phase = .streaming
        hasAudio = true
        lastAudio = nowNs
        return []
    }

    mutating func stopped(reason: StopReason = .unspecified, nowNs: UInt64) -> [Effect] {
        lastEventNs = nowNs
        if reason != .timeout && reason != .unspecified {
            guard isActive else { return [] }
            if (reason == .fault || reason == .notificationsOff), continuationOpened {
                return fail("续接因遥控器故障或通知关闭而停止")
            }
            return finish()
        }
        switch phase {
        case .idle, .confirmingHold, .waitingForStart:
            return [] // Absorb repeated STOP while the single OPEN is outstanding.
        case .waitingForAudio:
            return fail("续接启动后尚无音频即停止")
        case .streaming:
            let age = nowNs >= segmentStart ? nowNs - segmentStart : 0
            if authorized(nowNs), hasAudio,
               (reason == .timeout || age >= Self.minimumSegmentNs) {
                phase = .confirmingHold
                recoveryDeadline = nowNs &+ Self.holdConfirmationNs
                return [] // Let a normal HID release overtake the BLE STOP before opening.
            }
            return continuationOpened && authorized(nowNs) ? fail("续接段提前停止") : finish()
        }
    }

    mutating func advance(nowNs: UInt64) -> [Effect] {
        lastEventNs = nowNs
        guard isActive, boundToken != nil else { return [] }
        if phase == .confirmingHold {
            guard authorized(nowNs) else { return finish() }
            guard nowNs >= recoveryDeadline else { return [] }
            phase = .waitingForStart
            continuationOpened = true
            recoveryDeadline = nowNs &+ Self.recoveryNs
            return [.open] // STOP closed the old stream: do not send an echo-producing CLOSE.
        }
        if phase == .waitingForStart || phase == .waitingForAudio {
            guard authorized(nowNs) else { return fail("续接等待期间授权已失效") }
            return nowNs >= recoveryDeadline ? fail(phase == .waitingForStart ? "续接START未在3秒内到达" : "续接音频未在3秒内到达") : []
        }
        // Lease expiry alone never interrupts an already producing transport.
        if continuationOpened, nowNs >= lastAudio, nowNs - lastAudio >= Self.recoveryNs {
            return fail("续接段连续3秒没有完整音频帧")
        }
        if phase == .streaming, let extensionSession, authorized(nowNs), hasAudio,
           nowNs >= lastAudio, nowNs - lastAudio < Self.recoveryNs, nowNs >= nextExtend {
            nextExtend = nowNs &+ Self.extendIntervalNs
            return [.extend(extensionSession)]
        }
        return []
    }

    mutating func transportError(_ reason: String) -> [Effect] {
        guard isActive else { return [] }
        return continuationOpened ? fail(reason) : finish()
    }

    private func authorized(_ nowNs: UInt64) -> Bool {
        guard let boundToken, let grant else { return false }
        return grant.token == boundToken && grant.expires > nowNs
    }

    private mutating func fail(_ reason: String) -> [Effect] {
        [.failed(reason)] + finish()
    }

    private mutating func finish() -> [Effect] {
        guard isActive else { return [] }
        if let boundToken { retiredToken = boundToken }
        else if let grant { retiredToken = grant.token }
        allowUnrequestedAfterQuarantine = !continuationOpened
        startQuarantineDeadline = lastEventNs &+ Self.leaseNs
        phase = .idle
        boundToken = nil
        grant = nil
        startArmed = false // CLOSE echoes and delayed STARTs cannot create a new logical hold.
        return [.end, .close]
    }

    static func selfCheck() -> Bool {
        let second: UInt64 = 1_000_000_000
        func isFailure(_ effects: [Effect]) -> Bool {
            guard effects.count == 3, case .failed = effects[0] else { return false }
            return Array(effects.suffix(2)) == [.end, .close]
        }
        var model = Self()
        guard model.physicalRequest(), model.started(sessionID: 1, nowNs: 0) == [.begin] else { return false }
        // Three firmware boundaries, one OPEN each, a single logical begin/end.
        for boundary: UInt64 in 1...3 {
            let now = boundary * 60 * second
            model.authorize(token: 1, nowNs: now)
            _ = model.audioFrame(nowNs: now)
            guard !model.physicalRequest(), model.stopped(nowNs: now) == [],
                  model.stopped(nowNs: now) == [],
                  model.started(sessionID: 1, nowNs: now) == [],
                  model.advance(nowNs: now + Self.holdConfirmationNs - 1) == [],
                  model.advance(nowNs: now + Self.holdConfirmationNs) == [.open],
                  model.advance(nowNs: now + Self.holdConfirmationNs) == [],
                  model.started(sessionID: boundary == 2 ? nil : 1, nowNs: now + Self.holdConfirmationNs) == [.segment],
                  model.started(sessionID: 1, nowNs: now + Self.holdConfirmationNs) == [] else { return false }
            _ = model.audioFrame(nowNs: now + Self.holdConfirmationNs)
        }
        guard model.revoke(token: 1) == [.end, .close],
              model.stopped(nowNs: 180 * second) == [],
              model.started(sessionID: 1, nowNs: 180 * second) == [] else { return false }
        model.authorize(token: 1, nowNs: 181 * second)
        guard model.physicalRequest(), model.started(sessionID: 5, nowNs: 181 * second) == [.begin],
              model.stopped(nowNs: 241 * second) == [.end, .close] else { return false }
        var normal = Self()
        guard normal.started(sessionID: 1, nowNs: 0) == [.begin],
              normal.stopped(nowNs: 60 * second) == [.end, .close] else { return false }
        var short = Self()
        short.authorize(token: 2, nowNs: 0)
        _ = short.started(sessionID: 1, nowNs: 0)
        _ = short.audioFrame(nowNs: 1)
        guard short.stopped(nowNs: 2) == [.end, .close] else { return false }
        var released = Self()
        released.authorize(token: 3, nowNs: 0)
        _ = released.started(sessionID: 1, nowNs: 0)
        guard released.revoke(token: 3) == [], // Original tail is preserved.
              released.stopped(nowNs: 1) == [.end, .close] else { return false }
        var graceRelease = Self()
        _ = graceRelease.started(sessionID: 1, nowNs: 0)
        graceRelease.authorize(token: 4, nowNs: 60 * second)
        _ = graceRelease.audioFrame(nowNs: 60 * second)
        guard graceRelease.stopped(nowNs: 60 * second) == [],
              graceRelease.revoke(token: 4) == [.end, .close],
              graceRelease.advance(nowNs: 61 * second) == [] else { return false }
        var stale = Self()
        stale.authorize(token: 5, nowNs: 0)
        _ = stale.started(sessionID: 1, nowNs: 0)
        stale.authorize(token: 6, nowNs: 1)
        _ = stale.audioFrame(nowNs: Self.leaseNs)
        guard stale.advance(nowNs: Self.leaseNs) == [],
              stale.stopped(nowNs: 60 * second) == [.end, .close] else { return false }
        for acknowledge in [false, true] {
            var timeout = Self()
            _ = timeout.started(sessionID: 1, nowNs: 0)
            timeout.authorize(token: 7, nowNs: 60 * second)
            _ = timeout.audioFrame(nowNs: 60 * second)
            guard timeout.stopped(nowNs: 60 * second) == [],
                  timeout.advance(nowNs: 60 * second + Self.holdConfirmationNs) == [.open] else { return false }
            if acknowledge {
                guard timeout.started(sessionID: nil, nowNs: 60 * second + Self.holdConfirmationNs) == [.segment],
                      timeout.started(sessionID: 1, nowNs: 62 * second) == [] else { return false }
            }
            timeout.authorize(token: 7, nowNs: 64 * second)
            guard isFailure(timeout.advance(nowNs: 64 * second)),
                  timeout.stopped(nowNs: 64 * second) == [],
                  timeout.started(sessionID: 2, nowNs: 64 * second) == [] else { return false }
        }
        // An active transport can pass 10 minutes, and 75 seconds without STOP.
        var long = Self()
        _ = long.started(sessionID: 1, nowNs: 0)
        long.authorize(token: 8, nowNs: 0)
        _ = long.audioFrame(nowNs: 1000 * second)
        guard long.advance(nowNs: 1000 * second) == [] else { return false }
        // v1 extends only a verified session with fresh hold/context and recent audio.
        for session: UInt16? in [0, 0x7a, nil] {
            for modern in [false, true] {
                var extended = Self()
                _ = extended.started(sessionID: session, supportsExtension: modern, nowNs: 0)
                for step: UInt64 in 1...80 { // More than ten minutes without a fixed recording cap.
                    let now = step * Self.extendIntervalNs
                    extended.authorize(token: 99, nowNs: now)
                    _ = extended.audioFrame(nowNs: now)
                    let expected: [Effect] = modern ? session.map { [.extend($0)] } ?? [] : []
                    guard extended.advance(nowNs: now) == expected,
                          extended.advance(nowNs: now) == [] else { return false }
                }
                guard extended.revoke(token: 99) == [],
                      extended.advance(nowNs: 1000 * second) == [],
                      extended.stopped(reason: .release, nowNs: 1000 * second) == [.end, .close] else { return false }
            }
        }
        // Known non-timeout STOPs never reopen, including during the HID grace.
        for reason in [StopReason.release, .hostClose, .upcomingStart, .notificationsOff, .fault] {
            var stopped = Self()
            _ = stopped.started(sessionID: 3, nowNs: 0)
            stopped.authorize(token: 100, nowNs: 60 * second)
            _ = stopped.audioFrame(nowNs: 60 * second)
            guard stopped.stopped(reason: reason, nowNs: 60 * second) == [.end, .close],
                  stopped.advance(nowNs: 60 * second + Self.holdConfirmationNs) == [] else { return false }
        }
        // Two ordinary HTT presses may arrive directly as START without MIC_REQUEST.
        var consecutive = Self()
        guard consecutive.started(sessionID: 1, physicalStart: true, nowNs: 0) == [.begin],
              consecutive.stopped(reason: .release, nowNs: second) == [.end, .close],
              consecutive.started(sessionID: 2, physicalStart: true, nowNs: second + 1) == [.begin],
              consecutive.stopped(reason: .release, nowNs: 2 * second) == [.end, .close],
              consecutive.started(sessionID: nil, nowNs: 2 * second) == [],
              consecutive.started(sessionID: nil, nowNs: 3 * second) == [.begin] else { return false }
        // Raw HID up can precede the near-minute STOP or arrive at the final grace instant.
        for releaseAfterStop in [false, true] {
            var race = Self()
            _ = race.started(sessionID: 3, nowNs: 0)
            race.authorize(token: 101, nowNs: 60 * second)
            _ = race.audioFrame(nowNs: 60 * second)
            if releaseAfterStop {
                guard race.stopped(reason: .timeout, nowNs: 60 * second) == [],
                      race.advance(nowNs: 60 * second + Self.holdConfirmationNs - 1) == [],
                      race.revoke(token: 101) == [.end, .close] else { return false }
            } else {
                guard race.revoke(token: 101) == [],
                      race.stopped(reason: .timeout, nowNs: 60 * second) == [.end, .close] else { return false }
            }
            guard race.advance(nowNs: 61 * second) == [] else { return false }
        }
        model = Self() // Disconnect drops every grant and timer epoch.
        return model.revoke(token: 1) == [] && model.advance(nowNs: 999 * second) == []
    }
}
