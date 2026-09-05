import Testing

@testable import SitrCore

/// 4 × 2 tiles at the origin. Timelines use 1/32 s frames and 1/64 s result latency: exact in binary, so the
/// 0.2 / 0.5 / 1.0 s thresholds compare exactly.
private let window = Rect(x: 0, y: 0, width: 256, height: 128)
private let frame = 1.0 / 32
private let latency = 1.0 / 64

private func tile(_ column: Int, _ row: Int, in w: Rect = window) -> Rect {
    Rect(x: w.x + Double(column) * 64, y: w.y + Double(row) * 64, width: 64, height: 64)
}

/// `count` frames of `rects` dirty from `start`, each verified `latency` later with `hidden` in the result.
private func play(
    _ curtain: inout Curtain, rects: [Rect], hidden: [Rect] = [], from start: Double, seq: Int, count: Int
) -> (next: Double, nextSeq: Int, preCoveredOnArrival: [Int], trustedAt: Double?) {
    var preCovered: [Int] = []
    var trustedAt: Double?
    for n in 0..<count {
        let t = start + Double(n) * frame
        curtain.dirty(rects: rects, seq: seq + n, now: t)
        if !curtain.preCovers().isEmpty { preCovered.append(seq + n) }
        curtain.verified(seq: seq + n, hiddenRects: hidden, now: t + latency)
        if trustedAt == nil, curtain.isTrusted(window: 1) { trustedAt = t + latency }
    }
    return (start + Double(count) * frame, seq + count, preCovered, trustedAt)
}

@Suite struct CurtainTests {
    @Test func constantsMatchPRD() {
        #expect(Curtain.tileSize == 64)
        #expect(Curtain.motionGap == 0.2)
        #expect(Curtain.trustAfter == 0.5)
        #expect(Curtain.staticReset == 1.0)
    }

    @Test func pageLoad_newWindowIsFullyPreCoveredUntilItsFirstVerifiedFrame() {
        var curtain = Curtain()
        curtain.dirty(rects: [], seq: 4, now: 0)  // frames 0…4 predate the window
        curtain.windowChanged(id: 1, rect: window, now: 0.01)
        #expect(curtain.preCovers() == [window])  // all 8 tiles, as one rect
        curtain.verified(seq: 4, hiddenRects: [], now: 0.1)  // a result for a frame that never saw the window
        #expect(curtain.preCovers() == [window])
        curtain.verified(seq: 5, hiddenRects: [], now: 0.15)  // the first frame after the window appeared
        #expect(curtain.preCovers().isEmpty)
        #expect(!curtain.isTrusted(window: 1))
    }

    @Test func pageLoadWithAPersonKeepsTheirTilesCoveredUntilALaterSafeFrame() {
        var curtain = Curtain()
        curtain.windowChanged(id: 1, rect: window, now: 0)
        let person = Rect(x: 70, y: 10, width: 20, height: 100)  // over tiles (1,0) and (1,1)
        curtain.verified(seq: 0, hiddenRects: [person], now: 0.1)
        #expect(curtain.preCovers() == [Rect(x: 64, y: 0, width: 64, height: 128)])
        curtain.dirty(rects: [tile(1, 0)], seq: 1, now: 0.15)  // re-dirtied at seq 1; (1,1) still waits since seq 0
        curtain.verified(seq: 1, hiddenRects: [], now: 0.2)  // person gone: both clear
        #expect(curtain.preCovers().isEmpty)
    }

    @Test func scrollStart_dirtyRowsArePreCoveredThenClearedAfterVerification() {
        var curtain = Curtain()
        curtain.windowChanged(id: 1, rect: window, now: 0)
        curtain.verified(seq: 0, hiddenRects: [], now: 0.1)
        let bottomRow = Rect(x: 0, y: 64, width: 256, height: 64)
        curtain.dirty(rects: [bottomRow], seq: 1, now: 0.2)
        #expect(curtain.preCovers() == [bottomRow])
        let caret = Rect(x: 100, y: 10, width: 10, height: 10)  // a caret blink: one tile
        curtain.dirty(rects: [caret], seq: 2, now: 0.25)
        #expect(curtain.preCovers() == [bottomRow, tile(1, 0)])
        curtain.verified(seq: 1, hiddenRects: [], now: 0.3)
        #expect(curtain.preCovers() == [tile(1, 0)])
        curtain.verified(seq: 2, hiddenRects: [], now: 0.35)
        #expect(curtain.preCovers().isEmpty)
    }

    /// 30 s of video without people: dirty every frame, every frame verified safe.
    @Test func video_trustedAfter500msThenNoPreCoverUntilAOneSecondPause() {
        var curtain = Curtain()
        let video = Rect(x: 64, y: 0, width: 128, height: 128)  // tile columns 1–2, both rows
        curtain.windowChanged(id: 1, rect: window, now: 0)
        curtain.verified(seq: 0, hiddenRects: [], now: 0.05)

        var run = play(&curtain, rects: [video], from: 0.5, seq: 1, count: 960)  // 0.5 → 30.5 s
        let trustedAt = run.trustedAt ?? -1
        // Motion starts at 0.5; trusted once a result confirms 0.5 s of it: 0.5 + 16 frames + latency = 1.015625.
        #expect(trustedAt == 0.5 + 16 * frame + latency)
        #expect(run.preCoveredOnArrival == Array(1...17))  // every frame up to the one in flight when trust arrived
        #expect(curtain.preCovers().isEmpty)

        // A 0.5 s frame drop (> motionGap, < staticReset) does not end trust.
        var t = run.next + 0.5
        curtain.dirty(rects: [video], seq: run.nextSeq, now: t)
        #expect(curtain.preCovers().isEmpty && curtain.isTrusted(window: 1))
        curtain.verified(seq: run.nextSeq, hiddenRects: [], now: t + latency)

        // Another window's motion during the pause is not this window's motion…
        let elsewhere = Rect(x: 1000, y: 1000, width: 10, height: 10)
        for i in 1...9 { curtain.dirty(rects: [elsewhere], seq: run.nextSeq + i, now: t + Double(i) / 10) }
        #expect(curtain.preCovers().isEmpty && curtain.isTrusted(window: 1))
        // …and 1 s without a dirty rect in the window resets it: the next frame is curtained again.
        t += 1
        run = play(&curtain, rects: [video], from: t, seq: run.nextSeq + 10, count: 40)
        #expect(run.preCoveredOnArrival.first == run.nextSeq - 40)  // first frame after the pause was pre-covered
        #expect(run.trustedAt == t + 16 * frame + latency)  // and trust is earned again the same way
    }

    @Test func aGapInMotionRestartsTheTrustClock() {
        var curtain = Curtain()
        curtain.windowChanged(id: 1, rect: window, now: 0)
        curtain.verified(seq: 0, hiddenRects: [], now: 0)
        // 12 frames from 0.5 (0.375 s of motion), then a 0.25 s gap (> motionGap): the run starts over.
        var run = play(&curtain, rects: [window], from: 0.5, seq: 1, count: 12)
        #expect(run.trustedAt == nil)
        run = play(&curtain, rects: [window], from: run.next + 0.25, seq: run.nextSeq, count: 40)
        #expect(run.trustedAt == 0.5 + 12 * frame + 0.25 + 16 * frame + latency)  // 0.5 s after the restart
    }

    @Test func aLateResultAfterMotionStoppedDoesNotGrantTrust() {
        var curtain = Curtain()
        curtain.windowChanged(id: 1, rect: window, now: 0)
        curtain.verified(seq: 0, hiddenRects: [], now: 0)
        let run = play(&curtain, rects: [window], from: 0.5, seq: 1, count: 10)  // 0.3 s of motion
        curtain.dirty(rects: [window], seq: run.nextSeq, now: run.next)  // last frame of the motion; its result is slow
        curtain.verified(seq: run.nextSeq, hiddenRects: [], now: run.next + 0.4)  // safe results now span > 0.5 s…
        #expect(!curtain.isTrusted(window: 1))  // …but the motion ended 0.4 s ago
        #expect(curtain.preCovers().isEmpty)
    }

    @Test func personInAVerifiedFrameKeepsTheirTilesCoveredAndBlocksTrust() {
        var curtain = Curtain()
        curtain.windowChanged(id: 1, rect: window, now: 0)
        curtain.verified(seq: 0, hiddenRects: [], now: 0)
        let video = Rect(x: 64, y: 0, width: 128, height: 128)
        let person = Rect(x: 140, y: 20, width: 30, height: 100)  // inside tile column 2, both rows
        let personTiles = Rect(x: 128, y: 0, width: 64, height: 128)
        var t = 0.5
        for n in 1...40 {  // 1.25 s of video with a person in it
            curtain.dirty(rects: [video], seq: n, now: t)
            #expect(curtain.preCovers() == [video])
            curtain.verified(seq: n, hiddenRects: [person], now: t + latency)
            #expect(curtain.preCovers() == [personTiles])  // column 1 cleared, column 2 stays for the person cover
            #expect(!curtain.isTrusted(window: 1))
            t += frame
        }
        // The person leaves: the next safe result clears their tiles, and trust follows 0.5 s later.
        let run = play(&curtain, rects: [video], from: t, seq: 41, count: 20)
        #expect(run.preCoveredOnArrival.count == 17)
        #expect(run.trustedAt == t + 16 * frame + latency)
    }

    @Test func personDuringTrustedMotionKeepsBlurBehaviourUntilTheNextReset() {
        var curtain = Curtain()
        curtain.windowChanged(id: 1, rect: window, now: 0)
        curtain.verified(seq: 0, hiddenRects: [], now: 0)
        var run = play(&curtain, rects: [window], from: 0.5, seq: 1, count: 20)
        #expect(run.trustedAt != nil)
        let person = Rect(x: 140, y: 20, width: 30, height: 100)
        // A person appears in a trusted video: no pre-cover (the caller's person cover is the only cover), trust kept.
        run = play(&curtain, rects: [window], hidden: [person], from: run.next, seq: run.nextSeq, count: 20)
        #expect(run.preCoveredOnArrival.isEmpty)
        #expect(curtain.isTrusted(window: 1))
        // After a ≥ 1 s pause the video resumes with the person: curtained again, no trust while a person is seen.
        run = play(&curtain, rects: [window], hidden: [person], from: run.next + 1, seq: run.nextSeq, count: 40)
        #expect(run.preCoveredOnArrival.count == 40)
        #expect(run.trustedAt == nil)
        #expect(curtain.preCovers() == [Rect(x: 128, y: 0, width: 64, height: 128)])
    }

    @Test func outOfOrder_aResultForFrameNNeverClearsTilesDirtiedByFrameNPlusOne() {
        var curtain = Curtain()
        curtain.windowChanged(id: 1, rect: window, now: 0)
        curtain.verified(seq: 0, hiddenRects: [], now: 0)
        curtain.dirty(rects: [tile(0, 0)], seq: 5, now: 1)
        curtain.dirty(rects: [tile(3, 1)], seq: 6, now: 1 + frame)
        curtain.verified(seq: 5, hiddenRects: [], now: 1.1)
        #expect(curtain.preCovers() == [tile(3, 1)])  // 5 clears its own tile, not 6's
        curtain.dirty(rects: [tile(0, 0), tile(3, 1)], seq: 7, now: 1.125)  // 7 re-dirties both
        curtain.verified(seq: 6, hiddenRects: [], now: 1.15)
        #expect(curtain.preCovers() == [tile(0, 0), tile(3, 1)])  // nothing: both now wait for 7
        curtain.verified(seq: 7, hiddenRects: [], now: 1.2)
        #expect(curtain.preCovers().isEmpty)
        // A newer result arriving first clears what that frame saw; the older one arriving late changes nothing.
        curtain.dirty(rects: [tile(1, 0)], seq: 8, now: 1.25)
        curtain.dirty(rects: [tile(2, 0)], seq: 9, now: 1.25 + frame)
        curtain.verified(seq: 9, hiddenRects: [], now: 1.35)
        #expect(curtain.preCovers().isEmpty)
        curtain.verified(seq: 8, hiddenRects: [], now: 1.36)
        #expect(curtain.preCovers().isEmpty)
    }

    @Test func closedWindowHasNoPreCoversAndNoTrust() {
        var curtain = Curtain()
        let other = Rect(x: 500, y: 0, width: 64, height: 64)
        curtain.windowChanged(id: 1, rect: window, now: 0)
        curtain.windowChanged(id: 2, rect: other, now: 0)
        #expect(curtain.preCovers() == [window, other])
        curtain.windowClosed(id: 1)
        #expect(curtain.preCovers() == [other])
        #expect(!curtain.isTrusted(window: 1))
        curtain.dirty(rects: [window], seq: 1, now: 0.1)  // dirt where the window was belongs to nobody
        #expect(curtain.preCovers() == [other])
        curtain.windowClosed(id: 2)
        curtain.windowClosed(id: 2)  // idempotent
        #expect(curtain.preCovers().isEmpty)
    }

    @Test func resizePreCoversEverythingAgainWhileAMoveKeepsState() {
        var curtain = Curtain()
        curtain.windowChanged(id: 1, rect: window, now: 0)
        curtain.verified(seq: 0, hiddenRects: [], now: 0)
        curtain.dirty(rects: [tile(0, 0)], seq: 1, now: 0.1)
        curtain.windowChanged(id: 1, rect: window, now: 0.15)  // poll with no change: no-op
        #expect(curtain.preCovers() == [tile(0, 0)])
        let moved = Rect(x: 100, y: 50, width: 256, height: 128)
        curtain.windowChanged(id: 1, rect: moved, now: 0.2)  // same size: the covered tile moves with it
        #expect(curtain.preCovers() == [tile(0, 0, in: moved)])
        curtain.verified(seq: 1, hiddenRects: [], now: 0.25)
        #expect(curtain.preCovers().isEmpty)
        let resized = Rect(x: 100, y: 50, width: 300, height: 200)  // 5 × 4 tiles; last column 44 pt, last row 8 pt
        curtain.windowChanged(id: 1, rect: resized, now: 0.3)
        #expect(curtain.preCovers() == [resized])
        curtain.verified(seq: 1, hiddenRects: [], now: 0.35)  // predates the resize: tiles wait for frame 2
        #expect(curtain.preCovers() == [resized])
        curtain.dirty(rects: [], seq: 2, now: 0.4)
        curtain.verified(seq: 2, hiddenRects: [], now: 0.45)
        #expect(curtain.preCovers().isEmpty)
    }

    @Test func preCoversClipToTheWindowMergeRunsAndIgnoreTouchingEdges() {
        var curtain = Curtain()
        let small = Rect(x: 10, y: 20, width: 100, height: 70)  // 2 × 2 tiles, clipped to 100 × 70
        curtain.windowChanged(id: 1, rect: small, now: 0)
        curtain.windowChanged(id: 2, rect: Rect(x: 0, y: 0, width: 0, height: 0), now: 0)  // degenerate: no tiles
        #expect(curtain.preCovers() == [small])
        curtain.verified(seq: 0, hiddenRects: [], now: 0)
        let tile00 = Rect(x: 10, y: 20, width: 64, height: 64), tile11 = Rect(x: 74, y: 84, width: 36, height: 6)
        curtain.dirty(rects: [Rect(x: 0, y: 0, width: 11, height: 21)], seq: 1, now: 0.1)  // 1 pt into tile (0,0)
        #expect(curtain.preCovers() == [tile00])
        curtain.dirty(rects: [Rect(x: 80, y: 85, width: 5, height: 3)], seq: 2, now: 0.13)  // inside tile (1,1)
        #expect(curtain.preCovers() == [tile00, tile11])
        curtain.dirty(rects: [Rect(x: 74, y: 20, width: 1, height: 70)], seq: 3, now: 0.16)  // column 1, both rows
        #expect(curtain.preCovers() == [Rect(x: 10, y: 20, width: 100, height: 64), tile11])  // row 0 is one run
        curtain.verified(seq: 3, hiddenRects: [], now: 0.2)
        let onTileEdges = Rect(x: 0, y: 0, width: 74, height: 84)  // ends exactly where tiles (1,0) and (0,1) begin
        curtain.dirty(rects: [onTileEdges], seq: 4, now: 0.25)
        #expect(curtain.preCovers() == [tile00])
        let outside = Rect(x: 110, y: 20, width: 50, height: 50)  // starts at the window's maxX
        curtain.dirty(rects: [outside], seq: 5, now: 0.28)
        #expect(curtain.preCovers() == [tile00])
        let corner = Rect(x: 0, y: 0, width: 10, height: 20)  // touches the window's corner only
        curtain.verified(seq: 5, hiddenRects: [corner], now: 0.3)
        #expect(curtain.preCovers().isEmpty)  // not an overlap: the tile clears
    }
}
