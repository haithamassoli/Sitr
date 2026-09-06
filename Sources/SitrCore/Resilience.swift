// M4-T10: the decisions behind surviving sleep/wake, lock/unlock, fast user switching, display hot-plug and mirroring.
// Pure — every clock value is passed in and no display, stream or notification centre is involved — so the 10 s backoff
// ceiling, the "one Mac, several overlapping suspensions" bookkeeping and the mirror dedupe are unit-tested without
// AppKit and without a real second passing. `Sources/Sitr/Capture/*` and `Runtime` hold the AppKit half.

// MARK: - stream restart backoff

/// Exponential backoff for a capture stream that will not start: `first` seconds, doubling, never over `cap`. A stream
/// that ran for `resetAfter` before dying earns a fresh sequence (a laptop that wakes once a day must not start from the
/// ceiling). PRD/M4-T10: 1, 2, 4, 8, 10, 10 … s.
public struct Backoff: Hashable, Sendable {
    public var first: Double
    public var factor: Double
    public var cap: Double
    public var resetAfter: Double

    public init(first: Double = 1, factor: Double = 2, cap: Double = 10, resetAfter: Double = 30) {
        self.first = first
        self.factor = factor
        self.cap = cap
        self.resetAfter = resetAfter
    }

    /// M4-T10: 1 s, doubling, capped at 10 s; a stream that survived 30 s starts over.
    public static let captureStream = Backoff()

    /// Seconds to wait before retry number `attempt` (0-based). Multiplied rather than `pow`ed, so a session that has
    /// been failing for a week cannot overflow its way past the cap.
    public func delay(attempt: Int) -> Double {
        guard attempt > 0 else { return min(first, cap) }
        var delay = first
        for _ in 0..<attempt {
            if delay >= cap { return cap }
            delay *= factor
        }
        return min(delay, cap)
    }
}

/// One capture stream's restart bookkeeping. The owner reports failures and connects with its own clock; this decides
/// whether to schedule a reconnect and when. Exactly one retry can be pending at a time, so a burst of failures — a
/// delegate error, a failed reconnect and a topology change landing together — schedules one timer, not three.
public struct RestartPolicy: Hashable, Sendable {
    public enum Decision: Hashable, Sendable {
        /// Reconnect `after` seconds from the failure.
        case retry(after: Double)
        /// A reconnect was already scheduled and has not fired; this failure joins it. `after` is what is left of it.
        case alreadyScheduled(after: Double)
        /// Nothing to retry: capture was stopped, the grant is gone, or the display went away.
        case stop
    }

    public let backoff: Backoff
    /// Retries scheduled so far in the current sequence; the next delay is `backoff.delay(attempt:)`.
    public private(set) var attempt = 0
    /// Retries scheduled since the policy was created (never reset; the session reports it in logs and selftests).
    public private(set) var retries = 0
    /// Clock value the pending retry fires at, nil when none is pending.
    public private(set) var retryAt: Double?
    /// Clock value the current connection started at, nil while disconnected.
    public private(set) var connectedAt: Double?

    public init(backoff: Backoff = .captureStream) {
        self.backoff = backoff
    }

    /// The stream connected. Does not clear `attempt`: a stream that connects and dies again immediately keeps climbing
    /// the backoff; only surviving `backoff.resetAfter` earns a fresh sequence.
    public mutating func connected(at now: Double) {
        connectedAt = now
        retryAt = nil
    }

    /// The stream stopped with an error, or a connect attempt threw. `retryable` is the caller's world — still wanted,
    /// permission granted, display still there. Returns what to do; `attempt` only moves on `.retry`.
    public mutating func failed(at now: Double, retryable: Bool) -> Decision {
        let ranFor = connectedAt.map { now - $0 } ?? 0
        connectedAt = nil
        guard retryable else {
            retryAt = nil
            attempt = 0
            return .stop
        }
        if let at = retryAt, at > now { return .alreadyScheduled(after: at - now) }
        if ranFor >= backoff.resetAfter { attempt = 0 }
        let delay = backoff.delay(attempt: attempt)
        attempt += 1
        retries += 1
        retryAt = now + delay
        return .retry(after: delay)
    }

    /// The scheduled retry fired: the slot is free again, so the next failure schedules rather than joining a timer that
    /// has already gone off.
    public mutating func retryFired() {
        retryAt = nil
    }

    /// Stopped on purpose, or the display went away: no pending retry and the next failure starts from `first`.
    public mutating func reset() {
        attempt = 0
        retryAt = nil
        connectedAt = nil
    }

    /// Seconds left before the pending retry fires, nil when none is pending or it is already due.
    public func timeToRetry(at now: Double) -> Double? {
        guard let retryAt, retryAt > now else { return nil }
        return retryAt - now
    }
}

// MARK: - suspend / resume

/// Why capture is suspended. Several can hold at once — the screen locks, then the Mac sleeps, then the display sleeps —
/// and the streams come back only when the last one clears, so an unlock that arrives before the wake cannot restart
/// capture into a sleeping machine.
public struct SuspensionReasons: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// `NSWorkspace.willSleepNotification` … `didWakeNotification`.
    public static let systemSleep = SuspensionReasons(rawValue: 1 << 0)
    /// `NSWorkspace.sessionDidResignActiveNotification` … `sessionDidBecomeActiveNotification`: fast user switching.
    public static let sessionInactive = SuspensionReasons(rawValue: 1 << 1)
    /// `NSWorkspace.screensDidSleepNotification` … `screensDidWakeNotification`: displays off, the Mac awake.
    public static let screensAsleep = SuspensionReasons(rawValue: 1 << 2)
    /// `com.apple.screenIsLocked` … `com.apple.screenIsUnlocked`.
    public static let screenLocked = SuspensionReasons(rawValue: 1 << 3)
}

/// What capture should be doing. `resuming` is the gap between the wake and the first frame: streams are being rebuilt,
/// so PRD FR10 fail-closed covers stay up and a stopped session is not yet evidence of a lost grant.
public enum SystemActivity: Hashable, Sendable {
    case active, suspended, resuming
}

/// Sleep/wake, lock/unlock and fast user switching as one state machine. Feed it the `NSWorkspace` events in any order,
/// with any amount of duplication and nesting; it answers with the state capture should be in. Pure and unit-tested:
/// 20 sleep/wake cycles here cost no seconds and no hardware.
public struct SystemActivityMachine: Hashable, Sendable {
    public enum Event: Hashable, Sendable {
        case willSleep, didWake
        case sessionResignedActive, sessionBecameActive
        case screensDidSleep, screensDidWake
        case screenLocked, screenUnlocked

        /// The reason this event sets or clears, and which way.
        var reason: (SuspensionReasons, suspends: Bool) {
            switch self {
            case .willSleep: (.systemSleep, true)
            case .didWake: (.systemSleep, false)
            case .sessionResignedActive: (.sessionInactive, true)
            case .sessionBecameActive: (.sessionInactive, false)
            case .screensDidSleep: (.screensAsleep, true)
            case .screensDidWake: (.screensAsleep, false)
            case .screenLocked: (.screenLocked, true)
            case .screenUnlocked: (.screenLocked, false)
            }
        }
    }

    /// How long after the last wake a stopped session still counts as "coming back" rather than as a failure, when no
    /// frame has arrived to say so. Health is held for this long; fail-closed covers stay up until the frame itself.
    public static let settleFor: Double = 5

    public private(set) var reasons: SuspensionReasons = []
    public private(set) var state: SystemActivity = .active
    /// Clock value `state` last changed at.
    public private(set) var changedAt: Double = 0

    public init() {}

    /// One `NSWorkspace` event. Returns the new state when it moved, nil when it did not (a duplicate `didWake`, or a
    /// wake that still leaves the screen locked).
    @discardableResult
    public mutating func handle(_ event: Event, at now: Double) -> SystemActivity? {
        let (reason, suspends) = event.reason
        if suspends {
            reasons.insert(reason)
        } else {
            reasons.remove(reason)
        }
        return move(to: reasons.isEmpty ? (state == .suspended ? .resuming : state) : .suspended, at: now)
    }

    /// A frame reached the pipeline: capture is really back. Returns `.active` when that ended a resume, nil otherwise.
    @discardableResult
    public mutating func framesResumed(at now: Double) -> SystemActivity? {
        guard state == .resuming else { return nil }
        return move(to: .active, at: now)
    }

    /// Back to a cold start (`Runtime.stop()`), so a stopped runtime does not resume into a state nobody is watching.
    public mutating func reset() {
        reasons = []
        state = .active
        changedAt = 0
    }

    /// True while a stopped stream is explained by the transition rather than by a lost grant: suspended, or resuming and
    /// still inside `settleFor`. Callers hold their health state here.
    public func holdsHealth(at now: Double, settleFor: Double = SystemActivityMachine.settleFor) -> Bool {
        switch state {
        case .suspended: true
        case .resuming: now - changedAt < settleFor
        case .active: false
        }
    }

    /// Fail-closed covers (PRD FR10) belong up whenever capture is not known to be live.
    public var capturesFrames: Bool { state == .active }

    private mutating func move(to next: SystemActivity, at now: Double) -> SystemActivity? {
        guard next != state else { return nil }
        state = next
        changedAt = now
        return next
    }
}

// MARK: - topology

/// One entry of the display list macOS reports: the id we key everything by, and the display it mirrors.
public struct DisplayLink: Hashable, Sendable {
    public var id: UInt32
    /// `CGDisplayMirrorsDisplay`: the display whose pixels this one shows, 0 when it mirrors nothing.
    public var mirrors: UInt32

    public init(id: UInt32, mirrors: UInt32 = 0) {
        self.id = id
        self.mirrors = mirrors
    }
}

/// Which of the displays macOS reports we actually manage. Pure, so hot-plug and mirroring are unit-tested against a
/// list rather than against hardware. `CGDirectDisplayID` is a `UInt32`, which keeps this file free of CoreGraphics.
public enum DisplayTopology {
    /// One id, in the order given, per display that deserves its own panel and stream: duplicates collapse (a mirror set
    /// can report the same id twice) and a display mirroring another managed one is dropped — its pixels are the
    /// master's, so a second panel there would draw every cover twice and a second stream would capture the same frames.
    /// A list where everything mirrors something (a cycle that cannot happen on real hardware) is kept whole: covering
    /// nothing is worse than covering twice.
    public static func managed(_ links: [DisplayLink]) -> [UInt32] {
        var seen = Set<UInt32>()
        let unique = links.filter { seen.insert($0.id).inserted }
        let slaves = Set(unique.filter { $0.mirrors != 0 && $0.mirrors != $0.id && seen.contains($0.mirrors) }.map(\.id))
        guard slaves.count < unique.count else { return unique.map(\.id) }
        return unique.map(\.id).filter { !slaves.contains($0) }
    }
}
