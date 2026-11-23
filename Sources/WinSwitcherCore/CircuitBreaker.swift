import Foundation

/// Sliding-window circuit breaker for `CGEventTap` timeout events.
/// If macOS disables the event tap due to slow responses too frequently within the window,
/// the breaker trips and refuses automatic re-enabling so the user's keyboard can never freeze.
public struct TapCircuitBreaker: Sendable {
    public let maxTimeouts: Int
    public let windowSeconds: TimeInterval

    private var timeoutTimestamps: [TimeInterval] = []
    public private(set) var isTripped: Bool = false

    public init(maxTimeouts: Int = 2, windowSeconds: TimeInterval = 10.0) {
        self.maxTimeouts = max(1, maxTimeouts)
        self.windowSeconds = max(1.0, windowSeconds)
    }

    /// Records a `.tapDisabledByTimeout` event at timestamp `now`.
    /// - Returns: `true` if it is still safe to re-enable the tap; `false` if the breaker has tripped.
    @discardableResult
    public mutating func recordTimeout(at now: TimeInterval) -> Bool {
        if isTripped {
            return false
        }
        timeoutTimestamps.append(now)
        let cutoff = now - windowSeconds
        timeoutTimestamps.removeAll { $0 < cutoff }

        if timeoutTimestamps.count >= maxTimeouts {
            isTripped = true
            return false
        }
        return true
    }

    public mutating func reset() {
        timeoutTimestamps.removeAll()
        isTripped = false
    }

    public var recentTimeoutCount: Int {
        timeoutTimestamps.count
    }
}
