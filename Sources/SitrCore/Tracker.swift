// Frame-to-frame tracking of classified persons (M2-T08). Pure: the pipeline passes frame timestamps in seconds.
// Goal per PRD FR2: no flicker. Boxes are EMA-smoothed, persist briefly through dropouts, and categories are sticky.

/// One classified person in a frame, in display points.
public struct Observation: Hashable, Sendable {
    public var rect: Rect
    public var category: Category
    /// Classifier P(woman) when it ran; carried for the bench and debug counts, not used by the tracker.
    public var pWoman: Double?

    public init(rect: Rect, category: Category, pWoman: Double? = nil) {
        self.rect = rect
        self.category = category
        self.pWoman = pWoman
    }
}

/// A person followed across frames. `id` is stable for the life of the track and keys overlay layers.
public struct Track: Hashable, Sendable, Identifiable {
    public let id: Int
    /// EMA-smoothed box in display points.
    public var rect: Rect
    public var category: Category
    /// Frame timestamp (seconds) of the last matched observation.
    public var lastSeen: Double
    /// Number of matched observations, including the one that created the track.
    public var hits: Int
    /// Category the recent observations disagree with `category` on, and how many in a row said so.
    var contrary: Category?
    var contraryHits = 0

    public init(id: Int, rect: Rect, category: Category, lastSeen: Double, hits: Int = 1) {
        self.id = id
        self.rect = rect
        self.category = category
        self.lastSeen = lastSeen
        self.hits = hits
    }

    mutating func hit(_ observation: Observation, at now: Double) {
        rect = rect.blended(toward: observation.rect, alpha: Tracker.smoothing)
        lastSeen = now
        hits += 1
        if observation.category == category {
            contrary = nil
            contraryHits = 0
        } else if observation.category == contrary {
            contraryHits += 1
            if contraryHits >= Tracker.flipFrames {
                category = observation.category
                contrary = nil
                contraryHits = 0
            }
        } else {
            contrary = observation.category
            contraryHits = 1
        }
    }
}

public struct Tracker: Sendable {
    /// Minimum IoU between a track's smoothed box and an observation to count as the same person.
    public static let matchIoU: Double = 0.3
    /// EMA weight of the newest observation.
    public static let smoothing: Double = 0.5
    /// Seconds an unmatched track survives after its last hit.
    public static let persistence: Double = 0.3
    /// Consecutive observations of one other category needed to flip a track's category.
    public static let flipFrames = 3

    public private(set) var tracks: [Track] = []
    private var nextID = 1
    private var lastSequence = Int.min

    public init() {}

    /// Feed one frame's observations. `now` is the frame timestamp in seconds; `sequence` is the frame's sequence
    /// number and frames arriving out of order (sequence not above the last one processed) are ignored.
    /// Returns the tracks after the update.
    // ponytail: no motion model — the EMA lags one step behind steady motion, so a person moving faster than ~27 % of
    // their box width per frame (~4 body widths/s at 15 fps) drops below IoU 0.3 and gets a new id (cover appears
    // anyway, only the layer key changes); upgrade path: constant-velocity prediction of `rect` before matching.
    @discardableResult
    public mutating func update(_ observations: [Observation], at now: Double, sequence: Int) -> [Track] {
        guard sequence > lastSequence else { return tracks }
        lastSequence = sequence
        tracks.removeAll { now - $0.lastSeen > Self.persistence }

        // Greedy one-to-one matching, best IoU first.
        var pairs: [(iou: Double, track: Int, observation: Int)] = []
        for (t, track) in tracks.enumerated() {
            for (o, observation) in observations.enumerated() {
                let iou = track.rect.iou(observation.rect)
                if iou >= Self.matchIoU { pairs.append((iou, t, o)) }
            }
        }
        pairs.sort { $0.iou > $1.iou }
        var matchedTracks = Set<Int>(), matchedObservations = Set<Int>()
        for pair in pairs where !matchedTracks.contains(pair.track) && !matchedObservations.contains(pair.observation) {
            matchedTracks.insert(pair.track)
            matchedObservations.insert(pair.observation)
            tracks[pair.track].hit(observations[pair.observation], at: now)
        }
        for (o, observation) in observations.enumerated() where !matchedObservations.contains(o) {
            tracks.append(Track(id: nextID, rect: observation.rect, category: observation.category, lastSeen: now))
            nextID += 1
        }
        return tracks
    }

    /// Collapses each group of mutually overlapping tracks (transitively) into one track carrying the lowest id and
    /// the union of their boxes; the rest pass through unchanged. Touching edges do not count as overlap.
    /// Policy applies this to the hidden tracks so overlapping people get one cover.
    public static func merged(_ tracks: [Track]) -> [Track] {
        var groups = tracks.sorted { $0.id < $1.id }
        var didMerge = true
        while didMerge {
            didMerge = false
            search: for i in groups.indices {
                for j in groups.indices where j > i && groups[i].rect.intersection(groups[j].rect).area > 0 {
                    groups[i].rect = groups[i].rect.union(groups[j].rect)
                    groups.remove(at: j)
                    didMerge = true
                    break search
                }
            }
        }
        return groups
    }
}

extension Rect {
    /// Smallest rect containing both.
    // ponytail: belongs in Geometry.swift, which this task does not own; move when that file is next touched.
    func union(_ other: Rect) -> Rect {
        let x0 = min(minX, other.minX), y0 = min(minY, other.minY)
        return Rect(x: x0, y: y0, width: max(maxX, other.maxX) - x0, height: max(maxY, other.maxY) - y0)
    }

    /// Exponential moving average step: each component moves `alpha` of the way toward `target`.
    func blended(toward target: Rect, alpha: Double) -> Rect {
        Rect(
            x: x + (target.x - x) * alpha,
            y: y + (target.y - y) * alpha,
            width: width + (target.width - width) * alpha,
            height: height + (target.height - height) * alpha)
    }
}
