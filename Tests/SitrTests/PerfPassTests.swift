// M4-T09 performance pass: the pure decisions that removed per-frame work. Each one answers "can this frame skip something
// without changing what ends up on screen", so every test here is really a correctness test for a shortcut.
// The live numbers are in docs/perf.md; the runnable gate is `Sitr --selftest pipeline`'s `perf_budget` line.
import CoreGraphics
import CoreVideo
import Foundation
import SitrCore
import enum SitrCore.Category
import SitrDetect
import Testing

@testable import Sitr

private func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }

// MARK: - classifier cadence

@Test func classificationOrderSkipsTracksWithAFreshAnswer() {
    // persons 0…3, all classifiable: two known tracks with a fresh answer, one known but stale, one brand new.
    let sticky: [Category?] = [.woman, .man, .man, nil]
    let all = [Bool](repeating: true, count: 4)
    #expect(classificationOrder(classifiable: all, sticky: sticky, fresh: [true, true, false, false], round: 0) == [3, 2])
    // A new or Unknown track is never deferred, however fresh the map claims it is.
    #expect(classificationOrder(classifiable: all, sticky: [.unknown, .man, .man, nil], fresh: [true, true, true, true], round: 0) == [0, 3])
    // Everyone fresh and known: the classifier does not run at all.
    #expect(classificationOrder(classifiable: all, sticky: [.woman, .man, .man, .woman], fresh: [true, true, true, true], round: 0).isEmpty)
    // No freshness known (an empty or short array) is the pre-M4-T09 behaviour: everybody eligible, capped at the limit.
    #expect(classificationOrder(classifiable: all, sticky: sticky, round: 0) == [3, 0, 1])
    #expect(classificationOrder(classifiable: all, sticky: sticky, fresh: [true], round: 0) == [3, 1, 2])
}

// MARK: - faces only when they can change a category

private func track(_ id: Int, _ rect: Rect, _ category: Category) -> Track {
    Track(id: id, rect: rect, category: category, lastSeen: 0)
}

@Test func facesAreLookedForOnlyWhenTheyCouldChangeACover() {
    let a = Rect(x: 0, y: 0, width: 100, height: 300), b = Rect(x: 400, y: 0, width: 100, height: 300)
    let tracks = [track(1, a, .woman), track(2, b, .man)]
    let fresh = [1: 9.5, 2: 9.6]
    // Everyone on a known track with an answer newer than 1 s: nothing a face could change.
    #expect(!needsFaces(persons: [a, b], tracks: tracks, classifiedAt: fresh, now: 10, refresh: 1))
    // Somebody new, on no track at all.
    #expect(needsFaces(persons: [a, b, Rect(x: 800, y: 0, width: 100, height: 300)], tracks: tracks, classifiedAt: fresh, now: 10, refresh: 1))
    // A track whose answer has gone stale, and one that never had an answer.
    #expect(needsFaces(persons: [a], tracks: tracks, classifiedAt: [1: 8.0], now: 10, refresh: 1))
    #expect(needsFaces(persons: [a], tracks: tracks, classifiedAt: [:], now: 10, refresh: 1))
    // An Unknown track always wants a face, however recently it was asked.
    #expect(needsFaces(persons: [b], tracks: [track(2, b, .unknown)], classifiedAt: [2: 9.99], now: 10, refresh: 1))
    // No people, no faces.
    #expect(!needsFaces(persons: [], tracks: tracks, classifiedAt: fresh, now: 10, refresh: 1))
    for hiddenSet in HiddenSet.allCases {
        #expect(needsFaces(persons: [a], tracks: [], classifiedAt: [:], now: 10, refresh: 1,
                           hiddenSet: hiddenSet) == (hiddenSet != .everyone))
    }
}

// MARK: - cover reuse

@Test func curtainComparesPixelsAcrossSkippedFramesAndIgnoresOverlayDamage() throws {
    func frame(_ sequence: Int, changedByte: Bool = false, size: Int = 65) throws -> Frame {
        let buffer = try makeBuffer(size, size)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        base.initializeMemory(as: UInt8.self, repeating: 0, count: rowBytes * size)
        if changedByte { base.storeBytes(of: UInt8(1), toByteOffset: 64 * rowBytes + 64 * 4, as: UInt8.self) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return Frame(pixelBuffer: buffer, displayID: 1, sequence: sequence, timestamp: 0,
                     dirtyRects: [r(0, 0, Double(size), Double(size))], contentRect: .zero,
                     scaleFactor: 1, contentScale: 1, displaySize: CGSize(width: size, height: size))
    }
    let old = try frame(1)
    #expect(old.changedTiles(since: nil) == [r(0, 0, 65, 65)])
    #expect(try frame(2).changedTiles(since: old).isEmpty) // full-screen WindowServer damage, identical capture
    #expect(try frame(10, changedByte: true).changedTiles(since: old) == [r(64, 64, 1, 1)])
    #expect(try frame(11, size: 66).changedTiles(since: old) == [r(0, 0, 66, 66)])
}

@Test func aCoverIsReusedOnlyWhileItsBoxAndItsPixelsHoldStill() {
    let cover = r(100, 100, 200, 400)
    #expect(coverCanReuse(cached: cover, cover: cover, dirty: []))
    #expect(coverCanReuse(cached: cover, cover: r(100.9, 100.4, 200, 400), dirty: []))  // sub-pixel EMA drift
    #expect(!coverCanReuse(cached: cover, cover: r(104, 100, 200, 400), dirty: []))  // moved
    #expect(!coverCanReuse(cached: cover, cover: r(100, 100, 208, 400), dirty: []))  // resized
    // A changed region that touches the cover forces a re-render; one that misses it does not.
    #expect(!coverCanReuse(cached: cover, cover: cover, dirty: [r(0, 0, 150, 150)]))
    #expect(coverCanReuse(cached: cover, cover: cover, dirty: [r(0, 0, 90, 90), r(400, 0, 100, 100)]))
    // `nil` = the changed regions are unknowable (a sequence gap, an appearance change): never reuse.
    #expect(!coverCanReuse(cached: cover, cover: cover, dirty: nil))
}

@Test func anIdenticalCoverSetIsNotRecommitted() {
    let buffer = try? makeBuffer(8, 8)
    let a = CoverLayerSpec(id: 1, frame: r(0, 0, 10, 10), contents: buffer, color: nil)
    #expect(a.matches(CoverLayerSpec(id: 1, frame: r(0, 0, 10, 10), contents: buffer, color: nil)))
    #expect(!a.matches(CoverLayerSpec(id: 2, frame: r(0, 0, 10, 10), contents: buffer, color: nil)))
    #expect(!a.matches(CoverLayerSpec(id: 1, frame: r(0, 1, 10, 10), contents: buffer, color: nil)))
    #expect(!a.matches(CoverLayerSpec(id: 1, frame: r(0, 0, 10, 10), contents: try? makeBuffer(8, 8), color: nil)))
    let solid = CoverLayerSpec(id: 3, frame: r(0, 0, 10, 10), contents: nil, color: CGColor(gray: 0.5, alpha: 1))
    #expect(solid.matches(CoverLayerSpec(id: 3, frame: r(0, 0, 10, 10), contents: nil, color: CGColor(gray: 0.5, alpha: 1))))
    #expect(!solid.matches(CoverLayerSpec(id: 3, frame: r(0, 0, 10, 10), contents: nil, color: CGColor(gray: 0.2, alpha: 1))))
}

// MARK: - frames that cannot have changed anybody

@Test func aFrameOfTinyChangesAwayFromEveryTrackSkipsDetection() {
    let tracks = [r(100, 100, 100, 300)]  // display points; the frame below is 1 px per point
    // A clock tick in the corner: too small to hold a 40 px body, nowhere near anybody.
    #expect(nothingDetectableChanged(dirtyRects: [r(1200, 0, 30, 20)], pixelsPerPoint: 1, tracks: tracks))
    // The same tiny change must reach verification after the Curtain fast path pre-covers its tile.
    #expect(!nothingDetectableChanged(dirtyRects: [r(1200, 0, 30, 20)], pixelsPerPoint: 1, tracks: tracks, hasCurtain: true))
    // The same tick, but over a tracked person: they may have moved inside their own box.
    #expect(!nothingDetectableChanged(dirtyRects: [r(120, 120, 30, 20)], pixelsPerPoint: 1, tracks: tracks))
    // Big enough to hold a person who was not there before.
    #expect(!nothingDetectableChanged(dirtyRects: [r(1200, 0, 30, 60)], pixelsPerPoint: 1, tracks: tracks))
    // No changed regions reported says nothing at all, so detection runs.
    #expect(!nothingDetectableChanged(dirtyRects: [], pixelsPerPoint: 1, tracks: tracks))
    // The tracks are in points and the rects in capture pixels: at 0.5 px/pt the same track covers half the pixel coordinates.
    #expect(!nothingDetectableChanged(dirtyRects: [r(60, 60, 20, 20)], pixelsPerPoint: 0.5, tracks: tracks))
    #expect(nothingDetectableChanged(dirtyRects: [r(160, 60, 20, 20)], pixelsPerPoint: 0.5, tracks: tracks))
}

// MARK: - blur downscale

@Test func onlyBigBlursAreRenderedReduced() {
    #expect(CoverGeometry.blurDownscale(sigma: 4) == 1)
    #expect(CoverGeometry.blurDownscale(sigma: 7.9) == 1)
    #expect(CoverGeometry.blurDownscale(sigma: 8) == 2)
    #expect(CoverGeometry.blurDownscale(sigma: 15.9) == 2)
    #expect(CoverGeometry.blurDownscale(sigma: 16) == 4)
    #expect(CoverGeometry.blurDownscale(sigma: 200) == 4)
    // At least 4 samples per sigma at every step, so the reduction never removes detail the blur would have kept.
    for sigma in stride(from: 1.0, through: 120.0, by: 0.5) {
        #expect(sigma / Double(CoverGeometry.blurDownscale(sigma: sigma)) >= 4 || sigma < 8)
    }
}

// MARK: - the gate itself

@Test @MainActor func perFrameBudgetFailsWhenTheWorkComesBack() {
    var m = PipelineMetrics()
    m.framesOut = 200
    m.applies = 110
    m.crops = 20
    m.renders = 220
    #expect(PerFrameBudget(m).ok)
    m.applies = 200  // a commit per frame: the overlay damages the display it is captured from, and the pipeline feeds itself
    #expect(!PerFrameBudget(m).ok)
    m.applies = 110
    m.crops = 180  // the classifier back on every frame
    #expect(!PerFrameBudget(m).ok)
    m.crops = 20
    m.renders = 400  // reported, never gated: how much of the screen holds still is not this test's to control
    #expect(PerFrameBudget(m).ok)
    m.framesOut = 5  // too few frames to conclude anything
    #expect(!PerFrameBudget(m).ok)
    #expect(PerFrameBudget(m).line(load: 1).contains("applies_per_frame="))
}
