import CoreAudio
import Foundation

/// Read-only evidence about one process's input IO on the session's bridge.
/// Unknown is deliberately distinct from stopped; neither permits a stop toggle.
enum InputCaptureState: String {
    case running, stopped, unknown

    static func read(pid: pid_t, device: AudioDeviceID) -> InputCaptureState {
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard let processes = objects(system, selector: kAudioHardwarePropertyProcessObjectList) else { return .unknown }
        var matched = false
        var uncertain = false
        for process in processes {
            guard let owner: pid_t = scalar(process, selector: kAudioProcessPropertyPID), owner == pid else { continue }
            matched = true
            guard let active: UInt32 = scalar(process, selector: kAudioProcessPropertyIsRunningInput) else {
                uncertain = true
                continue
            }
            guard active != 0 else { continue }
            guard let devices = objects(process, selector: kAudioProcessPropertyDevices,
                                        scope: kAudioObjectPropertyScopeInput) else {
                uncertain = true
                continue
            }
            if devices.contains(device) { return .running }
        }
        return matched && !uncertain ? .stopped : .unknown
    }

    private static func scalar<T: FixedWidthInteger>(_ object: AudioObjectID,
                                                     selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var value: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<T>.size else { return nil }
        return value
    }

    private static func objects(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
              size.isMultiple(of: UInt32(MemoryLayout<AudioObjectID>.size)) else { return nil }
        if size == 0 { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &values) == noErr else { return nil }
        return values
    }
}

/// The hotkey being posted does not establish that WeType has opened BlackHole.
/// Positive capture evidence opens immediately; unavailable evidence gets a
/// bounded grace period. Verified stopped capture keeps waiting within the
/// caller's existing total startup deadline, including first-launch startup.
enum InputCaptureStartWait {
    enum Decision { case wait, ready, unconfirmed }

    static func decision(capture: InputCaptureState, elapsedNs: UInt64) -> Decision {
        switch capture {
        case .running: return .ready
        case .unknown: return elapsedNs >= 500_000_000 ? .unconfirmed : .wait
        case .stopped: return .wait
        }
    }

    static func selfCheck() -> Bool {
        decision(capture: .running, elapsedNs: 0) == .ready
            && decision(capture: .stopped, elapsedNs: 250_000_000) == .wait
            && decision(capture: .unknown, elapsedNs: 499_999_999) == .wait
            && decision(capture: .unknown, elapsedNs: 500_000_000) == .unconfirmed
            && decision(capture: .stopped, elapsedNs: 999_999_999) == .wait
            && decision(capture: .stopped, elapsedNs: 7_999_999_999) == .wait
    }
}

/// Recovery is permitted once, only after the original key was released and
/// the same input context still has positive evidence of lingering capture.
struct InputCaptureStopRecovery {
    private(set) var attempted = false

    mutating func shouldRetry(keyReleased: Bool, captureStartedHere: Bool, contextMatches: Bool,
                              capture: InputCaptureState) -> Bool {
        guard !attempted, keyReleased, captureStartedHere, contextMatches, capture == .running else { return false }
        attempted = true
        return true
    }

    static func selfCheck() -> Bool {
        var recovery = InputCaptureStopRecovery()
        guard !recovery.shouldRetry(keyReleased: false, captureStartedHere: true, contextMatches: true, capture: .running),
              !recovery.shouldRetry(keyReleased: true, captureStartedHere: false, contextMatches: true, capture: .running),
              !recovery.shouldRetry(keyReleased: true, captureStartedHere: true, contextMatches: false, capture: .running),
              !recovery.shouldRetry(keyReleased: true, captureStartedHere: true, contextMatches: true, capture: .unknown),
              !recovery.shouldRetry(keyReleased: true, captureStartedHere: true, contextMatches: true, capture: .stopped),
              !recovery.attempted,
              recovery.shouldRetry(keyReleased: true, captureStartedHere: true, contextMatches: true, capture: .running),
              !recovery.shouldRetry(keyReleased: true, captureStartedHere: true, contextMatches: true, capture: .running) else { return false }
        return true
    }
}
