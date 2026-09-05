// Who gets covered, and whether anything gets covered right now (M2-T09). Pure: callers pass `now` in seconds.

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

/// Per-app mode. Off apps are never captured, so they never reach Policy.
public enum CoverMode: Hashable, Sendable, Codable {
    case blur, curtain
}

/// App rules. Default Rule is Blur throughout M2.
// ponytail: carries only the Default Rule; M3-T01 adds `AppRule { bundleID, mode }` overrides and per-bundle resolution.
public struct Rules: Hashable, Sendable, Codable {
    public var defaultMode: CoverMode

    public init(defaultMode: CoverMode = .blur) {
        self.defaultMode = defaultMode
    }
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

    /// True while covers are produced: protection active (or a pause that has elapsed) and capture permitted.
    /// Blur mode fails open (PRD FR10): without Screen Recording permission nothing is covered.
    public func isProtecting(at now: Double) -> Bool {
        guard health != .needsPermission else { return false }
        switch protection {
        case .active: return true
        case .paused(let until): return until <= now
        case .disabled: return false
        }
    }

    /// Whether a person of `category` belongs to the hidden set (Unknown only under `effectiveStrict`).
    public func hides(_ category: Category) -> Bool {
        switch hiddenSet {
        case .everyone: return true
        case .women: return category == .woman || (category == .unknown && effectiveStrict)
        case .men: return category == .man || (category == .unknown && effectiveStrict)
        }
    }

    /// Covers for this frame: one per hidden track, overlapping hidden tracks merged into one (see `Tracker.merged`).
    /// Empty when paused (until > now), disabled, or without permission.
    public func covers(for tracks: [Track], now: Double) -> [Cover] {
        guard isProtecting(at: now) else { return [] }
        return Tracker.merged(tracks.filter { hides($0.category) })
            .map { Cover(trackID: $0.id, rect: $0.rect, mode: rules.defaultMode) }
    }
}
