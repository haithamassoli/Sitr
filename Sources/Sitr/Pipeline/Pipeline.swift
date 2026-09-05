// M2-T12: one Pipeline per display. Frame → detect persons + faces → assign faces → classify (hook) → categorize → track →
// policy → render → commit. Backpressure is the capture stream's `.bufferingNewest(1)`: while one detection is in flight,
// newer frames replace the single buffered frame, so intermediate frames are skipped and nothing ever queues. Metrics are
// timings and counts only (`SITR_METRICS=1` prints them every 5 s); no pixel leaves memory.
import CoreVideo
import Foundation
import QuartzCore
import SitrCore
import SitrDetect
import Synchronization

/// Person boxes in capture pixels (top-left origin) for one frame. Vision today; `CoreMLPersonDetector` (M1-T06b) conforms next.
nonisolated protocol PersonDetecting: Sendable {
    func detect(in frame: Frame) async throws -> [Detection]
}

/// P(woman) for one face, or nil when the classifier cannot say (no model yet, crop too small, model error) → `.unknown`.
nonisolated protocol GenderClassifying: Sendable {
    /// `face` in capture pixels of `frame`; the implementation crops with its own margin (PRD FR2: 20 %).
    func pWoman(faceCrop face: Rect, in frame: Frame) async -> Double?
}

/// Vision full-body ∪ upper-body boxes, deduplicated (the M1-T06 union: 37.8 % recall on the benchmark set).
// ponytail: two Vision handler runs per frame (full and upper body concurrently; faces make a third in the pipeline) instead
// of one shared handler, because SitrDetect keeps its requests internal. The CoreML detector (M1-T06b) replaces this type
// wholesale through `PersonDetecting`, so the extra handler run is not worth an API change.
nonisolated struct VisionPersonDetector: PersonDetecting {
    private let full = PersonDetector()
    private let upper = PersonDetector(upperBodyOnly: true)

    func detect(in frame: Frame) async throws -> [Detection] {
        async let a = full.detect(in: frame.pixelBuffer)
        async let b = upper.detect(in: frame.pixelBuffer)
        return dedupe(try await a + b)
    }
}

/// M2-T07 placeholder: no classifier → every person is `.unknown` → covered under the Everyone / Strict placeholder policy.
// ponytail: returns nil until M2-T07 lands the CoreML face-gender model; then a `CoreMLGenderClassifier: GenderClassifying`
// takes this slot in `Pipeline.init`.
nonisolated struct NoClassifier: GenderClassifying {
    func pWoman(faceCrop face: Rect, in frame: Frame) async -> Double? { nil }
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

/// Cover look (PRD FR3): style, Blur Strength 0…1 (default 0.7), Body Padding 0…0.5 (default 0.15). `Preferences` persists it.
nonisolated struct CoverAppearance: Sendable {
    var style: CoverStyle = .gaussian
    var strength = 0.7
    var padding = 0.15
}

/// Counts since start and stage timings (seconds) for the current metrics window; the window is reset every print (or capped),
/// so nothing grows. Timings and counts only.
nonisolated struct PipelineMetrics: Sendable {
    var framesIn = 0, framesOut = 0, skipped = 0, detections = 0, errors = 0, applies = 0, tracks = 0, layers = 0
    var detect: [Double] = [], track: [Double] = [], render: [Double] = [], commit: [Double] = [], e2e: [Double] = []

    mutating func resetWindow() {
        detect = []
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
            + "errors=\(errors) applies=\(applies) detect_ms=\(Self.p(detect)) track_ms=\(Self.p(track)) render_ms=\(Self.p(render)) "
            + "commit_ms=\(Self.p(commit)) e2e_ms=\(Self.p(e2e)) tracks=\(tracks) layers=\(layers) rss_mb=\(Int(residentMemoryMB())) "
            + "load1=\(fmt(loadAverage()))"
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
        if ProcessInfo.processInfo.environment["SITR_METRICS"] == "1" { printer = Task { await printMetrics() } }
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

            // 2. Face → person, classifier hook, category rule; observations in display points.
            let assigned = assignFaces(faceBoxes, to: persons)
            var observations: [PersonObservation] = []
            observations.reserveCapacity(persons.count)
            for (i, person) in persons.enumerated() {
                let face = assigned[i]
                var p: Double?
                if let face { p = await classifier.pWoman(faceCrop: face.box, in: frame) }
                let category = categorize(
                    face: face.map { Size(width: $0.box.width, height: $0.box.height) },
                    body: Size(width: person.box.width, height: person.box.height), pWoman: p)
                observations.append(PersonObservation(rect: frame.pixelsToDisplayPoints(person.box), category: category, pWoman: p))
            }

            // 3. Track, then policy (merges overlapping hidden tracks itself).
            let now = CACurrentMediaTime()
            let tracks = tracker.update(observations, at: now, sequence: frame.sequence)
            let current = settings.withLock { $0 }
            let covers = current.policy.covers(for: tracks, now: now)
            let t2 = CACurrentMediaTime()
            metrics.track.append(t2 - t1)

            // 4. Render one layer per cover from this frame's pixels.
            let a = current.appearance
            let specs = covers.map {
                renderer.render(id: $0.trackID, style: a.style, strength: a.strength, padding: a.padding, rect: CGRect($0.rect), frame: frame)
            }
            let t3 = CACurrentMediaTime()
            metrics.render.append(t3 - t2)

            // 5. Commit on the main actor in one pass. An empty set is applied once, then the panel is left alone.
            if !specs.isEmpty || hadLayers {
                await panel.apply(specs)
                metrics.applies += 1
            }
            hadLayers = !specs.isEmpty
            let t4 = CACurrentMediaTime()
            metrics.commit.append(t4 - t3)
            metrics.e2e.append(t4 - frame.timestamp)
            metrics.framesOut += 1
            if metrics.framesOut == 1, printer != nil {  // launch → protection: where the first second goes
                print("pipeline display=\(displayID) first_frame_at_ms=\(Int((frame.timestamp - startedAt) * 1000)) "
                    + "first_commit_at_ms=\(Int((t4 - startedAt) * 1000)) warmup_ms=\(warmupMs) layers=\(specs.count)")
            }
            metrics.tracks = tracks.count
            metrics.layers = specs.count
            if printer == nil, metrics.e2e.count >= 512 { metrics.resetWindow() }  // no printer draining the window: cap it
            if let hook = commitHook.withLock({ $0 }) { await hook(specs, frame, t4) }
        }
    }

    /// The first Vision request in a process loads its models (hundreds of ms). Run one on a blank frame while the stream
    /// connects, so the first real frame is not the one paying for it.
    private func warmUp() async {
        guard let blank = try? makeBuffer(64, 64) else { return }
        let frame = Frame(pixelBuffer: blank, displayID: displayID, sequence: 0, timestamp: CACurrentMediaTime(), dirtyRects: [],
                          contentRect: .zero, scaleFactor: 1, contentScale: 1, displaySize: CGSize(width: 64, height: 64))
        _ = try? await detector.detect(in: frame)
        _ = try? await faces.detect(in: blank)
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
