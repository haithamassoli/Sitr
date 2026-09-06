// M4-T07: the degraded-state hysteresis and the notification spacing behind PRD FR10 ("Detection > 250 ms/frame for 3 s
// → Degraded"). Pure: the caller measures the frames and passes its own clock, so both are unit-testable without a
// pipeline, a notification centre, or a real second passing.

/// Frame-time limits of the degraded state, in seconds. `enter` and `exit` leave a hysteresis band: a frame time between
/// them holds whatever state is current, so a detector hovering at the limit cannot flap.
public struct DegradedThresholds: Hashable, Sendable {
    /// Detection slower than this counts as slow (PRD FR10: 250 ms/frame).
    public var enter: Double
    /// Detection faster than this counts as healthy again.
    public var exit: Double
    /// Continuous slow seconds before the state flips to degraded.
    public var enterFor: Double
    /// Continuous fast seconds before it flips back.
    public var exitFor: Double

    public init(enter: Double = 0.250, exit: Double = 0.150, enterFor: Double = 3, exitFor: Double = 5) {
        self.enter = enter
        self.exit = exit
        self.enterFor = enterFor
        self.exitFor = exitFor
    }

    /// PRD FR10 / M4-T07: 250 ms for 3 s in, 150 ms for 5 s out.
    public static let standard = DegradedThresholds()
}

/// One detector's health over time. Feed it every measured frame in order; it answers whether detection is keeping up.
/// A run of slow (or fast) frames is measured from the *start* of its first frame, so one 4 s frame is already 4 s of
/// slowness and does not have to be followed by three more seconds of samples.
public struct DegradedMonitor: Hashable, Sendable {
    public let thresholds: DegradedThresholds
    public private(set) var isDegraded = false
    /// Start of the current run of slow frames while healthy, of fast frames while degraded; nil when a frame broke it.
    private var runSince: Double?

    public init(thresholds: DegradedThresholds = .standard) {
        self.thresholds = thresholds
    }

    /// One measured frame: `seconds` of detection work that finished at `now`. Returns the new value of `isDegraded`
    /// when this frame flipped it, nil when nothing changed. Samples must arrive in order (one monitor per pipeline).
    @discardableResult
    public mutating func record(seconds: Double, at now: Double) -> Bool? {
        let counts = isDegraded ? seconds < thresholds.exit : seconds > thresholds.enter
        guard counts else {
            runSince = nil
            return nil
        }
        let since = runSince ?? now - max(0, seconds)
        runSince = since
        guard now - since >= (isDegraded ? thresholds.exitFor : thresholds.enterFor) else { return nil }
        isDegraded.toggle()
        runSince = nil
        return isDegraded
    }

    /// Back to square one: healthy, with no run in progress. Used when the frames stop being comparable (a pipeline
    /// restarts, a display goes away) rather than to hide a real slowdown.
    public mutating func reset() {
        isDegraded = false
        runSince = nil
    }
}

/// Which health transitions are worth a user notification (M4-T07). Exactly one per transition — a repeat of the state
/// the user was already told about says nothing new — and the same transition at most once per `spacing`, so a detector
/// flapping between healthy and degraded cannot fill Notification Centre. Pure; the caller passes its own clock.
public struct HealthNotificationGate: Sendable {
    /// M4-T07: five minutes between repeats of the same transition.
    public static let repeatSpacing: Double = 300

    /// A change of health, from one state to another. `needsPermission → ok` and `degraded → ok` are different
    /// transitions: they have different causes, and each is throttled on its own.
    public struct Transition: Hashable, Sendable {
        public var from: Health
        public var to: Health

        public init(from: Health, to: Health) {
            self.from = from
            self.to = to
        }
    }

    private let spacing: Double
    private var lastPosted: [Transition: Double] = [:]

    public init(spacing: Double = HealthNotificationGate.repeatSpacing) {
        self.spacing = spacing
    }

    /// True when this transition should be announced; records it as announced. `from == to` is not a transition, and a
    /// suppressed transition is not recorded, so the spacing always runs from the last notification the user actually saw.
    public mutating func allows(from: Health, to: Health, at now: Double) -> Bool {
        guard from != to else { return false }
        let transition = Transition(from: from, to: to)
        if let last = lastPosted[transition], now - last < spacing { return false }
        lastPosted[transition] = now
        return true
    }
}
