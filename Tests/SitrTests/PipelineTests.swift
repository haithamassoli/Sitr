// M2-T12 / M2-T16 unit tests: the pure pipeline stages (detection dedupe, face → person assignment, metrics), the notification
// dedupe, and the FR3 appearance defaults. The live stages run under `Sitr --selftest pipeline|failstate`.
import CoreGraphics
import Foundation
import SitrCore
import SitrDetect
import Testing

@testable import Sitr

private func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ c: Float = 0.9) -> Detection {
    Detection(box: Rect(x: x, y: y, width: w, height: h), confidence: c)
}

@Test func dedupeKeepsOneBoxPerPerson() {
    let full = box(100, 100, 100, 300)
    let upper = box(105, 100, 90, 120, 0.8)  // upper body inside its full body: contained → dropped
    let near = box(110, 110, 100, 300, 0.7)  // IoU 0.77 with `full`: repeat → dropped (full wins on confidence)
    let other = box(400, 100, 100, 300)
    let kept = dedupe([upper, near, other, full])
    #expect(kept.count == 2)
    #expect(kept.contains(full) && kept.contains(other))
    // Two people side by side with a small overlap stay two boxes.
    let a = box(0, 0, 100, 300), b = box(80, 0, 100, 300)
    #expect(dedupe([a, b]).count == 2)
    #expect(dedupe([]).isEmpty)
}

@Test func facesGoToTheMostOverlappingPerson() {
    let a = box(0, 0, 100, 300), b = box(200, 0, 100, 300)
    let faceA = box(30, 10, 40, 40), faceB = box(190, 10, 40, 40)  // faceB overlaps b by 30 px and a by nothing
    let stray = box(500, 10, 40, 40)
    let assigned = assignFaces([faceB, stray, faceA], to: [a, b])
    #expect(assigned.count == 2)
    #expect(assigned[0] == faceA)
    #expect(assigned[1] == faceB)
    // Two faces on one person: the larger one wins.
    let small = box(10, 10, 20, 20), big = box(40, 10, 50, 50)
    #expect(assignFaces([small, big], to: [a]) == [big])
    #expect(assignFaces([big, small], to: [a]) == [big])
    #expect(assignFaces([faceA], to: []).isEmpty)
}

@Test func categoryRuleWithoutClassifierIsUnknown() {
    // What the pipeline does today: no P(woman) → unknown → covered under Everyone / Strict.
    #expect(categorize(face: Size(width: 60, height: 60), body: Size(width: 100, height: 300), pWoman: nil) == .unknown)
    #expect(Policy(hiddenSet: .everyone).hides(.unknown))
    #expect(Policy(hiddenSet: .women, strictMode: true).hides(.unknown))
}

@Test func metricsWindowAndSkipRatio() {
    var m = PipelineMetrics()
    #expect(m.skipRatio == 0)
    m.framesIn = 60
    m.skipped = 20
    #expect(abs(m.skipRatio - 0.25) < 1e-9)
    m.detect = [0.010, 0.020, 0.030]
    #expect(PipelineMetrics.p(m.detect) == "20.00/30.00")
    #expect(PipelineMetrics.p([]) == "-")
    let line = m.line(display: 1, elapsed: 12.4)
    #expect(line.hasPrefix("pipeline display=1 t=12 in=60"))
    #expect(line.contains("skipped=20") && line.contains("detect_ms=20.00/30.00") && line.contains("rss_mb="))
    m.resetWindow()
    #expect(m.detect.isEmpty && m.framesIn == 60)
    #expect(residentMemoryMB() > 1)
}

@MainActor @Test func notifierPostsOncePerHealthTransition() {
    Notifier.dryRun = true
    let n = Notifier()
    n.healthChanged(to: .ok)  // launch: healthy from the start, nothing to say
    #expect(n.posted == 0)
    n.healthChanged(to: .needsPermission)
    n.healthChanged(to: .needsPermission)  // same state again: no repeat
    #expect(n.posted == 1)
    n.healthChanged(to: .ok)  // recovery
    #expect(n.posted == 2)
    n.healthChanged(to: .ok)
    #expect(n.posted == 2)
    n.healthChanged(to: .degraded)
    n.healthChanged(to: .ok)
    #expect(n.posted == 4)
}

@MainActor @Test func appearanceDefaultsFollowFR3AndPersist() {
    let suite = "SitrTests.appearance.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let fresh = Preferences(defaults: defaults)
    #expect(fresh.coverStyle == .gaussian && fresh.blurStrength == 0.7 && fresh.bodyPadding == 0.15)
    let a = CoverAppearance()
    #expect(a.style == .gaussian && a.strength == 0.7 && a.padding == 0.15)
    fresh.coverStyle = .pixelate
    fresh.blurStrength = 0.4
    fresh.bodyPadding = 0.3
    let reloaded = Preferences(defaults: defaults)
    #expect(reloaded.coverStyle == .pixelate && reloaded.blurStrength == 0.4 && reloaded.bodyPadding == 0.3)
    defaults.removePersistentDomain(forName: suite)
}
