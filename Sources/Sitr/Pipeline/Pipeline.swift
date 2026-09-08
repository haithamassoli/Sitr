// M2-T12: one Pipeline per display. Frame → Curtain fast path (M3-T05: dirty rects ∩ Curtain windows → pre-covers on screen before
// detection) → detect persons + faces → assign faces → classify (≤ 3 faces) → categorize → attribute to the topmost window →
// track → policy → render → verify Curtain tiles → commit. Backpressure is the capture stream's `.bufferingNewest(1)`: while one
// detection is in flight, newer frames replace the single buffered frame, so intermediate frames are skipped and nothing ever
// queues. The pipeline is the panel's only writer: person covers, pre-covers and the Runtime's fail-closed covers (M3-T06) are
// merged here in one apply. Metrics are timings and counts only (`SITR_METRICS=1` prints them every 5 s); no pixel leaves memory.
import CoreGraphics
import CoreVideo
import Foundation
import QuartzCore
import SitrCore
// Scoped import: the ObjC runtime's `Category` typedef (via Foundation) would otherwise make the bare name ambiguous here.
import enum SitrCore.Category
import SitrDetect
import Synchronization

/// Person boxes in capture pixels (top-left origin) for one frame. `CoreMLPersonDetector` (YOLOX, M2-T06) in the app; Vision as the fallback.
nonisolated protocol PersonDetecting: Sendable {
    func detect(in frame: Frame) async throws -> [Detection]
}

/// P(woman) per face, index-aligned; nil where the classifier cannot say (no model, model error) → `.unknown`.
nonisolated protocol GenderClassifying: Sendable {
    /// `faces` in capture pixels of `frame`; the implementation crops with its own margin (PRD FR2: 20 %).
    func pWoman(faces: [Rect], in frame: Frame) async -> [Double?]
}

/// M2-T06: the YOLOX-s 1280x768 CoreML detector (85 % recall on the benchmark set against Vision's 38 %; docs/spike/detect.md).
nonisolated extension CoreMLPersonDetector: PersonDetecting {
    func detect(in frame: Frame) async throws -> [Detection] { try await detect(in: frame.pixelBuffer) }
}

/// M2-T07: the ViT face-gender model. A failed prediction yields nil for every face of the call → `.unknown` (covered under Strict).
nonisolated extension GenderClassifier: GenderClassifying {
    func pWoman(faces: [Rect], in frame: Frame) async -> [Double?] {
        (try? pWoman(faces: faces, in: frame.pixelBuffer))?.map { $0 as Double? } ?? faces.map { _ in nil }
    }
}

/// Vision full-body ∪ upper-body boxes, deduplicated (the M1-T06 union: 37.8 % recall on the benchmark set). The fallback when the
/// CoreML model is missing or fails to load.
// ponytail: two Vision handler runs per frame (full and upper body concurrently; faces make a third in the pipeline) instead
// of one shared handler, because SitrDetect keeps its requests internal. Fallback only, so the extra handler run is not worth an API change.
nonisolated struct VisionPersonDetector: PersonDetecting {
    private let full = PersonDetector()
    private let upper = PersonDetector(upperBodyOnly: true)

    func detect(in frame: Frame) async throws -> [Detection] {
        async let a = full.detect(in: frame.pixelBuffer)
        async let b = upper.detect(in: frame.pixelBuffer)
        return dedupe(try await a + b)
    }
}

/// No model: every person is `.unknown`, which Everyone / Strict covers. The fallback when the classifier fails to load.
nonisolated struct NoClassifier: GenderClassifying {
    func pWoman(faces: [Rect], in frame: Frame) async -> [Double?] { faces.map { _ in nil } }
}

/// Drops boxes that repeat a kept box: IoU ≥ `iou` with it, or ≥ 80 % of their own area inside it (an upper-body box within
/// its full-body box adds nothing to the cover). Larger, then more confident boxes are kept first.
nonisolated func dedupe(_ boxes: [Detection], iou: Double = 0.5) -> [Detection] {
    var kept: [Detection] = []
    for d in boxes.sorted(by: { ($0.box.area, $0.confidence) > ($1.box.area, $1.confidence) })
    where !kept.contains(where: { $0.box.iou(d.box) >= iou || $0.box.intersection(d.box).area >= 0.8 * d.box.area }) {
        kept.append(d)
    }
    return kept
}

/// PRD FR2: each face goes to the person box it overlaps most; a person with several faces keeps the largest.
/// Index-aligned with `persons`; nil where no face landed.
nonisolated func assignFaces(_ faces: [Detection], to persons: [Detection]) -> [Detection?] {
    var assigned = [Detection?](repeating: nil, count: persons.count)
    for face in faces {
        let overlaps = persons.map { $0.box.intersection(face.box).area }
        guard let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }), overlaps[best] > 0 else { continue }
        if assigned[best].map({ $0.box.area < face.box.area }) ?? true { assigned[best] = face }
    }
    return assigned
}

/// Whether the category rule can say anything for this person: a face whose short side is ≥ 32 px on a body ≥ 40 px tall
/// (capture pixels). `categorize` returns `.unknown` otherwise, so the classifier is not run.
nonisolated func classifiable(face: Detection?, body: Detection) -> Bool {
    guard let face else { return false }
    return min(face.box.width, face.box.height) >= Category.minFaceSide && body.box.height >= Category.minBodyHeight
}

/// Indices of the persons to classify this frame, at most `limit`: classifiable persons that are new (`sticky` nil: no track
/// matches) or on an `.unknown` track first, then the ones whose track's answer is stale; each group rotated by `round` so
/// nobody starves. `fresh[i]` = this person's track was classified inside `Pipeline.classifyRefresh` and is skipped entirely
/// (an absent or short `fresh` means nothing is fresh, the pre-M4-T09 behaviour). The Tracker keeps categories sticky, so a
/// person skipped this frame keeps last frame's answer.
// M4-T09: re-classifying every settled track on every frame was the single most expensive thing the app did — 2.0 s of thread
// time in a 30 s browsing profile, more than the person detector, and much of it BNNS *CPU* inference because parts of the int8
// ViT do not fit the ANE. A settled track is now re-checked once a second (`classifyRefresh`), which is what the 3-crop cap
// below used to buy on a busy screen and does not on a quiet one.
// ponytail: 3 crops per frame still caps the worst case, so ten new faces cost the same as three. The cost of the slower
// refresh: a track whose *person* changes without the box moving keeps the old category for up to `classifyRefresh` ×
// `Tracker.flipFrames` ≈ 3 s (it was ~0.6 s). Upgrade path: the ≤ 10 MB MobileNetV3 of docs/spike/classifier.md, which is
// cheap enough to run on every track every frame.
nonisolated func classificationOrder(classifiable: [Bool], sticky: [Category?], fresh: [Bool] = [], round: Int, limit: Int = 3) -> [Int] {
    func rotated(_ v: [Int]) -> [Int] { v.isEmpty ? v : Array(v[(round % v.count)...] + v[..<(round % v.count)]) }
    func isFresh(_ i: Int) -> Bool { i < fresh.count && fresh[i] }
    let eligible = classifiable.indices.filter { classifiable[$0] }
    let urgent = eligible.filter { sticky[$0] == nil || sticky[$0] == .unknown }
    let stale = eligible.filter { !urgent.contains($0) && !isFresh($0) }
    return Array((rotated(urgent) + rotated(stale)).prefix(limit))
}

/// M4-T09 dev switch: `SITR_PERF_LEGACY=1` restores the pre-M4-T09 per-frame behaviour — classify every classifiable track on
/// every frame, re-render every cover from every frame one GPU round trip at a time, never skip detection. The same binary then
/// measures before and after minutes apart, which is the only way to compare on a machine whose own load moves between runs
/// (`docs/perf.md`). Read once.
// ponytail: an environment switch rather than a second build, like `SITR_FPS` / `SITR_CAPTURE_SIDE`; nothing in the product
// reads it and `scripts/measure-system.sh` passes it through. Upgrade path: delete it once the numbers are re-taken on M1 8 GB.
nonisolated let perfLegacy = ProcessInfo.processInfo.environment["SITR_PERF_LEGACY"] == "1"

/// Whether this frame's changed regions rule out any change to the people on screen: every changed region is shorter than a
/// detectable body (`Category.minBodyHeight`, 40 capture px — a body cannot appear inside a region too small to hold one) and
/// none of them touches a box already being tracked (so nobody tracked moved, shrank or left). A frame like that is dropped
/// before detection: the covers that are up stay up and stay correct. A frame with no changed regions at all says nothing —
/// the answer is `false` — and so does one with no tracks yet.
// M4-T09, first item of the spike report's fix list. Pure; unit-tested. Rects are in capture pixels, tracks in display points.
nonisolated func nothingDetectableChanged(dirtyRects: [CGRect], pixelsPerPoint: Double, tracks: [CGRect],
                                          minBody: Double = Category.minBodyHeight, hasCurtain: Bool = false) -> Bool {
    // Curtain pre-covers have already been applied; skipping verification would leave them on screen.
    guard !hasCurtain, !dirtyRects.isEmpty, dirtyRects.allSatisfy({ $0.height < minBody && $0.width < minBody }) else { return false }
    let k = pixelsPerPoint > 0 ? pixelsPerPoint : 1
    return !tracks.contains { track in
        let box = CGRect(x: track.minX * k, y: track.minY * k, width: track.width * k, height: track.height * k)
        return dirtyRects.contains { $0.intersects(box) }
    }
}

/// Whether this frame's faces have to be looked for: any detected person that no track matches (someone new), or whose track
/// is `.unknown` or has no classifier answer newer than `refresh`. Faces feed nothing else — `classifiable` gates the
/// classifier and `categorize` reads the face size — so when every person here already has a fresh answer, the face request is
/// work whose result cannot change a cover. Pure; unit-tested. `persons` in display points, like `Track.rect`.
// M4-T09: `DetectFaceRectanglesRequest` was ~1.6 s of a 30 s browsing profile on its own Vision queue. Skipping it costs the
// overlap it used to have with the person detector on the frames that still need it (they now run one after the other), which
// is the price of never guessing about a face that could change a category.
nonisolated func needsFaces(persons: [Rect], tracks: [Track], classifiedAt: [Int: Double], now: Double, refresh: Double,
                            hiddenSet: HiddenSet = .women) -> Bool {
    guard hiddenSet != .everyone else { return false }
    return persons.contains { p in
        guard let track = tracks.filter({ $0.rect.iou(p) >= Tracker.matchIoU }).max(by: { $0.rect.iou(p) < $1.rect.iou(p) }) else { return true }
        return track.category == .unknown || classifiedAt[track.id].map { now - $0 >= refresh } ?? true
    }
}

/// Whether a cover can show the previous frame's pixels: its padded rect moved less than `tolerance` points and nothing the
/// frame reports as changed overlaps it. The blur reads exactly the padded rect (`CoverRenderer.prepare` crops to it), so
/// unchanged source pixels there give a pixel-identical cover. Pure; unit-tested.
// M4-T09: rendering every cover from every frame was 1.2 s of thread time in a 30 s browsing profile with two covers up, and
// scales with the cover count (the spike measured render at 25–40 % of the frame with seven). Callers pass `dirty: nil` (never
// reuse) whenever the changed regions are not knowable — a sequence gap, an appearance change, a resize — and `dirty: []` when
// they are knowable but untrustworthy, which is any frame after a commit of ours (see `Pipeline.ownDamage`).
// `tolerance` is one capture pixel of slack (1.15 pt on a 1470 pt display captured at 1280 px): the tracker's EMA converges on
// a still person but never exactly, and half a pixel of lag under a cover that is padded by 15 % of the body is not visible.
nonisolated func coverCanReuse(cached: CGRect, cover: CGRect, dirty: [CGRect]?, tolerance: Double = 1.5) -> Bool {
    guard let dirty else { return false }
    guard abs(cached.minX - cover.minX) <= tolerance, abs(cached.minY - cover.minY) <= tolerance,
          abs(cached.width - cover.width) <= tolerance, abs(cached.height - cover.height) <= tolerance
    else { return false }
    let probe = cached.insetBy(dx: -tolerance, dy: -tolerance)
    return !dirty.contains { $0.intersects(probe) }
}

/// Overlay layer ids. Track ids are ≥ 1 (`Tracker.nextID` starts at 1), so everything else lives below zero: pre-covers just under
/// it, fail-closed covers far below (a window id is 32 bits, a piece index 8), and no range ever meets another. Unit-tested.
nonisolated enum CoverID {
    /// Pre-cover `n` of a frame (0-based): -1, -2, …
    static func preCover(_ n: Int) -> Int { -1 - n }
    static let failClosedBase = -(1 << 40)
    /// Fail-closed Solid cover over `piece` of a Curtain window's visible region.
    static func failClosed(window: CGWindowID, piece: Int = 0) -> Int { failClosedBase - (Int(window) << 8 | min(piece, 255)) }
    static func isTrack(_ id: Int) -> Bool { id >= 1 }
    static func isPreCover(_ id: Int) -> Bool { id < 0 && id > failClosedBase }
    static func isFailClosed(_ id: Int) -> Bool { id <= failClosedBase }
}

/// Capture rate for a display: `curtainFPS` while at least one visible Curtain window is on it (the M1-T04 latency numbers:
/// 15 fps capture alone is 72 ms p95, over the 50 ms Curtain target), else the FR1 default.
nonisolated func captureFPS(windows: [WindowRect], rules: Rules, displayID: CGDirectDisplayID, curtainFPS: Int, defaultFPS: Int = 15,
                            cap: Int = .max) -> Int {
    // `cap` is M4-T06's Low Power ceiling: without it Low Power and the Curtain rate would each undo the other's write to `fps`.
    min(windows.contains { $0.displayID == displayID && rules.mode(for: $0.bundleID) == .curtain } ? curtainFPS : defaultFPS, cap)
}

/// M3-T06 fail-closed covers for one display: one Solid spec per visible piece of every Curtain window (clipped to what is not under
/// another window, so a Blur or Off window stacked above stays uncovered). Blur apps get nothing (they fail open, PRD FR10).
nonisolated func failClosedSpecs(windows: [WindowRect], rules: Rules, displayID: CGDirectDisplayID, color: CGColor) -> [CoverLayerSpec] {
    windows.filter { $0.displayID == displayID && rules.mode(for: $0.bundleID) == .curtain }.flatMap { w in
        subtract(w.rect, holes: windows.occluders(of: w)).enumerated().map { i, piece in
            CoverLayerSpec(id: CoverID.failClosed(window: w.windowID, piece: i), frame: piece, contents: nil, color: color)
        }
    }
}

/// Cover look (PRD FR3): style, Blur Strength 0…1 (default 0.7), Body Padding 0…0.5 (default 0.15). `Preferences` persists it.
nonisolated struct CoverAppearance: Sendable, Equatable {
    var style: CoverStyle = .gaussian
    var strength = 0.7
    var padding = 0.15
}

/// Counts since start and stage timings (seconds) for the current metrics window; the window is reset every print (or capped),
/// so nothing grows. Timings and counts only. `classify` is per crop (a frame's classification time ÷ its crops).
nonisolated struct PipelineMetrics: Sendable {
    var framesIn = 0, framesOut = 0, skipped = 0, detections = 0, errors = 0, applies = 0, tracks = 0, layers = 0
    /// Face crops classified since start; current tracks per category.
    var crops = 0, women = 0, men = 0, unknown = 0
    /// M3-T05: pre-cover applies (frames that put pre-covers up before detection), pre-cover layers on screen now, renders that
    /// fell back to Solid over the 5 ms budget, frames whose sequence gap made the whole Curtain window count as dirty.
    var preApplies = 0, preLayers = 0, preSolid = 0, gapCovers = 0
    /// M4-T09 per-frame work: person covers sent to the GPU, person covers that reused the previous frame's pixels
    /// (`coverCanReuse`), and detections skipped because nothing on screen had changed. `renders + reuses` is the cover total.
    var renders = 0, reuses = 0, detectSkips = 0, applySkips = 0, faceSkips = 0
    /// Why a re-render was needed: the source pixels under an unmoved cover changed, or the cover itself moved.
    var reuseBlockedByPixels = 0, reuseBlockedByMove = 0
    var detect: [Double] = [], classify: [Double] = [], track: [Double] = [], render: [Double] = [], commit: [Double] = [], e2e: [Double] = []
    /// Fast path: capture callback → pre-cover commit; pre-cover render time per frame; detection done → pre-cover cleared.
    var fastPath: [Double] = [], preRender: [Double] = [], curtainClear: [Double] = []

    mutating func resetWindow() {
        detect = []
        classify = []
        track = []
        render = []
        commit = []
        e2e = []
        fastPath = []
        preRender = []
        curtainClear = []
    }

    /// Skipped ÷ delivered, over the whole run.
    var skipRatio: Double { framesIn + skipped > 0 ? Double(skipped) / Double(framesIn + skipped) : 0 }

    /// p50/p95 ms of one stage, "-" without samples.
    static func p(_ v: [Double]) -> String { v.isEmpty ? "-" : "\(ms(percentile(v, 0.5)))/\(ms(percentile(v, 0.95)))" }

    func line(display: CGDirectDisplayID, elapsed: Double) -> String {
        "pipeline display=\(display) t=\(Int(elapsed)) in=\(framesIn) out=\(framesOut) skipped=\(skipped) detections=\(detections) "
            + "errors=\(errors) applies=\(applies) detect_ms=\(Self.p(detect)) classify_ms=\(Self.p(classify)) crops=\(crops) "
            + "track_ms=\(Self.p(track)) render_ms=\(Self.p(render)) commit_ms=\(Self.p(commit)) e2e_ms=\(Self.p(e2e)) tracks=\(tracks) "
            + "categories=w\(women)/m\(men)/u\(unknown) layers=\(layers) pre_applies=\(preApplies) pre_layers=\(preLayers) pre_solid=\(preSolid) gap_covers=\(gapCovers) "
            + "renders=\(renders) reuses=\(reuses) reuse_blocked=\(reuseBlockedByPixels)px/\(reuseBlockedByMove)mv detect_skips=\(detectSkips) apply_skips=\(applySkips) face_skips=\(faceSkips) "
            + "fast_ms=\(Self.p(fastPath)) pre_render_ms=\(Self.p(preRender)) clear_ms=\(Self.p(curtainClear)) rss_mb=\(Int(residentMemoryMB())) load1=\(fmt(loadAverage()))"
    }
}

/// Resident set size in MB via `task_info(MACH_TASK_BASIC_INFO)`. `task_self_trap()` stands in for the `mach_task_self_`
/// global, which Swift 6 rejects as shared mutable state.
nonisolated func residentMemoryMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(task_self_trap(), task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : .nan
}

/// The per-display pipeline. Owns the tracker and the per-app `Curtain` state machines; reads the latest `Policy` /
/// `CoverAppearance` / window snapshot per frame; commits covers to the display's `OverlayPanel` on the main actor in one pass.
actor Pipeline {
    /// Pre-cover render budget per frame; past it the remaining pre-covers of the frame are Solid (M3-T05).
    static let preCoverBudget = 0.005
    /// M4-T09: seconds a track's category is trusted before the classifier is asked about it again. New tracks and `.unknown`
    /// tracks are never deferred, so a person appearing is still classified on the frame they are first seen.
    static let classifyRefresh = 1.0

    nonisolated let displayID: CGDirectDisplayID
    private let frames: AsyncStream<Frame>
    private let panel: OverlayPanel
    private let renderer: CoverRenderer
    private var detector: any PersonDetecting
    private let faces = FaceDetector()
    private var classifier: any GenderClassifying

    private nonisolated struct Settings: Sendable {
        var policy: Policy
        var appearance: CoverAppearance
        var revision = 0
    }
    private let settings: Mutex<Settings>
    /// `WindowTracker` snapshot (every display; filtered per use), pushed by the Runtime at ≤ 10 Hz.
    private let windows = Mutex<[WindowRect]>([])
    /// M3-T06 fail-closed covers from the Runtime; merged into every apply so the pipeline stays the panel's only writer.
    private let failClosed = Mutex<[CoverLayerSpec]>([])
    private let commitHook = Mutex<(@MainActor @Sendable ([CoverLayerSpec], Frame, Double) -> Void)?>(nil)
    private let preCoverHook = Mutex<(@MainActor @Sendable ([CoverLayerSpec], Frame, Double) -> Void)?>(nil)

    private var tracker = Tracker()
    /// One Curtain per Curtain-mode app (keyed by bundle id, "" for windows without one) and the window ids each one knows.
    private var curtains: [String: Curtain] = [:]
    private var curtainWindowIDs: [String: Set<Int>] = [:]
    private var personSpecs: [CoverLayerSpec] = []
    private var verifiedFrame: Frame?
    private var preSpecs: [CoverLayerSpec] = []
    /// M4-T09: last frame's rendered cover per track id, reused while the box and the pixels under it hold still
    /// (`coverCanReuse`). Pruned to the covers of the current frame, so it cannot grow and it pins no recycled surface.
    private var coverCache: [Int: CoverLayerSpec] = [:]
    /// The appearance and buffer size `coverCache` was rendered with; a change to either invalidates every entry.
    private var cacheKey: (style: CoverStyle, strength: Double, padding: Double, width: Int, height: Int)?
    /// M4-T09: `CACurrentMediaTime()` of the last classifier answer per track id; pruned to live tracks every frame.
    private var classifiedAt: [Int: Double] = [:]
    /// The last pre-cover pass went over `preCoverBudget`: render the next one Solid (see `preCoverSpecs`).
    private var preCoverOverBudget = false
    private var appliedLayers = 0
    /// The spec list currently on the panel; an identical list is not re-committed (`applyAll`).
    private var appliedSpecs: [CoverLayerSpec] = []
    /// The last `applyAll` committed something, so this frame's `dirtyRects` include our own overlay's damage and say nothing
    /// about the captured pixels. Cleared by the first apply that changes nothing.
    private var ownDamage = false
    private(set) var metrics = PipelineMetrics()
    private var loop: Task<Void, Never>?
    private var printer: Task<Void, Never>?
    private var lastSequence: Int?
    private var round = 0
    private let startedAt = CACurrentMediaTime()

    @MainActor init(
        displayID: CGDirectDisplayID, frames: AsyncStream<Frame>, panel: OverlayPanel, renderer: CoverRenderer,
        policy: Policy, appearance: CoverAppearance,
        detector: any PersonDetecting = VisionPersonDetector(), classifier: any GenderClassifying = NoClassifier()
    ) {
        self.displayID = displayID
        self.frames = frames
        self.panel = panel
        self.renderer = renderer
        self.detector = detector
        self.classifier = classifier
        settings = Mutex(Settings(policy: policy, appearance: appearance))
    }

    func replaceModels(detector: any PersonDetecting, classifier: any GenderClassifying) async {
        settings.withLock { $0.revision &+= 1 }
        self.detector = detector
        self.classifier = classifier
        await clear()
        await warmUp()
    }

    /// Current tracks (display points); the category selftest reads categories from here.
    var tracks: [Track] { tracker.tracks }

    /// Curtain windows in trusted motion right now, by bundle id (the curtain selftest reads `trusted_after_ms` off this).
    var trustedCurtainWindows: [String: [Int]] {
        var out: [String: [Int]] = [:]
        for (key, curtain) in curtains {
            out[key] = (curtainWindowIDs[key] ?? []).filter { curtain.isTrusted(window: $0) }.sorted()
        }
        return out
    }

    /// Dynamic type names of the plug-ins, for the metrics header and the selftests.
    var modelsNote: String {
        "detector=\(String(describing: type(of: detector))) classifier=\(String(describing: type(of: classifier)))"
    }

    /// Latest policy (`AppModel.onPolicyChanged`), used from the next frame on. When it stops protecting (pause, disable,
    /// needs permission) the covers come down right away, frames or not.
    nonisolated func update(_ policy: Policy) {
        let reset = settings.withLock { current in
            let reset = current.policy.rules != policy.rules || current.policy.hiddenSet != policy.hiddenSet
                || current.policy.protection != policy.protection
            current.policy = policy
            current.revision &+= 1
            return reset
        }
        if reset || !policy.isProtecting(at: CACurrentMediaTime()) { Task { await self.clear() } }
    }

    nonisolated func captureStopped() {
        settings.withLock { $0.revision &+= 1 }
        Task { await self.clear() }
    }

    nonisolated func update(_ appearance: CoverAppearance) {
        settings.withLock { $0.appearance = appearance }
    }

    /// Latest `WindowTracker.windows` (all displays). Read at the next frame: attribution, Curtain windows, clipping.
    nonisolated func update(windows: [WindowRect]) {
        self.windows.withLock { $0 = windows }
    }

    /// M3-T06: Solid covers the Runtime wants on screen while capture is down (empty = none). Applied at once when they change,
    /// then carried along with every frame's covers; the first frame after capture resumes replaces them like any other apply.
    nonisolated func update(failClosed specs: [CoverLayerSpec]) {
        let changed = failClosed.withLock { current in
            guard current.map(\.id) != specs.map(\.id) || current.map(\.frame) != specs.map(\.frame) else { return false }
            current = specs
            return true
        }
        if changed { Task { await self.applyAll() } }
    }

    /// Runs on the main actor after every processed frame, once its covers are on screen: every spec applied (person covers,
    /// pre-covers and fail-closed covers — tell them apart with `CoverID`), the frame, and `CACurrentMediaTime()` right after
    /// the commit. Health recovery and the selftests hang off this.
    nonisolated func onCommit(_ hook: (@MainActor @Sendable ([CoverLayerSpec], Frame, Double) -> Void)?) {
        commitHook.withLock { $0 = hook }
    }

    /// Runs on the main actor on every frame arrival, after the Curtain fast path: the frame's pre-cover specs (possibly none)
    /// and the time they were on screen. The curtain selftest measures exposure with it.
    nonisolated func onPreCover(_ hook: (@MainActor @Sendable ([CoverLayerSpec], Frame, Double) -> Void)?) {
        preCoverHook.withLock { $0 = hook }
    }

    /// Consumes the display's frames until `stop()`. Idempotent.
    func start() {
        guard loop == nil else { return }
        loop = Task { await run() }
        if ProcessInfo.processInfo.environment["SITR_METRICS"] == "1" {
            print("pipeline display=\(displayID) \(modelsNote)")
            printer = Task { await printMetrics() }
        }
    }

    /// Stops consuming and removes every cover of this display, fail-closed ones included.
    func stop() async {
        loop?.cancel()
        printer?.cancel()
        loop = nil
        printer = nil
        failClosed.withLock { $0 = [] }
        await clear()
    }

    /// Person covers, pre-covers and Curtain state go; fail-closed covers (if any) stay.
    private func clear() async {
        tracker = Tracker()
        lastSequence = nil
        ownDamage = false
        verifiedFrame = nil
        personSpecs = []
        preSpecs = []
        curtains = [:]
        curtainWindowIDs = [:]
        coverCache = [:]
        classifiedAt = [:]
        await applyAll()
    }

    /// The one apply: person covers + pre-covers + fail-closed covers. An empty set is applied once, then the panel is left alone.
    // M4-T09: a set identical to what is already on screen is not applied at all. The overlay panel is on the display the
    // stream captures, so every commit damages it and SCK answers with a `.complete` frame — an unconditional commit per frame
    // made the pipeline run on its own output at ~3× the rate the screen actually changed (docs/perf.md).
    private func applyAll(ifCurrent: @Sendable () -> Bool = { true }) async {
        let specs = personSpecs + preSpecs + failClosed.withLock { $0 }
        guard !specs.isEmpty || appliedLayers > 0 else { return }
        if !perfLegacy, specs.count == appliedSpecs.count, zip(specs, appliedSpecs).allSatisfy({ $0.matches($1) }) {
            metrics.applySkips += 1
            ownDamage = false
            return
        }
        let applied = await MainActor.run {
            guard ifCurrent() else { return false }
            panel.apply(specs)
            return true
        }
        guard applied else { return }
        appliedSpecs = specs
        appliedLayers = specs.count
        ownDamage = true
        metrics.applies += 1
    }

    /// Feeds the Curtain-mode windows of this display to their app's `Curtain`: new / resized windows are pre-covered until their
    /// first verified frame, moved ones keep their tiles, gone ones are closed, apps without windows are dropped.
    private func syncCurtains(_ curtainWindows: [WindowRect], now: Double) {
        var seen: [String: Set<Int>] = [:]
        for w in curtainWindows {
            let key = w.bundleID ?? ""
            var c = curtains[key] ?? Curtain()
            c.windowChanged(id: Int(w.windowID), rect: Rect(w.rect), now: now)
            curtains[key] = c
            seen[key, default: []].insert(Int(w.windowID))
        }
        for key in curtains.keys {
            guard let ids = seen[key] else {
                curtains[key] = nil
                curtainWindowIDs[key] = nil
                continue
            }
            for id in curtainWindowIDs[key] ?? [] where !ids.contains(id) { curtains[key]?.windowClosed(id: id) }
            curtainWindowIDs[key] = ids
        }
    }

    /// Pre-cover layers for the current Curtain state: each `preCovers()` rect clipped to its window's visible region (M3-T09: never
    /// on a window stacked above it), rendered from this frame in the active style, no padding (tiles already overshoot).
    // ponytail: the budget is enforced across frames — the first overrun is paid once, then pre-covers stay Solid until a frame's
    // pre-cover pass comes back under it (a within-frame check cannot help when one big rect is the whole cost). Upgrade path:
    // downsample the blur for large pre-covers (M4-T09) instead of dropping to Solid.
    private func preCoverSpecs(frame: Frame, appearance a: CoverAppearance, windows snapshot: [WindowRect], curtainWindows: [WindowRect]) -> [CoverLayerSpec] {
        // M4-T09: every piece is submitted to the GPU first and waited for once (`renderer.finish`), so a frame's pre-covers
        // queue together. The budget is still measured on the submit pass — it bounds the graph building, which is what runs
        // before the pre-cover can go up.
        var prepared: [CoverRenderer.Prepared] = []
        let t0 = CACurrentMediaTime()
        for (key, curtain) in curtains.sorted(by: { $0.key < $1.key }) {
            let appWindows = curtainWindows.filter { ($0.bundleID ?? "") == key }
            for rect in curtain.preCovers() {
                let cg = CGRect(rect)
                guard let owner = appWindows.max(by: { $0.rect.intersection(cg).area < $1.rect.intersection(cg).area }) else { continue }
                for piece in subtract(cg, holes: snapshot.occluders(of: owner)) where piece.width >= 1 && piece.height >= 1 {
                    var style = a.style
                    if style != .solid, preCoverOverBudget || CACurrentMediaTime() - t0 > Self.preCoverBudget {
                        style = .solid
                        metrics.preSolid += 1
                    }
                    prepared.append(renderer.prepare(id: CoverID.preCover(prepared.count), style: style, strength: a.strength, padding: 0, rect: piece, frame: frame))
                }
            }
        }
        let specs = renderer.finish(prepared)
        if !specs.isEmpty {
            let spent = CACurrentMediaTime() - t0
            metrics.preRender.append(spent)
            preCoverOverBudget = spent > Self.preCoverBudget
        }
        return specs
    }

    private func run() async {
        let w0 = CACurrentMediaTime()
        await warmUp()
        let warmupMs = Int((CACurrentMediaTime() - w0) * 1000)
        for await frame in frames {
            if Task.isCancelled { return }
            let t0 = CACurrentMediaTime()
            metrics.framesIn += 1
            let gap = lastSequence.map { frame.sequence - $0 - 1 } ?? 0
            if gap > 0 { metrics.skipped += gap }
            lastSequence = frame.sequence
            let current = settings.withLock { $0 }
            guard frame.isCurrent(), current.policy.processingEnabled(at: t0) else { continue }
            let isCurrent: @Sendable () -> Bool = { [self] in
                frame.isCurrent() && self.settings.withLock { $0.revision == current.revision }
            }
            let snapshot = windows.withLock { $0 }
            let trustDirty = !ownDamage  // taken before this frame's own pre-cover commit (see step 4)

            // 0. Curtain fast path (M3-T05, PRD FR4): dirty rects ∩ this display's Curtain windows → pre-covers, on screen before
            //    detection starts. Every frame feeds `dirty` (seq bookkeeping); windows in trusted motion add nothing.
            let rules = current.policy.rules
            let curtainWindows = current.policy.isProtecting(at: t0)
                ? snapshot.filter { $0.displayID == displayID && rules.mode(for: $0.bundleID) == .curtain } : []
            syncCurtains(curtainWindows, now: t0)
            var pre: [CoverLayerSpec] = []
            if !curtains.isEmpty {
                // Compare against the last verified capture, including across dropped frames. Overlay damage
                // is absent from the pixels, so static browser chrome is not repeatedly pre-covered.
                let dirty = frame.changedTiles(since: verifiedFrame).map { frame.pixelsToDisplayPoints(Rect($0)) }
                if gap > 0 { metrics.gapCovers += 1 }
                for key in curtains.keys { curtains[key]?.dirty(rects: dirty, seq: frame.sequence, now: t0) }
                pre = preCoverSpecs(frame: frame, appearance: current.appearance, windows: snapshot, curtainWindows: curtainWindows)
            }
            if !pre.isEmpty || !preSpecs.isEmpty {
                preSpecs = pre
                await applyAll(ifCurrent: isCurrent)
                if !pre.isEmpty {
                    metrics.preApplies += 1
                    metrics.fastPath.append(CACurrentMediaTime() - frame.timestamp)
                }
            }
            guard isCurrent(), !Task.isCancelled else { continue }
            if let hook = preCoverHook.withLock({ $0 }) { await hook(pre, frame, CACurrentMediaTime()) }

            // 1. Persons and faces, concurrently, off this actor and off main (nonisolated async). One frame at a time: the
            //    loop waits here, and the capture stream keeps only the newest frame that arrives meanwhile.
            //    M4-T09: a frame whose changed regions are all too small to hold a body and touch no tracked box cannot have
            //    gained, lost or moved a person, so it skips detection entirely and keeps the covers that are up (the PRD's
            //    "idle user" case: a clock tick or a caret blink used to cost a full pipeline pass).
            if !perfLegacy, !tracker.tracks.isEmpty || !personSpecs.isEmpty, gap == 0,
               nothingDetectableChanged(dirtyRects: frame.dirtyRects, pixelsPerPoint: frame.pixelsPerPoint,
                                        tracks: tracker.tracks.map { CGRect($0.rect) }, hasCurtain: !curtains.isEmpty) {
                metrics.detectSkips += 1
                continue
            }
            // M4-T09: faces are only ever used to decide whether the classifier may run and what `categorize` says, so on a
            // frame where every person already sits on a track with a fresh answer they cost nothing but time. The check needs
            // the person boxes, so on those frames the face request is not started at all and the two no longer overlap; on the
            // frames that do need it (a new or unknown or stale track — every frame where a face could change a cover) the
            // request runs exactly as before, one detector after the other.
            // The tracks standing before this frame answer the same question one frame early, and they are right whenever the
            // set of people did not change: only then can the face request be left out of the concurrent pair without ever
            // losing its overlap with the person detector on the frames that do want it.
            let expectFaces = perfLegacy || needsFaces(persons: tracker.tracks.map(\.rect), tracks: tracker.tracks,
                                                       classifiedAt: classifiedAt, now: t0, refresh: Self.classifyRefresh,
                                                       hiddenSet: current.policy.hiddenSet)
            let persons: [Detection], faceBoxes: [Detection], ranFaces: Bool
            do {
                if expectFaces {
                    async let p = detector.detect(in: frame)
                    async let f = faces.detect(in: frame.pixelBuffer)
                    (persons, faceBoxes) = try await (p, f)
                    ranFaces = true
                } else {
                    persons = try await detector.detect(in: frame)
                    // The prediction missed — somebody new is on screen — so pay for the face request now, after the fact.
                    ranFaces = needsFaces(persons: persons.map { frame.pixelsToDisplayPoints($0.box) }, tracks: tracker.tracks,
                                          classifiedAt: classifiedAt, now: t0, refresh: Self.classifyRefresh,
                                          hiddenSet: current.policy.hiddenSet)
                    faceBoxes = ranFaces ? try await faces.detect(in: frame.pixelBuffer) : []
                    if !ranFaces { metrics.faceSkips += 1 }
                }
                metrics.detections += 1
            } catch {
                // ponytail: a failed detection keeps the previous covers (fail safe) and is counted; M4-T07 turns sustained
                // failures / slowness into `.degraded`.
                metrics.errors += 1
                if isCurrent() { DetectionMeter.shared.recordFailure(display: displayID, at: CACurrentMediaTime()) }
                continue
            }
            guard isCurrent(), !Task.isCancelled else { continue }
            let t1 = CACurrentMediaTime()
            metrics.detect.append(t1 - t0)
            DetectionMeter.shared.record(display: displayID, seconds: t1 - t0, at: t1)  // M4-T07 degraded state

            // 2. Face → person, then at most 3 faces through the classifier: new and unknown tracks first, the rest round-robin;
            //    a person skipped this frame keeps the category of the track it lands on. Category rule; observations in display
            //    points, attributed to the topmost window under the box centre (M3: Policy resolves Blur / Curtain per app).
            let assigned = assignFaces(faceBoxes, to: persons)
            let rects = persons.map { frame.pixelsToDisplayPoints($0.box) }
            let matched = rects.map { r in tracker.tracks.filter { $0.rect.iou(r) >= Tracker.matchIoU }.max { $0.rect.iou(r) < $1.rect.iou(r) } }
            let sticky = matched.map(\.?.category)
            let usable = persons.indices.map { classifiable(face: assigned[$0], body: persons[$0]) }
            // M4-T09: a track the classifier answered for less than `classifyRefresh` ago keeps that answer instead of paying
            // for a crop on every frame.
            let fresh = perfLegacy ? [] : matched.map { m in m.flatMap { classifiedAt[$0.id] }.map { t1 - $0 < Self.classifyRefresh } ?? false }
            let order = classificationOrder(classifiable: usable, sticky: sticky, fresh: fresh, round: round)
            round += 1
            let probabilities = order.isEmpty ? [] : await classifier.pWoman(faces: order.map { assigned[$0]!.box }, in: frame)
            guard isCurrent(), !Task.isCancelled else { continue }
            let t2 = CACurrentMediaTime()
            if !order.isEmpty {
                metrics.classify.append((t2 - t1) / Double(order.count))
                metrics.crops += order.count
                for i in order { if let id = matched[i]?.id { classifiedAt[id] = t2 } }
            }
            var observations: [PersonObservation] = []
            observations.reserveCapacity(persons.count)
            for (i, person) in persons.enumerated() {
                let category: Category
                var p: Double?
                if let k = order.firstIndex(of: i) {
                    p = probabilities[k]
                    category = categorize(
                        face: assigned[i].map { Size(width: $0.box.width, height: $0.box.height) },
                        body: Size(width: person.box.width, height: person.box.height), pWoman: p)
                } else if !ranFaces {
                    // M4-T09: faces were not looked for on this frame, which only happens when every person here already has a
                    // fresh answer on a track. `usable` is false for want of a face, not for want of a classifiable one, so the
                    // rule must not turn them all into Unknown — they keep the track's category, exactly as a person capped out
                    // by the 3-crop limit does. A person with no track is new, which is what `needsFaces` refuses to skip.
                    category = sticky[i] ?? .unknown
                } else {
                    category = usable[i] ? (sticky[i] ?? .unknown) : .unknown  // capped out this frame, or nothing to classify (rule → Unknown)
                }
                let owner = snapshot.topmost(at: CGPoint(x: rects[i].midX, y: rects[i].midY), on: displayID)?.bundleID
                observations.append(PersonObservation(rect: rects[i], category: category, pWoman: p, bundleID: owner,
                                                      categoryVerified: ranFaces && (!usable[i] || order.contains(i))))
            }

            // 3. Track, then policy (merges overlapping hidden tracks itself).
            let now = CACurrentMediaTime()
            let tracks = tracker.update(observations, at: now, sequence: frame.sequence)
            let covers = current.policy.covers(for: tracks, now: now)
            let t3 = CACurrentMediaTime()
            metrics.track.append(t3 - t2)
            classifiedAt = classifiedAt.filter { id, _ in tracks.contains { $0.id == id } }

            // 4. Render one layer per cover from this frame's pixels — except the covers whose box and source pixels are the
            //    ones the previous frame already rendered (M4-T09), which keep their surface.
            let a = current.appearance
            let key = (a.style, a.strength, a.padding, frame.width, frame.height)
            if cacheKey.map({ $0 != key }) ?? true {
                coverCache = [:]
                cacheKey = key
            }
            // The changed regions are unknowable across a sequence gap (SCK reports them against the previous frame it
            // *emitted*, and the drop-oldest stream threw those away), so a gap re-renders everything.
            // Our overlay is on the display this stream captures. A commit of ours damages it, SCK answers with a `.complete`
            // frame, and that frame's `dirtyRects` are our own covers — not a change to the pixels we blur. Trusting them made
            // the app re-render and re-commit on its own output: the browsing scenario ran at 12.4 processed fps while the
            // screen changed 3.5 times a second, at 29 % of a core instead of 7 % (docs/perf.md). So the changed regions are
            // used only on a frame that follows a commit of *nothing*; after a real commit the covers may only be reused
            // because they did not move, which is exactly the case that ends the cycle.
            let dirty = gap > 0 || perfLegacy ? nil : (trustDirty ? frame.dirtyRectsInDisplayPoints : [])
            var prepared: [CoverRenderer.Prepared?] = []
            for cover in covers {
                let padded = CoverGeometry.padded(CGRect(cover.rect), padding: a.padding, display: frame.displaySize)
                if let cached = coverCache[cover.trackID], coverCanReuse(cached: cached.frame, cover: padded, dirty: dirty) {
                    prepared.append(nil)
                    metrics.reuses += 1
                    continue
                }
                let p = renderer.prepare(id: cover.trackID, style: a.style, strength: a.strength, padding: a.padding,
                                         rect: CGRect(cover.rect), frame: frame)
                prepared.append(perfLegacy ? CoverRenderer.Prepared(spec: renderer.finish([p])[0], solid: p.solid, task: nil) : p)
                metrics.renders += 1
                if let cached = coverCache[cover.trackID] {
                    if coverCanReuse(cached: cached.frame, cover: padded, dirty: []) { metrics.reuseBlockedByPixels += 1 } else { metrics.reuseBlockedByMove += 1 }
                }
            }
            let rendered = renderer.finish(prepared.compactMap { $0 })
            var next = rendered.makeIterator()
            let specs = zip(covers, prepared).map { cover, p in p == nil ? coverCache[cover.trackID]! : next.next()! }
            coverCache = Dictionary(zip(covers.map(\.trackID), specs), uniquingKeysWith: { _, last in last })
            let t4 = CACurrentMediaTime()
            metrics.render.append(t4 - t3)

            // 5. Detection for this frame is in: tiles it pre-covered clear unless a hidden person's cover overlaps them, tiles a
            //    later frame dirtied stay. Then one commit on the main actor with person covers and the remaining pre-covers.
            if !curtains.isEmpty {
                let hidden = specs.map { Rect($0.frame) }
                for key in curtains.keys { curtains[key]?.verified(seq: frame.sequence, hiddenRects: hidden, now: t4) }
                let verifiedPre = preCoverSpecs(frame: frame, appearance: a, windows: snapshot, curtainWindows: curtainWindows)
                if verifiedPre.count < preSpecs.count { metrics.curtainClear.append(CACurrentMediaTime() - t1) }
                preSpecs = verifiedPre
            }
            personSpecs = specs
            verifiedFrame = curtains.isEmpty ? nil : frame
            await applyAll(ifCurrent: isCurrent)
            guard isCurrent(), !Task.isCancelled else { continue }
            let t5 = CACurrentMediaTime()
            metrics.commit.append(t5 - t4)
            metrics.e2e.append(t5 - frame.timestamp)
            metrics.framesOut += 1
            if metrics.framesOut == 1, printer != nil {  // launch → protection: where the first second goes
                print("pipeline display=\(displayID) first_frame_at_ms=\(Int((frame.timestamp - startedAt) * 1000)) "
                    + "first_commit_at_ms=\(Int((t5 - startedAt) * 1000)) warmup_ms=\(warmupMs) layers=\(specs.count)")
            }
            metrics.tracks = tracks.count
            metrics.women = tracks.count { $0.category == .woman }
            metrics.men = tracks.count { $0.category == .man }
            metrics.unknown = tracks.count { $0.category == .unknown }
            metrics.layers = specs.count
            metrics.preLayers = preSpecs.count
            if printer == nil, metrics.e2e.count >= 512 { metrics.resetWindow() }  // no printer draining the window: cap it
            if let hook = commitHook.withLock({ $0 }) { await hook(personSpecs + preSpecs + failClosed.withLock { $0 }, frame, t5) }
        }
    }

    /// The first Vision request and the first CoreML prediction in a process load their models (hundreds of ms; seconds on the first
    /// launch after an update while the ANE compiles). Run each once on a blank frame while the stream connects, so the first real
    /// frame is not the one paying for it.
    private func warmUp() async {
        guard let blank = try? makeBuffer(64, 64) else { return }
        let frame = Frame(pixelBuffer: blank, displayID: displayID, sequence: 0, timestamp: CACurrentMediaTime(), dirtyRects: [],
                          contentRect: .zero, scaleFactor: 1, contentScale: 1, displaySize: CGSize(width: 64, height: 64))
        _ = try? await detector.detect(in: frame)
        guard settings.withLock({ $0.policy.hiddenSet != .everyone }) else { return }
        _ = try? await faces.detect(in: blank)
        _ = await classifier.pWoman(faces: [Rect(x: 0, y: 0, width: 64, height: 64)], in: frame)
    }

    private func printMetrics() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            print(metrics.line(display: displayID, elapsed: CACurrentMediaTime() - startedAt))
            metrics.resetWindow()
        }
    }
}
