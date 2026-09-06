// M3-T02 WindowTracker: pure geometry on synthetic 2-display layouts, parse filters on synthetic window-list entries, a live
// WindowServer query (windows + bundle IDs), and the poll-cost measurement. Prints counts and bundle IDs only, never titles.
import AppKit
import Testing

@testable import Sitr

// The spike machine's built-in display as the main display, in CG space (origin top-left, y down).
private let main: WindowGeometry.Display = (id: 1, bounds: CGRect(x: 0, y: 0, width: 1470, height: 956))

private func byDisplay(_ parts: [(id: CGDirectDisplayID, localRect: CGRect)]) -> [CGDirectDisplayID: CGRect] {
    Dictionary(uniqueKeysWithValues: parts.map { ($0.id, $0.localRect) })
}

private func threadCPUms() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
    return Double(ts.tv_sec) * 1000 + Double(ts.tv_nsec) / 1e6
}

// MARK: - WindowGeometry.split

@Suite struct WindowGeometrySplitTests {
    @Test func secondaryAbove() {
        // Above the main display = negative y in CG space; a 1920×1080 display centred over the 1470-wide main one.
        let above: WindowGeometry.Display = (id: 2, bounds: CGRect(x: -225, y: -1080, width: 1920, height: 1080))
        let only = WindowGeometry.split(globalRect: CGRect(x: 100, y: -500, width: 400, height: 300), displays: [main, above])
        #expect(byDisplay(only) == [2: CGRect(x: 325, y: 580, width: 400, height: 300)])
        // Straddling the shared edge: the bottom 100 pt land at the top of the main display.
        let both = WindowGeometry.split(globalRect: CGRect(x: 100, y: -100, width: 200, height: 200), displays: [main, above])
        #expect(byDisplay(both) == [1: CGRect(x: 100, y: 0, width: 200, height: 100), 2: CGRect(x: 325, y: 980, width: 200, height: 100)])
    }

    @Test func secondaryLeft() {
        let left: WindowGeometry.Display = (id: 2, bounds: CGRect(x: -1920, y: -124, width: 1920, height: 1080))
        let only = WindowGeometry.split(globalRect: CGRect(x: -1800, y: 100, width: 300, height: 200), displays: [main, left])
        #expect(byDisplay(only) == [2: CGRect(x: 120, y: 224, width: 300, height: 200)])
        let both = WindowGeometry.split(globalRect: CGRect(x: -150, y: 10, width: 300, height: 50), displays: [main, left])
        #expect(byDisplay(both) == [1: CGRect(x: 0, y: 10, width: 150, height: 50), 2: CGRect(x: 1770, y: 134, width: 150, height: 50)])
    }

    @Test func secondaryRight() {
        let right: WindowGeometry.Display = (id: 2, bounds: CGRect(x: 1470, y: 0, width: 1920, height: 1080))
        let only = WindowGeometry.split(globalRect: CGRect(x: 1500, y: 50, width: 300, height: 200), displays: [main, right])
        #expect(byDisplay(only) == [2: CGRect(x: 30, y: 50, width: 300, height: 200)])
        // Straddling: one entry per display, in `displays` order, each clipped to its display.
        let both = WindowGeometry.split(globalRect: CGRect(x: 1270, y: 100, width: 400, height: 300), displays: [main, right])
        #expect(both.map(\.id) == [1, 2])
        #expect(byDisplay(both) == [1: CGRect(x: 1270, y: 100, width: 200, height: 300), 2: CGRect(x: 0, y: 100, width: 200, height: 300)])
    }

    @Test func offScreenEdgeTouchingAndHangingOff() {
        let right: WindowGeometry.Display = (id: 2, bounds: CGRect(x: 1470, y: 0, width: 1920, height: 1080))
        #expect(WindowGeometry.split(globalRect: CGRect(x: 5000, y: 5000, width: 100, height: 100), displays: [main, right]).isEmpty)
        #expect(WindowGeometry.split(globalRect: CGRect(x: 0, y: 956, width: 100, height: 100), displays: [main]).isEmpty)  // touches, no overlap
        #expect(WindowGeometry.split(globalRect: .zero, displays: [main]).isEmpty)
        // Hanging off the bottom of the main display: clipped to the 56 pt that are visible.
        let hanging = WindowGeometry.split(globalRect: CGRect(x: 100, y: 900, width: 200, height: 200), displays: [main, right])
        #expect(byDisplay(hanging) == [1: CGRect(x: 100, y: 900, width: 200, height: 56)])
        #expect(WindowGeometry.split(globalRect: CGRect(x: 0, y: 0, width: 10, height: 10), displays: []).isEmpty)
    }
}

// MARK: - WindowGeometry.parse

private func entry(_ id: Int, pid: Int, layer: Int = 0, alpha: Double = 1, bounds: CGRect?) -> [String: Any] {
    var d: [String: Any] = [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer,
                            kCGWindowAlpha as String: alpha]
    if let bounds { d[kCGWindowBounds as String] = bounds.dictionaryRepresentation }
    return d
}

@Suite struct WindowGeometryParseTests {
    @Test func filtersLayerAlphaSizeAndAssignsZOrder() {
        let right: WindowGeometry.Display = (id: 2, bounds: CGRect(x: 1470, y: 0, width: 1920, height: 1080))
        let list: [[String: Any]] = [
            entry(10, pid: 100, bounds: CGRect(x: 10, y: 20, width: 300, height: 200)),  // kept, z 0
            entry(11, pid: 1, layer: 24, bounds: CGRect(x: 0, y: 0, width: 1470, height: 24)),  // menu bar layer → skipped
            entry(12, pid: 100, alpha: 0, bounds: CGRect(x: 0, y: 0, width: 500, height: 500)),  // invisible → skipped
            entry(13, pid: 200, bounds: CGRect(x: 50, y: 50, width: 7, height: 100)),  // narrower than 8 pt → skipped
            entry(14, pid: 200, bounds: CGRect(x: 1370, y: 100, width: 200, height: 100)),  // straddles both displays, z 1
            entry(15, pid: 300, bounds: nil),  // no bounds → skipped
            entry(16, pid: 300, bounds: CGRect(x: 9000, y: 0, width: 100, height: 100)),  // off every display → skipped, no z
            entry(17, pid: 400, bounds: CGRect(x: 0, y: 0, width: 8, height: 8)),  // exactly 8×8 → kept, z 2
        ]
        let out = WindowGeometry.parse(list as CFArray, displays: [main, right])
        #expect(out.map(\.windowID) == [10, 14, 14, 17])
        #expect(out.map(\.zOrder) == [0, 1, 1, 2])
        #expect(out.map(\.pid) == [100, 200, 200, 400])
        #expect(out.map(\.displayID) == [1, 1, 2, 1])
        #expect(out[0].rect == CGRect(x: 10, y: 20, width: 300, height: 200))
        #expect(out[1].rect == CGRect(x: 1370, y: 100, width: 100, height: 100))
        #expect(out[2].rect == CGRect(x: 0, y: 100, width: 100, height: 100))
        #expect(out.allSatisfy { $0.bundleID == nil })
    }

    @Test func toleratesMissingAndOddEntries() {
        #expect(WindowGeometry.parse(nil, displays: [main]).isEmpty)
        #expect(WindowGeometry.parse([] as CFArray, displays: [main]).isEmpty)
        // A non-dictionary element, a string where a number belongs, a number where the bounds dictionary belongs.
        let odd: [Any] = ["not a window", [kCGWindowNumber as String: "1", kCGWindowLayer as String: 0],
                          entry(1, pid: 1, bounds: nil).merging([kCGWindowBounds as String: 5]) { _, new in new }]
        #expect(WindowGeometry.parse(odd as CFArray, displays: [main]).isEmpty)
    }
}

// MARK: - Live WindowServer query

@Suite(.serialized) @MainActor struct WindowTrackerLiveTests {
    @Test func queryReturnsWindowsAndResolvesBundleIDs() {
        let tracker = WindowTracker()
        tracker.refresh()
        let ws = tracker.windows
        #expect(!ws.isEmpty, "no on-screen layer-0 windows; is the screen locked?")
        let displayIDs = Set(NSScreen.screens.compactMap(\.displayID))
        for w in ws {
            #expect(displayIDs.contains(w.displayID))
            #expect(w.rect.width > 0 && w.rect.height > 0)
            #expect(w.rect.minX >= 0 && w.rect.minY >= 0)  // display-local, clipped: never negative
        }
        #expect(ws.map(\.zOrder) == ws.map(\.zOrder).sorted())
        let apps = Set(ws.compactMap(\.bundleID))
        #expect(!apps.isEmpty, "PID → bundle ID resolution found no app")
        // The frontmost window's centre is attributed to that window.
        if let front = ws.first {
            let hit = tracker.topmostWindow(at: CGPoint(x: front.rect.midX, y: front.rect.midY), on: front.displayID)
            #expect(hit?.windowID == front.windowID && hit?.zOrder == 0)
        }
        #expect(tracker.topmostWindow(at: CGPoint(x: -1, y: -1), on: displayIDs.first ?? 0) == nil)
        if let some = ws.first(where: { $0.bundleID != nil }), let bid = some.bundleID {
            let own = tracker.windows(for: bid)
            #expect(own.contains(some) && own.allSatisfy { $0.bundleID == bid })
        }
        #expect(tracker.windows(for: "com.goldentik.no-such-app").isEmpty)
        print("window_tracker: windows=\(ws.count) displays=\(displayIDs.count) apps=\(apps.count) bundle_ids=\(apps.sorted())")
    }

    @Test func startPollsAndStopClears() async throws {
        let tracker = WindowTracker()
        tracker.start()
        tracker.start()  // idempotent
        #expect(!tracker.windows.isEmpty)  // start() refreshes synchronously
        try await Task.sleep(for: .milliseconds(250))
        #expect(!tracker.windows.isEmpty)
        tracker.stop()
        #expect(tracker.windows.isEmpty)
    }

    /// Gate (docs/tasks.md M3-T02): poll cost < 0.3 % of one core at 10 Hz. Own-thread CPU is the gated number (the IPC wait in
    /// `wall` is WindowServer's time, not ours); hard-checked only in a quiet phase (load1 ≤ 4), like the render selftest.
    @Test func pollCost() {
        let tracker = WindowTracker()
        tracker.refresh()  // warm: bundle IDs cached, as in steady state
        let n = 100
        var wall0 = CFAbsoluteTimeGetCurrent(), cpu0 = threadCPUms()
        for _ in 0..<n { tracker.refresh() }
        let refreshWall = (CFAbsoluteTimeGetCurrent() - wall0) * 1000 / Double(n)
        let refreshCPU = (threadCPUms() - cpu0) / Double(n)
        wall0 = CFAbsoluteTimeGetCurrent()
        cpu0 = threadCPUms()
        for _ in 0..<n { _ = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) }
        let queryWall = (CFAbsoluteTimeGetCurrent() - wall0) * 1000 / Double(n)
        let queryCPU = (threadCPUms() - cpu0) / Double(n)
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        let quiet = load[0] <= 4
        // At 10 Hz, ms per call == % of one core (10 calls × ms ÷ 1000 ms × 100).
        print(String(format: "window_tracker_poll: n=%d windows=%d refresh wall=%.3f ms cpu=%.3f ms | query_only wall=%.3f ms cpu=%.3f ms"
                     + " | at 10 Hz: cpu=%.2f%% wall=%.2f%% | load1=%.1f timing_gated=%@",
                     n, tracker.windows.count, refreshWall, refreshCPU, queryWall, queryCPU, refreshCPU, refreshWall, load[0], quiet ? "true" : "false"))
        #expect(refreshWall < 20)  // sanity under any load
        if quiet { #expect(refreshCPU < 0.3, "poll cost over the 0.3 % gate; drop to 5 Hz") }
    }
}
