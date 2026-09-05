// Reveal Hold state machine (M2-T13, PRD FR5). Pure: the hotkey manager passes timestamps in seconds.

public enum RevealState: Hashable, Sendable {
    case covered
    case revealed(since: Double)

    /// Safety timeout in seconds: a hold this long re-covers even without a release.
    public static let timeout: Double = 30

    public var isRevealed: Bool {
        if case .revealed = self { return true }
        return false
    }

    /// Hotkey pressed. Idempotent while revealed: repeats keep the original `since`, so they cannot extend the timeout.
    public mutating func press(at now: Double) {
        if case .covered = self { self = .revealed(since: now) }
    }

    /// Hotkey released.
    public mutating func release() {
        self = .covered
    }

    /// Periodic check; re-covers once the hold has lasted `timeout` or longer.
    public mutating func tick(now: Double) {
        if case .revealed(let since) = self, now - since >= Self.timeout { self = .covered }
    }

    /// The release event cannot arrive (app deactivated, or modifier flags changed without a release): fail safe.
    public mutating func lostRelease() {
        self = .covered
    }
}
