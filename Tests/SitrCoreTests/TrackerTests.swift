import Testing
@testable import SitrCore

/// One detection frame at 15 fps.
private let frame = 1.0 / 15.0

private func person(x: Double, y: Double = 0, _ category: Category = .woman) -> PersonObservation {
    PersonObservation(rect: Rect(x: x, y: y, width: 50, height: 100), category: category)
}

@Suite struct TrackerTests {
    @Test func firstObservationCreatesTrack() {
        var tracker = Tracker()
        let tracks = tracker.update([person(x: 10, .man)], at: 1, sequence: 1)
        #expect(tracks.count == 1)
        #expect(tracks[0].id == 1)
        #expect(tracks[0].rect == Rect(x: 10, y: 0, width: 50, height: 100))  // no smoothing without history
        #expect(tracks[0].category == .man)
        #expect(tracks[0].lastSeen == 1)
        #expect(tracks[0].hits == 1)
    }

    @Test func oneFrameDropoutKeepsTrack() {
        var tracker = Tracker()
        tracker.update([person(x: 0)], at: 0, sequence: 0)
        let during = tracker.update([], at: frame, sequence: 1)
        #expect(during.map(\.id) == [1])  // still covered: no flicker
        let after = tracker.update([person(x: 0)], at: 2 * frame, sequence: 2)
        #expect(after.map(\.id) == [1])  // same person, same id
        #expect(after[0].hits == 2)
        #expect(after[0].lastSeen == 2 * frame)
    }

    @Test func trackDropsAfterPersistenceWindow() {
        var tracker = Tracker()
        tracker.update([person(x: 0)], at: 0, sequence: 0)
        #expect(tracker.update([], at: 0.3, sequence: 1).count == 1)  // exactly 300 ms: still there
        #expect(tracker.update([], at: 0.31, sequence: 2).isEmpty)  // > 300 ms: gone
        // A person reappearing later is a new track.
        #expect(tracker.update([person(x: 0)], at: 0.4, sequence: 3).map(\.id) == [2])
    }

    @Test func rectIsSmoothedWithAlphaHalf() {
        var tracker = Tracker()
        tracker.update([PersonObservation(rect: Rect(x: 0, y: 0, width: 50, height: 100), category: .woman)], at: 0, sequence: 0)
        // IoU with the track is 3840 / 6992 ≈ 0.55, so this is a match, not a new track.
        let tracks = tracker.update([PersonObservation(rect: Rect(x: 10, y: 4, width: 54, height: 108), category: .woman)], at: frame, sequence: 1)
        #expect(tracks.count == 1)
        #expect(tracks[0].rect == Rect(x: 5, y: 2, width: 52, height: 104))
    }

    @Test func categoryFlipsAfterExactlyThreeContraryFrames() {
        var tracker = Tracker()
        tracker.update([person(x: 0, .woman)], at: 0, sequence: 0)
        #expect(tracker.update([person(x: 0, .man)], at: 1 * frame, sequence: 1)[0].category == .woman)
        #expect(tracker.update([person(x: 0, .man)], at: 2 * frame, sequence: 2)[0].category == .woman)  // two are not enough
        #expect(tracker.update([person(x: 0, .man)], at: 3 * frame, sequence: 3)[0].category == .man)  // third flips
        #expect(tracker.tracks.map(\.id) == [1])  // same track throughout
    }

    @Test func agreeingFrameResetsContraryStreak() {
        var tracker = Tracker()
        tracker.update([person(x: 0, .woman)], at: 0, sequence: 0)
        tracker.update([person(x: 0, .man)], at: 1 * frame, sequence: 1)
        tracker.update([person(x: 0, .man)], at: 2 * frame, sequence: 2)
        tracker.update([person(x: 0, .woman)], at: 3 * frame, sequence: 3)  // reset
        tracker.update([person(x: 0, .man)], at: 4 * frame, sequence: 4)
        let tracks = tracker.update([person(x: 0, .man)], at: 5 * frame, sequence: 5)
        #expect(tracks[0].category == .woman)  // 2 + 2 contrary frames, never 3 in a row
        #expect(tracker.update([person(x: 0, .man)], at: 6 * frame, sequence: 6)[0].category == .man)
    }

    @Test func contraryFramesMustAgreeWithEachOther() {
        var tracker = Tracker()
        tracker.update([person(x: 0, .woman)], at: 0, sequence: 0)
        tracker.update([person(x: 0, .man)], at: 1 * frame, sequence: 1)
        tracker.update([person(x: 0, .unknown)], at: 2 * frame, sequence: 2)
        #expect(tracker.update([person(x: 0, .man)], at: 3 * frame, sequence: 3)[0].category == .woman)
        #expect(tracker.update([person(x: 0, .unknown)], at: 4 * frame, sequence: 4)[0].category == .woman)
        #expect(tracker.update([person(x: 0, .unknown)], at: 5 * frame, sequence: 5)[0].category == .woman)
        #expect(tracker.update([person(x: 0, .unknown)], at: 6 * frame, sequence: 6)[0].category == .unknown)
    }

    @Test func dropoutDoesNotResetContraryStreak() {
        var tracker = Tracker()
        tracker.update([person(x: 0, .woman)], at: 0, sequence: 0)
        tracker.update([person(x: 0, .man)], at: 1 * frame, sequence: 1)
        tracker.update([person(x: 0, .man)], at: 2 * frame, sequence: 2)
        tracker.update([], at: 3 * frame, sequence: 3)  // missed frame: neither confirms nor denies
        #expect(tracker.update([person(x: 0, .man)], at: 4 * frame, sequence: 4)[0].category == .man)
    }

    @Test func separatePeopleGetSeparateTracks() {
        var tracker = Tracker()
        let tracks = tracker.update([person(x: 0), person(x: 100)], at: 0, sequence: 0)
        #expect(tracks.map(\.id) == [1, 2])
    }

    @Test func crossingPeopleKeepTheirIDsWhenIoUStaysBelowThreshold() {
        // A walks right along y = 0, B walks left along y = 80: their boxes only ever share a 20-pt band, so cross-IoU
        // peaks at 1000 / 9000 ≈ 0.11. Steps of 10 pt with the EMA lagging one step keep own-IoU at 3000 / 7000 ≈ 0.43.
        var tracker = Tracker()
        tracker.update([person(x: 0, y: 0, .woman), person(x: 200, y: 80, .man)], at: 0, sequence: 0)
        for step in 1...20 {
            let x = Double(step) * 10
            let tracks = tracker.update([person(x: x, y: 0, .woman), person(x: 200 - x, y: 80, .man)], at: Double(step) * frame, sequence: step)
            #expect(tracks.map(\.id) == [1, 2])
        }
        let a = tracker.tracks[0], b = tracker.tracks[1]
        #expect(a.category == .woman && a.rect.y == 0 && a.rect.x > 150)  // A ended on the right
        #expect(b.category == .man && b.rect.y == 80 && b.rect.x < 50)  // B ended on the left
        #expect(a.hits == 21 && b.hits == 21)
    }

    @Test func matchingIsGreedyByIoUAndOneToOne() {
        var tracker = Tracker()
        tracker.update([person(x: 0)], at: 0, sequence: 0)
        // Both observations clear 0.3 (IoU 45/55 and 30/70); the closer one wins, the other becomes a new track.
        let tracks = tracker.update([person(x: 20), person(x: 5)], at: frame, sequence: 1)
        #expect(tracks.count == 2)
        #expect(tracks[0].id == 1 && tracks[0].rect.x == 2.5 && tracks[0].hits == 2)
        #expect(tracks[1].id == 2 && tracks[1].rect.x == 20 && tracks[1].hits == 1)
    }

    @Test func observationBelowIoUThresholdStartsNewTrack() {
        var tracker = Tracker()
        tracker.update([person(x: 0)], at: 0, sequence: 0)
        // Shift of 35 of 50: IoU 15/85 ≈ 0.18 < 0.3.
        let tracks = tracker.update([person(x: 35)], at: frame, sequence: 1)
        #expect(tracks.map(\.id) == [1, 2])
        #expect(tracks[0].hits == 1 && tracks[1].hits == 1)
    }

    @Test func outOfOrderFrameIsIgnored() {
        var tracker = Tracker()
        tracker.update([person(x: 0)], at: 2 * frame, sequence: 2)
        let tracks = tracker.update([person(x: 100)], at: frame, sequence: 1)  // stale result arriving late
        #expect(tracks.map(\.id) == [1])
        #expect(tracker.update([person(x: 0)], at: 3 * frame, sequence: 3)[0].hits == 2)
    }

    @Test func mergedUnionsOverlappingBoxesKeepingLowestID() {
        let a = Track(id: 3, rect: Rect(x: 0, y: 0, width: 50, height: 100), category: .woman, lastSeen: 0)
        let b = Track(id: 1, rect: Rect(x: 40, y: 20, width: 50, height: 100), category: .unknown, lastSeen: 0)
        let far = Track(id: 2, rect: Rect(x: 500, y: 0, width: 50, height: 100), category: .woman, lastSeen: 0)
        let merged = Tracker.merged([a, b, far])
        #expect(merged.count == 2)
        #expect(merged[0].id == 1 && merged[0].rect == Rect(x: 0, y: 0, width: 90, height: 120))
        #expect(merged[1].id == 2 && merged[1].rect == far.rect)
    }

    @Test func mergedIsTransitiveAndIgnoresTouchingEdges() {
        // a–b overlap, b–c overlap, a–c do not: one group. d only touches c's edge: separate.
        let a = Track(id: 1, rect: Rect(x: 0, y: 0, width: 50, height: 100), category: .woman, lastSeen: 0)
        let b = Track(id: 2, rect: Rect(x: 40, y: 0, width: 50, height: 100), category: .woman, lastSeen: 0)
        let c = Track(id: 3, rect: Rect(x: 80, y: 0, width: 50, height: 100), category: .woman, lastSeen: 0)
        let d = Track(id: 4, rect: Rect(x: 130, y: 0, width: 50, height: 100), category: .woman, lastSeen: 0)
        let merged = Tracker.merged([c, a, d, b])
        #expect(merged.map(\.id) == [1, 4])
        #expect(merged[0].rect == Rect(x: 0, y: 0, width: 130, height: 100))
        #expect(merged[1].rect == d.rect)
        #expect(Tracker.merged([]).isEmpty)
    }
}
