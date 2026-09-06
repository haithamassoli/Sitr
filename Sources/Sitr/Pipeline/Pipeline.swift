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
/// matches) or on an `.unknown` track first, then the rest; each group rotated by `round` so nobody starves. The Tracker keeps
/// categories sticky, so a person skipped this frame keeps last frame's answer.
// ponytail: 3 crops per frame (≈ 30 ms of ANE at the spike's 8–10 ms/crop) caps the classifier's cost, so ten faces cost the same
// as three and each is re-checked every ~3 frames instead of 100 ms/frame; upgrade path: classify only tracks that are unknown or
// older than N s, or swap in the ≤ 10 MB MobileNetV3 from docs/spike/classifier.md and lift the cap.
nonisolated func classificationOrder(classifiable: [Bool], sticky: [Category?], round: Int, limit: Int = 3) -> [Int] {
    func rotated(_ v: [Int]) -> [Int] { v.isEmpty ? v : Array(v[(round % v.count)...] + v[..<(round % v.count)]) }
    let eligible = classifiable.indices.filter { classifiable[$0] }
    let urgent = eligible.filter { sticky[$0] == nil || sticky[$0] == .unknown }
    let rest = eligible.filter { !urgent.contains($0) }
    return Array((rotated(urgent) + rotated(rest)).prefix(limit))
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
nonisolated struct CoverAppearance: Sendable {
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

    nonisolated let displayID: CGDirectDisplayID
    private let frames: AsyncStream<Frame>
    private let panel: OverlayPanel
    private let renderer: CoverRenderer
    private let detector: any PersonDetecting
    private let faces = FaceDetector()
    private let classifier: any GenderClassifying

    private nonisolated struct Settings: Sendable {
        var policy: Policy
        var appearance: CoverAppearance
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
    private var preSpecs: [CoverLayerSpec] = []
    /// The last pre-cover pass went over `preCoverBudget`: render the next one Solid (see `preCoverSpecs`).
    private var preCoverOverBudget = false
    private var appliedLayers = 0
    private(set) var metrics = PipelineMetrics()
    private var loop: Task<Void, Never>?
    private var printer: Task<Void, Never>?
    private var lastSequence: Int?
    private var round = 0
    private let startedAt = CACurrentMediaTime()

    init(
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
    nonisolated var modelsNote: String {
        "detector=\(String(describing: type(of: detector))) classifier=\(String(describing: type(of: classifier)))"
    }

    /// Latest policy (`AppModel.onPolicyChanged`), used from the next frame on. When it stops protecting (pause, disable,
    /// needs permission) the covers come down right away, frames or not.
    nonisolated func update(_ policy: Policy) {
        settings.withLock { $0.policy = policy }
        if !policy.isProtecting(at: CACurrentMediaTime()) { Task { await self.clear() } }
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
        personSpecs = []
        preSpecs = []
        curtains = [:]
        curtainWindowIDs = [:]
        await applyAll()
    }

    /// The one apply: person covers + pre-covers + fail-closed covers. An empty set is applied once, then the panel is left alone.
    private func applyAll() async {
        let specs = personSpecs + preSpecs + failClosed.withLock { $0 }
        guard !specs.isEmpty || appliedLayers > 0 else { return }
        await panel.apply(specs)
        appliedLayers = specs.count
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
        var specs: [CoverLayerSpec] = []
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
                    specs.append(renderer.render(id: CoverID.preCover(specs.count), style: style, strength: a.strength, padding: 0, rect: piece, frame: frame))
                }
            }
        }
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
            let snapshot = windows.withLock { $0 }

            // 0. Curtain fast path (M3-T05, PRD FR4): dirty rects ∩ this display's Curtain windows → pre-covers, on screen before
            //    detection starts. Every frame feeds `dirty` (seq bookkeeping); windows in trusted motion add nothing.
            let rules = current.policy.rules
            let curtainWindows = current.policy.isProtecting(at: t0)
                ? snapshot.filter { $0.displayID == displayID && rules.mode(for: $0.bundleID) == .curtain } : []
            syncCurtains(curtainWindows, now: t0)
            var pre: [CoverLayerSpec] = []
            if !curtains.isEmpty {
                // SCK reports `dirtyRects` against the previous frame it *emitted*, and the drop-oldest stream throws frames away
                // while detection runs: after a sequence gap the changes in between are unknowable, so the whole window counts as
                // dirty (Curtain covers what might have changed). Trusted motion still suppresses it, which is what keeps video
                // watchable (FR4.3).
                // ponytail: a whole-window pre-cover per skipped frame is coarse; upgrade path = accumulate dirty rects in the
                // capture callback (CaptureSession, another owner's file) and hand the union to the frame the pipeline consumes.
                var dirty = frame.dirtyRectsInDisplayPoints.map(Rect.init)
                if gap > 0 {
                    dirty += curtainWindows.map { Rect($0.rect) }
                    metrics.gapCovers += 1
                }
                for key in curtains.keys { curtains[key]?.dirty(rects: dirty, seq: frame.sequence, now: t0) }
                pre = preCoverSpecs(frame: frame, appearance: current.appearance, windows: snapshot, curtainWindows: curtainWindows)
            }
            if !pre.isEmpty || !preSpecs.isEmpty {
                preSpecs = pre
                await applyAll()
                if !pre.isEmpty {
                    metrics.preApplies += 1
                    metrics.fastPath.append(CACurrentMediaTime() - frame.timestamp)
                }
            }
            if let hook = preCoverHook.withLock({ $0 }) { await hook(pre, frame, CACurrentMediaTime()) }

            // 1. Persons and faces, concurrently, off this actor and off main (nonisolated async). One frame at a time: the
            //    loop waits here, and the capture stream keeps only the newest frame that arrives meanwhile.
            let persons: [Detection], faceBoxes: [Detection]
            do {
                async let p = detector.detect(in: frame)
                async let f = faces.detect(in: frame.pixelBuffer)
                (persons, faceBoxes) = try await (p, f)
                metrics.detections += 1
            } catch {
                // ponytail: a failed detection keeps the previous covers (fail safe) and is counted; M4-T07 turns sustained
                // failures / slowness into `.degraded`.
                metrics.errors += 1
                continue
            }
            let t1 = CACurrentMediaTime()
            metrics.detect.append(t1 - t0)
            DetectionMeter.shared.record(display: displayID, seconds: t1 - t0, at: t1)  // M4-T07 degraded state

            // 2. Face → person, then at most 3 faces through the classifier: new and unknown tracks first, the rest round-robin;
            //    a person skipped this frame keeps the category of the track it lands on. Category rule; observations in display
            //    points, attributed to the topmost window under the box centre (M3: Policy resolves Blur / Curtain per app).
            let assigned = assignFaces(faceBoxes, to: persons)
            let rects = persons.map { frame.pixelsToDisplayPoints($0.box) }
            let sticky = rects.map { r in tracker.tracks.filter { $0.rect.iou(r) >= Tracker.matchIoU }.max { $0.rect.iou(r) < $1.rect.iou(r) }?.category }
            let usable = persons.indices.map { classifiable(face: assigned[$0], body: persons[$0]) }
            let order = classificationOrder(classifiable: usable, sticky: sticky, round: round)
            round += 1
            let probabilities = order.isEmpty ? [] : await classifier.pWoman(faces: order.map { assigned[$0]!.box }, in: frame)
            let t2 = CACurrentMediaTime()
            if !order.isEmpty {
                metrics.classify.append((t2 - t1) / Double(order.count))
                metrics.crops += order.count
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
                } else {
                    category = usable[i] ? (sticky[i] ?? .unknown) : .unknown  // capped out this frame, or nothing to classify (rule → Unknown)
                }
                let owner = snapshot.topmost(at: CGPoint(x: rects[i].midX, y: rects[i].midY), on: displayID)?.bundleID
                observations.append(PersonObservation(rect: rects[i], category: category, pWoman: p, bundleID: owner))
            }

            // 3. Track, then policy (merges overlapping hidden tracks itself).
            let now = CACurrentMediaTime()
            let tracks = tracker.update(observations, at: now, sequence: frame.sequence)
            let covers = current.policy.covers(for: tracks, now: now)
            let t3 = CACurrentMediaTime()
            metrics.track.append(t3 - t2)

            // 4. Render one layer per cover from this frame's pixels.
            let a = current.appearance
            let specs = covers.map {
                renderer.render(id: $0.trackID, style: a.style, strength: a.strength, padding: a.padding, rect: CGRect($0.rect), frame: frame)
            }
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
            await applyAll()
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
