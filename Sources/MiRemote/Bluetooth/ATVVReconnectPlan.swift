import Foundation

/// Pure timing policy for explicit BLE reconnect requests. It does not pair a
/// device, take over HID, or extend a window when display/wake events repeat.
struct ATVVReconnectPlan {
    static let windowDuration: TimeInterval = 18
    static let connectionTimeout: TimeInterval = 8

    private(set) var token: UInt64 = 0
    private var deadline: TimeInterval?
    private var knownAttempted = false

    /// Returns a new token, or nil when this request merges into an open window.
    mutating func begin(now: TimeInterval) -> UInt64? {
        guard remaining(now: now) == nil else { return nil }
        token &+= 1
        deadline = now + Self.windowDuration
        knownAttempted = false
        return token
    }

    func remaining(now: TimeInterval) -> TimeInterval? {
        guard let deadline, deadline > now else { return nil }
        return deadline - now
    }

    func activeToken(now: TimeInterval) -> UInt64? {
        remaining(now: now) == nil ? nil : token
    }

    /// Consume before lookup, so an unknown/stale UUID is tried once per window.
    mutating func takeKnownAttempt(now: TimeInterval) -> Bool {
        guard remaining(now: now) != nil, !knownAttempted else { return false }
        knownAttempted = true
        return true
    }

    @discardableResult mutating func end(token expected: UInt64) -> Bool {
        guard token == expected, deadline != nil else { return false }
        deadline = nil
        return true
    }

    mutating func stop() {
        token &+= 1
        deadline = nil
        knownAttempted = false
    }

    /// The same policy drives pending-connect timers inside and outside a window.
    func pendingTimeout(now: TimeInterval) -> TimeInterval {
        min(Self.connectionTimeout, remaining(now: now) ?? Self.connectionTimeout)
    }

    static func selfCheck() -> Bool {
        var plan = Self()
        guard let first = plan.begin(now: 10),
              plan.takeKnownAttempt(now: 10), !plan.takeKnownAttempt(now: 11),
              plan.begin(now: 20) == nil, plan.remaining(now: 20) == 8,
              plan.pendingTimeout(now: 26) == 2,
              plan.activeToken(now: 28) == nil,
              !plan.takeKnownAttempt(now: 28),
              let second = plan.begin(now: 29), second != first,
              !plan.end(token: first), plan.takeKnownAttempt(now: 29) else { return false }
        plan.stop()
        guard !plan.end(token: second), plan.activeToken(now: 30) == nil,
              !plan.takeKnownAttempt(now: 30),
              plan.pendingTimeout(now: 30) == Self.connectionTimeout,
              let third = plan.begin(now: 31), third != second,
              plan.takeKnownAttempt(now: 31), plan.end(token: third),
              !plan.end(token: third), plan.remaining(now: 32) == nil else { return false }
        return true
    }
}
