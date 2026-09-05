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

private func track(_ id: Int, _ category: Category, x: Double = 0, app: String? = nil) -> Track {
    Track(id: id, rect: Rect(x: x, y: 0, width: 50, height: 100), category: category, lastSeen: 0, bundleID: app)
}

/// M2's "Entire Mac" Blur: the Default Rule is Off since M3-T01, so tests about who gets covered set Blur explicitly.
private let blurAll = Rules(defaultMode: .blur)

@Suite struct PolicyTests {
    @Test(arguments: coverageMatrix)
    func hiddenSetTimesStrictTimesCategory(hiddenSet: HiddenSet, strict: Bool, covered: Set<Category>) {
        let policy = Policy(hiddenSet: hiddenSet, strictMode: strict, rules: blurAll)
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

    @Test func coverCarriesTrackIDRectAndMode() {
        let policy = Policy(hiddenSet: .women, rules: blurAll)
        let covers = policy.covers(for: [track(7, .woman, x: 30), track(8, .man, x: 300)], now: 0)
        #expect(covers == [Cover(trackID: 7, rect: Rect(x: 30, y: 0, width: 50, height: 100), mode: .blur)])
        #expect(Rules().defaultMode == .off)  // PRD: the Default Rule starts Off
    }

    @Test func pausedYieldsNoCoversThenAutoResumes() {
        let policy = Policy(hiddenSet: .everyone, protection: .paused(until: 100), rules: blurAll)
        let tracks = [track(1, .woman)]
        #expect(policy.covers(for: tracks, now: 50).isEmpty)
        #expect(!policy.isProtecting(at: 99.99))
        #expect(policy.covers(for: tracks, now: 100).count == 1)  // deadline reached: active again
        #expect(policy.covers(for: tracks, now: 5000).count == 1)
    }

    @Test func disabledYieldsNoCovers() {
        let policy = Policy(hiddenSet: .everyone, protection: .disabled, rules: blurAll)
        #expect(policy.covers(for: [track(1, .woman), track(2, .unknown)], now: 0).isEmpty)
        #expect(!policy.isProtecting(at: 1e9))
    }

    @Test func needsPermissionFailsOpenAndDegradedKeepsCovering() {
        let tracks = [track(1, .woman)]
        func covers(_ health: Health) -> Int {
            Policy(hiddenSet: .everyone, health: health, rules: blurAll).covers(for: tracks, now: 0).count
        }
        #expect(covers(.needsPermission) == 0)
        #expect(covers(.degraded) == 1)
        #expect(covers(.ok) == 1)
    }

    @Test func overlappingHiddenTracksMergeIntoOneCover() {
        let policy = Policy(hiddenSet: .women, strictMode: false, rules: blurAll)
        let hiddenA = track(2, .woman, x: 0)
        let hiddenB = track(1, .woman, x: 40)
        let shownOverlapping = track(3, .man, x: 60)  // overlaps both, but is not hidden: must not grow the cover
        let covers = policy.covers(for: [hiddenA, hiddenB, shownOverlapping], now: 0)
        #expect(covers == [Cover(trackID: 1, rect: Rect(x: 0, y: 0, width: 90, height: 100), mode: .blur)])
    }

    @Test func noTracksNoCovers() {
        #expect(Policy(hiddenSet: .everyone, rules: blurAll).covers(for: [], now: 0).isEmpty)
    }

    @Test func defaultRuleOffCoversNothingUntilAnAppIsMonitored() {
        let unknownOwner = track(1, .woman)
        #expect(Policy(hiddenSet: .everyone).covers(for: [unknownOwner], now: 0).isEmpty)
        var rules = Rules()
        rules.upsert(AppRule(bundleID: "com.apple.Safari", mode: .curtain))
        let policy = Policy(hiddenSet: .everyone, rules: rules)
        #expect(policy.covers(for: [unknownOwner], now: 0).isEmpty)  // nil owner → Default Rule, still Off
        #expect(policy.covers(for: [track(2, .woman, app: "com.apple.Notes")], now: 0).isEmpty)  // no override → Off
        #expect(policy.covers(for: [track(3, .woman, app: "com.apple.Safari")], now: 0).map(\.mode) == [.curtain])
    }

    @Test func coverModeFollowsEachTracksApp() {
        var rules = Rules(defaultMode: .blur)
        rules.upsert(AppRule(bundleID: "com.apple.Safari", mode: .curtain))
        rules.upsert(AppRule(bundleID: "com.apple.Notes", mode: .off))
        let policy = Policy(hiddenSet: .everyone, rules: rules)
        let covers = policy.covers(
            for: [
                track(1, .woman, x: 0, app: "com.apple.Safari"),
                track(2, .woman, x: 200, app: "com.apple.Notes"),  // Off wins for that app only
                track(3, .woman, x: 400, app: "com.example.Unknown"),
                track(4, .woman, x: 600),
            ], now: 0)
        #expect(covers.map(\.trackID) == [1, 3, 4])
        #expect(covers.map(\.mode) == [.curtain, .blur, .blur])
    }

    @Test func overlappingTracksMergeOnlyWithinOneMode() {
        var rules = Rules(defaultMode: .blur)
        rules.upsert(AppRule(bundleID: "com.apple.Safari", mode: .curtain))
        let policy = Policy(hiddenSet: .everyone, rules: rules)
        // All three overlap: the two Blur tracks merge, the Curtain one stays its own cover.
        let covers = policy.covers(
            for: [track(1, .woman, x: 0, app: "com.apple.Safari"), track(2, .woman, x: 20), track(3, .woman, x: 40)],
            now: 0)
        #expect(
            covers == [
                Cover(trackID: 1, rect: Rect(x: 0, y: 0, width: 50, height: 100), mode: .curtain),
                Cover(trackID: 2, rect: Rect(x: 20, y: 0, width: 70, height: 100), mode: .blur),
            ])
    }
}
