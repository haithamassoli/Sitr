import Testing
@testable import SitrCore

/// Expected covered categories for every hidden set × Strict Mode (PRD Definitions: Everyone forces Strict on).
private let coverageMatrix: [(hiddenSet: HiddenSet, strict: Bool, covered: Set<Category>)] = [
    (.women, true, [.woman, .unknown]),
    (.women, false, [.woman]),
    (.men, true, [.man, .unknown]),
    (.men, false, [.man]),
    (.everyone, true, [.woman, .man, .unknown]),
    (.everyone, false, [.woman, .man, .unknown]),
]

private func track(_ id: Int, _ category: Category, x: Double = 0) -> Track {
    Track(id: id, rect: Rect(x: x, y: 0, width: 50, height: 100), category: category, lastSeen: 0)
}

@Suite struct PolicyTests {
    @Test(arguments: coverageMatrix)
    func hiddenSetTimesStrictTimesCategory(hiddenSet: HiddenSet, strict: Bool, covered: Set<Category>) {
        let policy = Policy(hiddenSet: hiddenSet, strictMode: strict)
        for category in [Category.woman, .man, .unknown] {
            let covers = policy.covers(for: [track(1, category)], now: 0)
            #expect(covers.count == (covered.contains(category) ? 1 : 0), "\(hiddenSet) strict=\(strict) \(category)")
            #expect(policy.hides(category) == covered.contains(category))
        }
    }

    @Test func everyoneForcesStrict() {
        #expect(Policy(hiddenSet: .everyone, strictMode: false).effectiveStrict)
        #expect(Policy(hiddenSet: .everyone, strictMode: true).effectiveStrict)
        #expect(!Policy(hiddenSet: .women, strictMode: false).effectiveStrict)
        #expect(Policy(hiddenSet: .women, strictMode: true).effectiveStrict)
        #expect(!Policy(hiddenSet: .men, strictMode: false).effectiveStrict)
    }

    @Test func coverCarriesTrackIDRectAndDefaultBlur() {
        let policy = Policy(hiddenSet: .women)
        let covers = policy.covers(for: [track(7, .woman, x: 30), track(8, .man, x: 300)], now: 0)
        #expect(covers == [Cover(trackID: 7, rect: Rect(x: 30, y: 0, width: 50, height: 100), mode: .blur)])
        #expect(Rules().defaultMode == .blur)
    }

    @Test func pausedYieldsNoCoversThenAutoResumes() {
        let policy = Policy(hiddenSet: .everyone, protection: .paused(until: 100))
        let tracks = [track(1, .woman)]
        #expect(policy.covers(for: tracks, now: 50).isEmpty)
        #expect(!policy.isProtecting(at: 99.99))
        #expect(policy.covers(for: tracks, now: 100).count == 1)  // deadline reached: active again
        #expect(policy.covers(for: tracks, now: 5000).count == 1)
    }

    @Test func disabledYieldsNoCovers() {
        let policy = Policy(hiddenSet: .everyone, protection: .disabled)
        #expect(policy.covers(for: [track(1, .woman), track(2, .unknown)], now: 0).isEmpty)
        #expect(!policy.isProtecting(at: 1e9))
    }

    @Test func needsPermissionFailsOpenAndDegradedKeepsCovering() {
        #expect(Policy(hiddenSet: .everyone, health: .needsPermission).covers(for: [track(1, .woman)], now: 0).isEmpty)
        #expect(Policy(hiddenSet: .everyone, health: .degraded).covers(for: [track(1, .woman)], now: 0).count == 1)
        #expect(Policy(hiddenSet: .everyone, health: .ok).covers(for: [track(1, .woman)], now: 0).count == 1)
    }

    @Test func overlappingHiddenTracksMergeIntoOneCover() {
        let policy = Policy(hiddenSet: .women, strictMode: false)
        let hiddenA = track(2, .woman, x: 0)
        let hiddenB = track(1, .woman, x: 40)
        let shownOverlapping = track(3, .man, x: 60)  // overlaps both, but is not hidden: must not grow the cover
        let covers = policy.covers(for: [hiddenA, hiddenB, shownOverlapping], now: 0)
        #expect(covers == [Cover(trackID: 1, rect: Rect(x: 0, y: 0, width: 90, height: 100), mode: .blur)])
    }

    @Test func noTracksNoCovers() {
        #expect(Policy(hiddenSet: .everyone).covers(for: [], now: 0).isEmpty)
    }
}
