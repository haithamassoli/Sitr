// M3-T03 / T05 / T06 / T09 unit tests: the filter plan, the reserved cover-id ranges, attribution on a window snapshot, the visible-
// region clip, fail-closed rect sets, the capture-rate rule and the stall decision. The live halves run under
// `Sitr --selftest filter | curtain | failstate | overlap` (docs/m3/integration.md).
import AppKit
import SitrCore
import Testing

@testable import Sitr

private let own: pid_t = 4242
private let apps = [
    FilterPlan.App(pid: own, bundleID: ""),  // ourselves, a bundle-less `.build/debug/Sitr`
    FilterPlan.App(pid: 100, bundleID: "com.apple.Safari"),
    FilterPlan.App(pid: 200, bundleID: "com.apple.TextEdit"),
    FilterPlan.App(pid: 300, bundleID: "ru.keepcoder.Telegram"),
    FilterPlan.App(pid: 400, bundleID: "com.example.Unlisted"),
]

private func window(_ id: CGWindowID, _ bundle: String?, _ rect: CGRect, z: Int, display: CGDirectDisplayID = 1) -> WindowRect {
    WindowRect(windowID: id, pid: pid_t(1000 + id), bundleID: bundle, displayID: display, rect: rect, zOrder: z)
}

@Suite struct FilterPlanTests {
    @Test func defaultOffIncludesOnlyBlurAndCurtainOverrides() {
        let rules = Rules(defaultMode: .off, overrides: [
            AppRule(bundleID: "com.apple.Safari", mode: .curtain), AppRule(bundleID: "com.apple.TextEdit", mode: .blur),
            AppRule(bundleID: "ru.keepcoder.Telegram", mode: .off), AppRule(bundleID: "com.not.running", mode: .blur),
        ])
        #expect(FilterPlan.compute(rules: rules, apps: apps, ownPID: own) == .include([100, 200]))
        // Nothing overridden: an empty include list (bare desktop), never our own process.
        #expect(FilterPlan.compute(rules: Rules(defaultMode: .off), apps: apps, ownPID: own) == .include([]))
    }

    @Test func defaultOnExcludesOffAppsAndOwnProcess() {
        let rules = Rules(defaultMode: .blur, overrides: [
            AppRule(bundleID: "com.apple.TextEdit", mode: .off), AppRule(bundleID: "com.apple.Safari", mode: .curtain),
        ])
        #expect(FilterPlan.compute(rules: rules, apps: apps, ownPID: own) == .exclude([own, 200]))
        #expect(FilterPlan.compute(rules: Rules(defaultMode: .curtain), apps: apps, ownPID: own) == .exclude([own]))
        // The own process is excluded even when it is not in the app list yet (nothing to exclude) — and never included.
        #expect(FilterPlan.compute(rules: Rules(defaultMode: .blur), apps: Array(apps.dropFirst()), ownPID: own) == .exclude([]))
    }

    @Test func rulesChangeMeansADifferentPlan() {
        var rules = Rules(defaultMode: .blur, overrides: [AppRule(bundleID: "com.apple.TextEdit", mode: .off)])
        let before = FilterPlan.compute(rules: rules, apps: apps, ownPID: own)
        rules.upsert(AppRule(bundleID: "com.apple.TextEdit", mode: .blur))
        #expect(FilterPlan.compute(rules: rules, apps: apps, ownPID: own) != before)
        rules.defaultMode = .off
        #expect(FilterPlan.compute(rules: rules, apps: apps, ownPID: own) == .include([200]))
    }

    @MainActor @Test func builderSchedulesOnRulesChangeOnly() {
        let builder = FilterBuilder(rules: Rules(defaultMode: .blur)) { [] }
        #expect(builder.installs == 0 && builder.plans.isEmpty)
        builder.rules = Rules(defaultMode: .blur)  // same value: no rebuild scheduled (didSet compares)
        builder.rules = Rules(defaultMode: .off)
        #expect(builder.rules.defaultMode == .off)
        #expect(FilterBuilder.debounce == .milliseconds(300))
        builder.stop()
    }
}

@Suite struct CoverIDTests {
    @Test func preCoverAndFailClosedRangesNeverMeetTrackIDs() {
        var seen = Set<Int>()
        for n in 0..<10_000 {
            let id = CoverID.preCover(n)
            #expect(id < 0 && CoverID.isPreCover(id) && !CoverID.isTrack(id) && !CoverID.isFailClosed(id))
            #expect(seen.insert(id).inserted)
        }
        for wid: CGWindowID in [0, 1, 77, 65_535, 1 << 20, CGWindowID.max] {
            for piece in [0, 1, 7, 255, 300] {
                let id = CoverID.failClosed(window: wid, piece: piece)
                #expect(CoverID.isFailClosed(id) && !CoverID.isPreCover(id) && !CoverID.isTrack(id))
                #expect(!CoverID.isPreCover(id))
            }
        }
        // Distinct windows and pieces get distinct ids (pieces cap at 255).
        #expect(CoverID.failClosed(window: 5, piece: 0) != CoverID.failClosed(window: 6, piece: 0))
        #expect(CoverID.failClosed(window: 5, piece: 0) != CoverID.failClosed(window: 5, piece: 1))
        #expect(CoverID.failClosed(window: 5, piece: 255) == CoverID.failClosed(window: 5, piece: 400))
        for track in [1, 2, 1_000, Int.max] { #expect(CoverID.isTrack(track) && !CoverID.isPreCover(track) && !CoverID.isFailClosed(track)) }
        #expect(!CoverID.isTrack(0) && !CoverID.isPreCover(0))
    }
}

@Suite struct AttributionAndClippingTests {
    let back = window(1, "com.apple.Safari", CGRect(x: 0, y: 0, width: 800, height: 600), z: 1)
    let front = window(2, "com.apple.TextEdit", CGRect(x: 400, y: 300, width: 500, height: 400), z: 0)
    let other = window(3, "com.hnc.Discord", CGRect(x: 0, y: 0, width: 800, height: 600), z: 0, display: 2)

    @Test func attributionPicksTheTopmostWindowUnderThePoint() {
        let snapshot = [front, other, back]  // front to back per display, as the tracker publishes
        #expect(snapshot.topmost(at: CGPoint(x: 500, y: 400), on: 1)?.bundleID == "com.apple.TextEdit")  // overlap: the front one
        #expect(snapshot.topmost(at: CGPoint(x: 100, y: 100), on: 1)?.bundleID == "com.apple.Safari")
        #expect(snapshot.topmost(at: CGPoint(x: 100, y: 100), on: 2)?.bundleID == "com.hnc.Discord")  // per display
        #expect(snapshot.topmost(at: CGPoint(x: 1000, y: 100), on: 1) == nil)  // desktop → Default Rule
        // A person whose box centre is under the front window is that app's, whatever the back window shows.
        let person = CGRect(x: 380, y: 280, width: 100, height: 200)
        #expect(snapshot.topmost(at: CGPoint(x: person.midX, y: person.midY), on: 1)?.windowID == 2)
    }

    @Test func subtractLeavesTheVisiblePieces() {
        let r = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(subtract(r, holes: []) == [r])
        #expect(subtract(r, holes: [CGRect(x: 200, y: 200, width: 10, height: 10)]) == [r])
        #expect(subtract(r, holes: [r]).isEmpty)
        #expect(subtract(r, holes: [CGRect(x: -10, y: -10, width: 500, height: 500)]).isEmpty)
        // A hole in the middle: four pieces whose areas add up to the rect minus the hole, none overlapping the hole.
        let hole = CGRect(x: 20, y: 30, width: 40, height: 20)
        let pieces = subtract(r, holes: [hole])
        #expect(pieces.count == 4)
        #expect(abs(pieces.reduce(0) { $0 + $1.area } - (r.area - hole.area)) < 1e-9)
        #expect(pieces.allSatisfy { $0.intersection(hole).isEmpty || $0.intersection(hole).area == 0 })
        // A corner cut: two pieces.
        let corner = subtract(r, holes: [CGRect(x: 50, y: 50, width: 100, height: 100)])
        #expect(corner.count == 2 && abs(corner.reduce(0) { $0 + $1.area } - 7500) < 1e-9)
        // Two holes compose.
        let two = subtract(r, holes: [CGRect(x: 0, y: 0, width: 50, height: 100), CGRect(x: 50, y: 0, width: 50, height: 50)])
        #expect(two.count == 1 && two[0] == CGRect(x: 50, y: 50, width: 50, height: 50))
    }

    @Test func occludersAreTheWindowsAboveOnTheSameDisplay() {
        let snapshot = [front, other, back]
        #expect(snapshot.occluders(of: back) == [front.rect])
        #expect(snapshot.occluders(of: front).isEmpty)
        #expect(snapshot.occluders(of: other).isEmpty)
    }
}

@Suite struct FailClosedAndRateTests {
    let curtainA = window(10, "com.apple.Safari", CGRect(x: 100, y: 100, width: 600, height: 400), z: 2)
    let curtainB = window(11, "com.hnc.Discord", CGRect(x: 800, y: 100, width: 300, height: 300), z: 3)
    let blur = window(12, "com.apple.TextEdit", CGRect(x: 0, y: 0, width: 200, height: 200), z: 1)
    let off = window(13, "com.apple.Notes", CGRect(x: 500, y: 300, width: 300, height: 300), z: 0)
    let elsewhere = window(14, "com.apple.Safari", CGRect(x: 0, y: 0, width: 500, height: 500), z: 4, display: 2)
    let rules = Rules(defaultMode: .blur, overrides: [
        AppRule(bundleID: "com.apple.Safari", mode: .curtain), AppRule(bundleID: "com.hnc.Discord", mode: .curtain),
        AppRule(bundleID: "com.apple.Notes", mode: .off),
    ])
    let color = CGColor(gray: 0.5, alpha: 1)

    @Test func failClosedCoversEveryCurtainWindowOnTheDisplayClippedAndNothingElse() {
        let windows = [off, blur, curtainA, curtainB, elsewhere]
        let specs = failClosedSpecs(windows: windows, rules: rules, displayID: 1, color: color)
        #expect(specs.allSatisfy { CoverID.isFailClosed($0.id) && $0.contents == nil && $0.color == color })
        // B is unobstructed: one piece, its whole rect. A has the Off window over its bottom-right corner and the Blur window over
        // its top-left corner (both stacked above it): three pieces, none under either, area = A minus both overlaps.
        let b = specs.filter { $0.id == CoverID.failClosed(window: 11) }
        #expect(b.count == 1 && b[0].frame == curtainB.rect)
        let a = specs.filter { spec in !b.contains { $0.id == spec.id } }
        #expect(a.count == 3)
        #expect(a.allSatisfy { $0.frame.intersection(off.rect).area == 0 && $0.frame.intersection(blur.rect).area == 0 })
        let hidden = curtainA.rect.intersection(off.rect).area + curtainA.rect.intersection(blur.rect).area
        #expect(abs(a.reduce(0) { $0 + $1.frame.area } - (curtainA.rect.area - hidden)) < 1e-9)
        #expect(Set(a.map(\.id)).count == 3)
        // The Blur window and the Off window get nothing of their own; the other display's Safari window is not on display 1.
        #expect(!specs.contains { $0.frame.intersects(blur.rect) })
        #expect(specs.count == 4)
        #expect(failClosedSpecs(windows: windows, rules: rules, displayID: 2, color: color).map(\.frame) == [elsewhere.rect])
        #expect(failClosedSpecs(windows: [blur, off], rules: rules, displayID: 1, color: color).isEmpty)
    }

    @Test func captureRateFollowsVisibleCurtainWindowsPerDisplay() {
        #expect(captureFPS(windows: [blur, off], rules: rules, displayID: 1, curtainFPS: 30) == 15)
        #expect(captureFPS(windows: [blur, curtainA], rules: rules, displayID: 1, curtainFPS: 30) == 30)
        #expect(captureFPS(windows: [blur, curtainA], rules: rules, displayID: 1, curtainFPS: 60) == 60)
        #expect(captureFPS(windows: [elsewhere], rules: rules, displayID: 1, curtainFPS: 30) == 15)  // Curtain window on another display
        #expect(captureFPS(windows: [elsewhere], rules: rules, displayID: 2, curtainFPS: 30) == 30)
        #expect(captureFPS(windows: [], rules: Rules(defaultMode: .curtain), displayID: 1, curtainFPS: 30) == 15)  // Entire-Mac Curtain, no window
        #expect(captureFPS(windows: [blur], rules: Rules(defaultMode: .curtain), displayID: 1, curtainFPS: 30) == 30)
        #expect(Runtime.curtainFPS == (Int(ProcessInfo.processInfo.environment["SITR_CURTAIN_FPS"] ?? "") ?? 30))
    }

    @Test func stallNeedsAWindowChangeWithoutAFrameForOneSecond() {
        #expect(!Runtime.isStalled(lastFrameAt: 10.0, curtainChangedAt: 9.0, now: 12.0))  // a frame after the change: fine
        #expect(!Runtime.isStalled(lastFrameAt: 8.0, curtainChangedAt: 9.0, now: 9.9))  // too early
        #expect(Runtime.isStalled(lastFrameAt: 8.0, curtainChangedAt: 9.0, now: 10.0))
        #expect(Runtime.isStalled(lastFrameAt: nil, curtainChangedAt: 9.0, now: 10.5))  // never a frame
        #expect(Runtime.stallAfter == 1.0)
    }
}
