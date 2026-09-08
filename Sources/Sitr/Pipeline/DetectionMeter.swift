// M4-T07: how long detection takes per frame, folded into the pure `DegradedMonitor` (SitrCore) once per display. The
// pipelines write from their own executor after every frame; the Runtime reads `isDegraded` on the main actor once a
// second and turns it into `Policy.health`. Timings and counts only — no frame, crop or pixel is ever recorded here.
import CoreGraphics
import SitrCore
import Synchronization
import os

nonisolated final class DetectionMeter: Sendable {
    // ponytail: one process-wide meter instead of an instance threaded from the Runtime through `Pipeline.init` (the file
    // two other tasks are editing). Ceiling: a second Runtime in the same process shares the state, which is why `start()`
    // resets it. Upgrade path: pass the meter to `Pipeline.init` alongside the detector.
    static let shared = DetectionMeter()

    private let monitors = Mutex<[CGDirectDisplayID: DegradedMonitor]>([:])
    private let failures = Mutex<[CGDirectDisplayID: (first: Double, last: Double)]>([:])
    var hasFailures: Bool { failures.withLock { $0.values.contains { $0.last - $0.first >= 3 } } }

    func recordFailure(display: CGDirectDisplayID, at now: Double) {
        failures.withLock { $0[display] = ($0[display]?.first ?? now, now) }
        let _ = monitors.withLock { $0[display, default: DegradedMonitor()].record(seconds: 0.251, at: now) }
    }

    private let log = Logger(subsystem: "com.goldentik.Sitr", category: "health")

    /// PRD FR10: any display whose detection has been slow for 3 s puts the app in the degraded state.
    var isDegraded: Bool { monitors.withLock { $0.values.contains(where: \.isDegraded) } }

    /// Displays currently degraded, for logs and selftests.
    var degradedDisplays: [CGDirectDisplayID] { monitors.withLock { $0.filter(\.value.isDegraded).keys.sorted() } }

    /// One processed frame: `seconds` of detection work that finished at `now`. Called off the main actor.
    func record(display: CGDirectDisplayID, seconds: Double, at now: Double) {
        failures.withLock { $0[display] = nil }
        let flipped = monitors.withLock { $0[display, default: DegradedMonitor()].record(seconds: seconds, at: now) }
        guard let flipped else { return }
        let state = flipped ? "degraded" : "recovered"
        log.notice("detection \(state, privacy: .public) display=\(display) frame_ms=\(Int(seconds * 1000))")
    }

    /// The display is gone (unplugged): its history says nothing about the ones that remain.
    func forget(display: CGDirectDisplayID) {
        monitors.withLock { $0[display] = nil }
        failures.withLock { $0[display] = nil }
    }

    /// Fresh start for a new Runtime (and between selftests / unit tests).
    func reset() {
        monitors.withLock { $0 = [:] }
        failures.withLock { $0 = [:] }
    }
}
