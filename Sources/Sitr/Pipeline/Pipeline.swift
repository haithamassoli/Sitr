// M2-T12: one Pipeline per display. Frame → detect persons + faces → assign faces → classify (≤ 3 faces) → categorize → track →
// policy → render → commit. Backpressure is the capture stream's `.bufferingNewest(1)`: while one detection is in flight,
// newer frames replace the single buffered frame, so intermediate frames are skipped and nothing ever queues. Metrics are
// timings and counts only (`SITR_METRICS=1` prints them every 5 s); no pixel leaves memory.
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
    var detect: [Double] = [], classify: [Double] = [], track: [Double] = [], render: [Double] = [], commit: [Double] = [], e2e: [Double] = []

    mutating func resetWindow() {
        detect = []
        classify = []
        track = []
        render = []
        commit = []
        e2e = []
    }

    /// Skipped ÷ delivered, over the whole run.
    var skipRatio: Double { framesIn + skipped > 0 ? Double(skipped) / Double(framesIn + skipped) : 0 }

    /// p50/p95 ms of one stage, "-" without samples.
    static func p(_ v: [Double]) -> String { v.isEmpty ? "-" : "\(ms(percentile(v, 0.5)))/\(ms(percentile(v, 0.95)))" }

    func line(display: CGDirectDisplayID, elapsed: Double) -> String {
        "pipeline display=\(display) t=\(Int(elapsed)) in=\(framesIn) out=\(framesOut) skipped=\(skipped) detections=\(detections) "
            + "errors=\(errors) applies=\(applies) detect_ms=\(Self.p(detect)) classify_ms=\(Self.p(classify)) crops=\(crops) "
            + "track_ms=\(Self.p(track)) render_ms=\(Self.p(render)) commit_ms=\(Self.p(commit)) e2e_ms=\(Self.p(e2e)) tracks=\(tracks) "
            + "categories=w\(women)/m\(men)/u\(unknown) layers=\(layers) rss_mb=\(Int(residentMemoryMB())) load1=\(fmt(loadAverage()))"
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

/// The per-display pipeline. Owns the tracker; reads the latest `Policy` / `CoverAppearance` per frame; commits covers to
/// the display's `OverlayPanel` on the main actor in one pass.
actor Pipeline {
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
    private let commitHook = Mutex<(@MainActor @Sendable ([CoverLayerSpec], Frame, Double) -> Void)?>(nil)

    private var tracker = Tracker()
    private(set) var metrics = PipelineMetrics()
    private var loop: Task<Void, Never>?
    private var printer: Task<Void, Never>?
    private var lastSequence: Int?
    private var hadLayers = false
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

    /// Runs on the main actor after every processed frame, once its covers are on screen: the specs applied, the frame, and
    /// `CACurrentMediaTime()` right after the commit. Health recovery and the selftests hang off this.
    nonisolated func onCommit(_ hook: (@MainActor @Sendable ([CoverLayerSpec], Frame, Double) -> Void)?) {
        commitHook.withLock { $0 = hook }
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

    /// Stops consuming and removes every cover of this display.
    func stop() async {
        loop?.cancel()
        printer?.cancel()
        loop = nil
        printer = nil
        await clear()
    }

    private func clear() async {
        hadLayers = false
        await panel.apply([])
    }

    private func run() async {
        let w0 = CACurrentMediaTime()
        await warmUp()
        let warmupMs = Int((CACurrentMediaTime() - w0) * 1000)
        for await frame in frames {
            if Task.isCancelled { return }
            let t0 = CACurrentMediaTime()
            metrics.framesIn += 1
            if let last = lastSequence, frame.sequence > last + 1 { metrics.skipped += frame.sequence - last - 1 }
            lastSequence = frame.sequence

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

            // 2. Face → person, then at most 3 faces through the classifier: new and unknown tracks first, the rest round-robin;
            //    a person skipped this frame keeps the category of the track it lands on. Category rule; observations in display points.
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
                observations.append(PersonObservation(rect: rects[i], category: category, pWoman: p))
            }

            // 3. Track, then policy (merges overlapping hidden tracks itself).
            let now = CACurrentMediaTime()
            let tracks = tracker.update(observations, at: now, sequence: frame.sequence)
            let current = settings.withLock { $0 }
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

            // 5. Commit on the main actor in one pass. An empty set is applied once, then the panel is left alone.
            if !specs.isEmpty || hadLayers {
                await panel.apply(specs)
                metrics.applies += 1
            }
            hadLayers = !specs.isEmpty
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
            if printer == nil, metrics.e2e.count >= 512 { metrics.resetWindow() }  // no printer draining the window: cap it
            if let hook = commitHook.withLock({ $0 }) { await hook(specs, frame, t5) }
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
