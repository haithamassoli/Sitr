// Curtain state machine (M3-T04, PRD FR4) for one Curtain-mode app. Pure: the pipeline passes frame sequence numbers
// and seconds; window ids and rects (display points) come from the window tracker.
//
// Per frame the caller runs `dirty(rects:seq:now:)` as soon as the frame arrives and commits `preCovers()` before
// detection, then `verified(seq:hiddenRects:now:)` once detection for that frame produced Policy's person covers.
// Pre-covers only ever add to the person covers: a tile under a hidden person stays pre-covered, the person cover does
// the rest.

public struct Curtain: Sendable {
    /// Tile side in display points; pre-covers are unions of tiles, so they overshoot a dirty rect by up to one tile.
    // ponytail: fixed 64 pt (a 2560×1664 window is 40×26 tiles); upgrade path: 32 pt if the overshoot around
    // scrolling text is visibly coarse.
    public static let tileSize: Double = 64
    /// Longest gap between two dirty events that still counts as continuous motion.
    public static let motionGap: Double = 0.2
    /// Continuous motion verified safe for this long → trusted motion (Blur behaviour, no pre-cover).
    public static let trustAfter: Double = 0.5
    /// No dirty event for this long ends trusted motion.
    public static let staticReset: Double = 1.0

    /// Tile value meaning "not pre-covered"; anything else is the seq of the frame that pre-covered the tile.
    static let clear = Int.min

    struct Window: Sendable {
        var rect: Rect
        var columns: Int
        var rows: Int
        /// Row-major tile grid: `Curtain.clear` or the pre-covering frame seq.
        var tiles: [Int]
        /// Time of the last dirty event (window change or dirty rect).
        var lastDirty: Double
        /// First frame seq of the current continuous-motion run; only frames from the run vouch for its content.
        var runSeq: Int
        /// When the current run was first verified safe; nil until then and after any hidden person.
        var safeSince: Double?
        var trusted = false
    }

    private(set) var windows: [Int: Window] = [:]
    /// Highest frame seq seen; a window that appears now is pre-covered as of the next frame.
    private var lastSeq = -1

    public init() {}

    /// Window tracker update; call on every poll, an unchanged rect is a no-op. A new window or a new size pre-covers
    /// every tile as of the next frame until that frame is verified; a move keeps tiles and trust (same content).
    public mutating func windowChanged(id: Int, rect: Rect, now: Double) {
        if var window = windows[id], window.rect.width == rect.width, window.rect.height == rect.height {
            window.rect = rect
            windows[id] = window
            return
        }
        let columns = max(0, Int((rect.width / Self.tileSize).rounded(.up)))
        let rows = max(0, Int((rect.height / Self.tileSize).rounded(.up)))
        windows[id] = Window(
            rect: rect, columns: columns, rows: rows, tiles: Array(repeating: lastSeq + 1, count: columns * rows),
            lastDirty: now, runSeq: lastSeq + 1)
    }

    /// Window gone: its pre-covers go with it.
    public mutating func windowClosed(id: Int) {
        windows[id] = nil
    }

    /// A frame arrived: every tile under a dirty rect is pre-covered as of `seq`, except in windows in trusted motion.
    /// Call for every frame, with empty `rects` when nothing changed, so the seq bookkeeping stays current; windows no
    /// rect overlaps are untouched (a frame in which a window did not change is not motion for it).
    public mutating func dirty(rects: [Rect], seq: Int, now: Double) {
        lastSeq = max(lastSeq, seq)
        for (id, var window) in windows {
            let spans = rects.compactMap { window.span(of: $0) }
            guard !spans.isEmpty else { continue }
            if now - window.lastDirty > Self.motionGap {  // run broken (or first ever): a new run starts here
                if now - window.lastDirty >= Self.staticReset { window.trusted = false }
                window.runSeq = seq
                window.safeSince = nil
            }
            window.lastDirty = now
            if !window.trusted {
                for span in spans {
                    for row in span.rows {
                        for column in span.columns {
                            let i = row * window.columns + column
                            window.tiles[i] = max(window.tiles[i], seq)
                        }
                    }
                }
            }
            windows[id] = window
        }
    }

    /// Detection finished for frame `seq` and Policy produced `hiddenRects` (its person covers, display points).
    /// A tile pre-covered as of `seq` or earlier clears unless a hidden rect overlaps it; tiles dirtied by a later
    /// frame stay covered whatever this frame says. A window verified safe (no hidden rect overlaps it) throughout
    /// `trustAfter` of continuous motion becomes trusted; a hidden person restarts that clock but does not end an
    /// existing trust (that would re-curtain a whole video around one covered person; only `staticReset` ends it).
    public mutating func verified(seq: Int, hiddenRects: [Rect], now: Double) {
        lastSeq = max(lastSeq, seq)
        for (id, var window) in windows {
            let hidden = hiddenRects.compactMap { window.span(of: $0) }
            for i in window.tiles.indices where window.tiles[i] != Self.clear && window.tiles[i] <= seq {
                let row = i / window.columns, column = i % window.columns
                if !hidden.contains(where: { $0.rows.contains(row) && $0.columns.contains(column) }) {
                    window.tiles[i] = Self.clear
                }
            }
            if !hidden.isEmpty {
                window.safeSince = nil
            } else if seq >= window.runSeq {
                let safeSince = window.safeSince ?? now
                window.safeSince = safeSince
                if now - safeSince >= Self.trustAfter, now - window.lastDirty <= Self.motionGap {
                    window.trusted = true
                }
            }
            windows[id] = window
        }
    }

    /// Pre-covered area: one rect per run of covered tiles along a row, equal runs on consecutive rows stacked into
    /// one, clipped to the window. Windows in ascending id order.
    // ponytail: run stacking only; upgrade path: maximal-rectangle decomposition if layer counts hurt commit time.
    public func preCovers() -> [Rect] {
        var rects: [Rect] = []
        for window in windows.sorted(by: { $0.key < $1.key }).map(\.value) {
            var runs: [Rect] = []
            for row in 0..<window.rows {
                var column = 0
                while column < window.columns {
                    let start = column
                    while column < window.columns, window.tiles[row * window.columns + column] != Self.clear {
                        column += 1
                    }
                    if column > start { runs.append(window.tileRect(columns: start..<column, row: row)) }
                    column += 1
                }
            }
            var stacked: [Rect] = []
            for run in runs.sorted(by: { ($0.x, $0.width, $0.y) < ($1.x, $1.width, $1.y) }) {
                if let last = stacked.last, last.x == run.x, last.width == run.width, last.maxY == run.y {
                    stacked[stacked.count - 1].height += run.height
                } else {
                    stacked.append(run)
                }
            }
            rects += stacked
        }
        return rects
    }

    /// Whether the window is in trusted motion. Event-driven: the `staticReset` applies on the window's next dirty
    /// event.
    public func isTrusted(window id: Int) -> Bool {
        windows[id]?.trusted ?? false
    }
}

extension Curtain.Window {
    /// Tile columns and rows whose area overlaps `rect`; nil when it misses the window (touching edges do not count).
    func span(of rect: Rect) -> (columns: ClosedRange<Int>, rows: ClosedRange<Int>)? {
        let x0 = max(rect.minX, self.rect.minX), x1 = min(rect.maxX, self.rect.maxX)
        let y0 = max(rect.minY, self.rect.minY), y1 = min(rect.maxY, self.rect.maxY)
        guard x1 > x0, y1 > y0 else { return nil }
        let t = Curtain.tileSize
        let c0 = Int((x0 - self.rect.minX) / t), c1 = min(columns, Int(((x1 - self.rect.minX) / t).rounded(.up))) - 1
        let r0 = Int((y0 - self.rect.minY) / t), r1 = min(rows, Int(((y1 - self.rect.minY) / t).rounded(.up))) - 1
        return (c0...c1, r0...r1)
    }

    /// Display rect of the tiles `columns` × `row`, clipped to the window.
    func tileRect(columns: Range<Int>, row: Int) -> Rect {
        let t = Curtain.tileSize
        let x = rect.minX + Double(columns.lowerBound) * t, y = rect.minY + Double(row) * t
        return Rect(
            x: x, y: y,
            width: min(rect.maxX, rect.minX + Double(columns.upperBound) * t) - x,
            height: min(rect.maxY, y + t) - y)
    }
}
