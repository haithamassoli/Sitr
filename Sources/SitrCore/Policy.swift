// Who gets covered, how (per-app rules), and whether anything gets covered right now (M2-T09, M3-T01). Pure: callers
// pass `now` in seconds.

/// Categories the user chose to hide (PRD Definitions). Everyone = all persons including Unknown.
public enum HiddenSet: Hashable, Sendable, Codable, CaseIterable {
    case women, men, everyone
}

public enum ProtectionState: Hashable, Sendable {
    case active
    /// Auto-resumes: behaves as `.active` once `until` (seconds, same clock as `now`) has passed.
    case paused(until: Double)
    case disabled
}

public enum Health: Hashable, Sendable {
    case ok, needsPermission, degraded
}

/// How a cover behaves: the resolved `RuleMode` of the track's app (see `Rules`). Off apps get no cover, and are never
/// captured to begin with.
public enum CoverMode: Hashable, Sendable, Codable {
    case blur, curtain
}

/// One rectangle to cover. `trackID` keys the overlay layer; when overlapping covers merge it is the lowest id of the group.
public struct Cover: Hashable, Sendable {
    public var trackID: Int
    public var rect: Rect
    public var mode: CoverMode

    public init(trackID: Int, rect: Rect, mode: CoverMode) {
        self.trackID = trackID
        self.rect = rect
        self.mode = mode
    }
}

public struct Policy: Hashable, Sendable {
    public var hiddenSet: HiddenSet
    /// "Blur Unknown". Read `effectiveStrict`: Everyone forces it on.
    public var strictMode: Bool
    public var protection: ProtectionState
    public var health: Health
    public var rules: Rules

    public init(
        hiddenSet: HiddenSet, strictMode: Bool = true, protection: ProtectionState = .active, health: Health = .ok,
        rules: Rules = Rules()
    ) {
        self.hiddenSet = hiddenSet
        self.strictMode = strictMode
        self.protection = protection
        self.health = health
        self.rules = rules
    }

    /// Strict Mode as applied: forced on when Everyone is selected (the UI shows it on and disabled).
    public var effectiveStrict: Bool { hiddenSet == .everyone || strictMode }

    /// Processing follows the user's switch, even while capture is recovering from a lost grant.
    public func processingEnabled(at now: Double) -> Bool {
        switch protection {
        case .active: true
        case .paused(let until): until <= now
        case .disabled: false
        }
    }

    /// True while covers are produced: protection active (or a pause that has elapsed) and capture permitted.
    /// Blur mode fails open (PRD FR10): without Screen Recording permission nothing is covered.
    public func isProtecting(at now: Double) -> Bool {
        guard health != .needsPermission else { return false }
        return processingEnabled(at: now)
    }

    /// Whether a person of `category` belongs to the hidden set (Unknown only under `effectiveStrict`).
    public func hides(_ category: Category) -> Bool {
        switch hiddenSet {
        case .everyone: return true
        case .women: return category == .woman || (category == .unknown && effectiveStrict)
        case .men: return category == .man || (category == .unknown && effectiveStrict)
        }
    }

    /// Covers for this frame: one per hidden track whose app resolves to Blur or Curtain (`rules.mode(for:)`; a track
    /// without a bundle ID takes the Default Rule), overlapping hidden tracks of one mode merged into one (see
    /// `Tracker.merged`), ascending by `trackID`. Empty when paused (until > now), disabled, or without permission.
    public func covers(for tracks: [Track], now: Double) -> [Cover] {
        guard isProtecting(at: now) else { return [] }
        return [CoverMode.blur, .curtain].flatMap { mode in
            Tracker.merged(tracks.filter { hides($0.category) && rules.mode(for: $0.bundleID).coverMode == mode })
                .map { Cover(trackID: $0.id, rect: $0.rect, mode: mode) }
        }.sorted { $0.trackID < $1.trackID }
    }
}
