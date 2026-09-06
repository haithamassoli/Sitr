// M4-T10 app-layer tests: the reconciliation invariant — exactly one pipeline, one overlay panel and one capture stream
// per managed display — through twenty synthetic sleep/wake cycles, lock/unlock, fast user switching, display hot-plug,
// mirroring, resolution changes and repeated no-op reconciliations (what Stage Manager and a Space switch look like from
// here). The topology is `DisplayManager.simulatedScreens`, so nothing touches ScreenCaptureKit, the real displays or the
// user's screen; the live half is `Sitr --selftest robustness` and the manual sleep runs in docs/m4/robustness.md.
import AppKit
import Foundation
import SitrCore
import Testing

@testable import Sitr

/// Serialized: `OverlayPanel.openCount` and `CaptureSession.liveStreams` are process-wide counters, and every test here
/// asserts on them. Each test still measures against its own baseline, so a leak from elsewhere cannot be mistaken for a
/// pass.
@MainActor @Suite(.serialized) struct RobustnessTests {
    /// A runtime whose displays are synthetic: simulated sessions (no ScreenCaptureKit), panels that are never ordered on
    /// screen, no window tracker, no filters, no models. Only the topology wiring is live.
    private func makeRuntime(_ screens: [ScreenSnapshot]) -> (runtime: Runtime, suite: String) {
        let suite = "SitrTests.\(UUID().uuidString)"
        let runtime = Runtime(model: AppModel(preferences: Preferences(defaults: UserDefaults(suiteName: suite)!)))
        runtime.displayManager.simulatedScreens = screens
        runtime.displayManager.start()
        runtime.reconcileNow()
        return (runtime, suite)
    }

    private func tearDown(_ runtime: Runtime, _ suite: String) async {
        await runtime.stop()
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    private func screen(_ id: CGDirectDisplayID, x: CGFloat = 0, width: CGFloat = 1440, height: CGFloat = 900,
                        scale: CGFloat = 2, mirrors: CGDirectDisplayID = 0) -> ScreenSnapshot {
        ScreenSnapshot(id: id, frame: CGRect(x: x, y: 0, width: width, height: height), scale: scale, mirrors: mirrors)
    }

    /// One of everything per display, and the ids agree everywhere.
    private func expectOnePerDisplay(_ runtime: Runtime, _ ids: [CGDirectDisplayID],
                                     panels: Int, streams: Int, _ what: Comment) {
        let managed = runtime.displayManager.displays
        #expect(managed.map(\.id).sorted() == ids.sorted(), what)
        #expect(Set(managed.map(\.id)).count == managed.count, what)  // never the same display twice
        #expect(runtime.pipelines.keys.sorted() == ids.sorted(), what)
        #expect(OverlayPanel.openCount == panels + ids.count, what)
        #expect(CaptureSession.liveStreams == streams + ids.count, what)
        #expect(Set(managed.map { ObjectIdentifier($0.panel) }).count == ids.count, what)  // one panel object each
    }

    // MARK: the done-when, synthetically

    @Test func twentySleepWakeCyclesLeaveOneStreamAndOnePanelPerDisplay() async {
        let panels = OverlayPanel.openCount, streams = CaptureSession.liveStreams
        let ids: [CGDirectDisplayID] = [11, 12]
        let (runtime, suite) = makeRuntime([screen(11), screen(12, x: 1440)])
        expectOnePerDisplay(runtime, ids, panels: panels, streams: streams, "before the first sleep")
        // The objects must survive the cycles: a sleep that rebuilds panels or sessions is how duplicates appear.
        let sessions = runtime.displayManager.displays.map { ObjectIdentifier($0.session) }.sorted { $0.hashValue < $1.hashValue }
        let panelIDs = runtime.displayManager.displays.map { ObjectIdentifier($0.panel) }.sorted { $0.hashValue < $1.hashValue }

        for cycle in 1...20 {
            runtime.systemEvents.simulate(.willSleep)
            #expect(runtime.systemEvents.state == .suspended, "cycle \(cycle)")
            #expect(CaptureSession.liveStreams == streams, "cycle \(cycle): every stream is parked")
            #expect(OverlayPanel.openCount == panels + ids.count, "cycle \(cycle): panels are never closed for a sleep")
            #expect(runtime.pipelines.count == ids.count, "cycle \(cycle): pipelines are never torn down for a sleep")

            runtime.systemEvents.simulate(.didWake)
            #expect(runtime.systemEvents.state == .resuming, "cycle \(cycle)")
            expectOnePerDisplay(runtime, ids, panels: panels, streams: streams, "cycle \(cycle) after the wake")
        }
        #expect(runtime.displayManager.displays.map { ObjectIdentifier($0.session) }.sorted { $0.hashValue < $1.hashValue } == sessions)
        #expect(runtime.displayManager.displays.map { ObjectIdentifier($0.panel) }.sorted { $0.hashValue < $1.hashValue } == panelIDs)
        #expect(runtime.pendingStallChecks == 0)  // no watch task left behind by twenty transitions

        await tearDown(runtime, suite)
        #expect(OverlayPanel.openCount == panels && CaptureSession.liveStreams == streams)  // nothing leaked
    }

    @Test func lockUnlockAndFastUserSwitchingHoldTheSameInvariant() async {
        let panels = OverlayPanel.openCount, streams = CaptureSession.liveStreams
        let (runtime, suite) = makeRuntime([screen(21)])
        let pairs: [(SystemActivityMachine.Event, SystemActivityMachine.Event)] = [
            (.screenLocked, .screenUnlocked),
            (.sessionResignedActive, .sessionBecameActive),  // fast user switching
            (.screensDidSleep, .screensDidWake),
        ]
        for _ in 0..<7 {
            for (down, up) in pairs {
                runtime.systemEvents.simulate(down)
                #expect(CaptureSession.liveStreams == streams)
                runtime.systemEvents.simulate(up)
                expectOnePerDisplay(runtime, [21], panels: panels, streams: streams, "after \(up)")
            }
        }
        await tearDown(runtime, suite)
        #expect(OverlayPanel.openCount == panels && CaptureSession.liveStreams == streams)
    }

    @Test func anUnlockThatArrivesBeforeTheWakeDoesNotRestartCapture() async {
        let panels = OverlayPanel.openCount, streams = CaptureSession.liveStreams
        let (runtime, suite) = makeRuntime([screen(31)])
        // A MacBook lid close: lock, screens off, sleep. Opening it again clears them one at a time.
        for event in [SystemActivityMachine.Event.screenLocked, .screensDidSleep, .willSleep] { runtime.systemEvents.simulate(event) }
        #expect(CaptureSession.liveStreams == streams)
        runtime.systemEvents.simulate(.screenUnlocked)
        #expect(CaptureSession.liveStreams == streams, "still asleep: nothing to capture")
        runtime.systemEvents.simulate(.screensDidWake)
        #expect(CaptureSession.liveStreams == streams)
        runtime.systemEvents.simulate(.didWake)
        expectOnePerDisplay(runtime, [31], panels: panels, streams: streams, "the last reason cleared")
        await tearDown(runtime, suite)
    }

    // MARK: hot-plug

    @Test func hotPlugAddsAndRemovesExactlyOneOfEverything() async {
        let panels = OverlayPanel.openCount, streams = CaptureSession.liveStreams
        let (runtime, suite) = makeRuntime([screen(41)])
        expectOnePerDisplay(runtime, [41], panels: panels, streams: streams, "built-in only")

        runtime.displayManager.simulatedScreens = [screen(41), screen(42, x: 1440, width: 2560, height: 1440, scale: 1)]
        runtime.reconcileNow()
        expectOnePerDisplay(runtime, [41, 42], panels: panels, streams: streams, "external plugged in")

        // The same list again, several times: what a burst of screen-parameter notifications looks like.
        for _ in 0..<5 { runtime.reconcileNow() }
        expectOnePerDisplay(runtime, [41, 42], panels: panels, streams: streams, "repeated reconciliation")

        runtime.displayManager.simulatedScreens = [screen(41)]
        runtime.reconcileNow()
        expectOnePerDisplay(runtime, [41], panels: panels, streams: streams, "external unplugged")
        await tearDown(runtime, suite)
        #expect(OverlayPanel.openCount == panels && CaptureSession.liveStreams == streams)
    }

    @Test func aDisplayUnpluggedWhileAsleepIsGoneByTheFirstFrameAfterTheWake() async {
        let panels = OverlayPanel.openCount, streams = CaptureSession.liveStreams
        let (runtime, suite) = makeRuntime([screen(51), screen(52, x: 1440)])
        runtime.systemEvents.simulate(.willSleep)
        runtime.displayManager.simulatedScreens = [screen(51)]  // unplugged in the bag
        runtime.systemEvents.simulate(.didWake)
        expectOnePerDisplay(runtime, [51], panels: panels, streams: streams, "woke with one display")

        // And the other way round: plugged into a dock while asleep.
        runtime.systemEvents.simulate(.willSleep)
        runtime.displayManager.simulatedScreens = [screen(51), screen(53, x: 1440), screen(54, x: 4000)]
        runtime.systemEvents.simulate(.didWake)
        expectOnePerDisplay(runtime, [51, 53, 54], panels: panels, streams: streams, "woke on a dock")
        await tearDown(runtime, suite)
        #expect(OverlayPanel.openCount == panels && CaptureSession.liveStreams == streams)
    }

    // MARK: mirroring

    @Test func aMirrorSetGetsOnePanelAndOneStream() async {
        let panels = OverlayPanel.openCount, streams = CaptureSession.liveStreams
        let (runtime, suite) = makeRuntime([screen(61), screen(62, x: 1440)])
        expectOnePerDisplay(runtime, [61, 62], panels: panels, streams: streams, "two independent displays")

        // Mirroring turned on: 62 now shows 61's pixels. A panel on both would draw every cover twice.
        runtime.displayManager.simulatedScreens = [screen(61), screen(62, mirrors: 61)]
        runtime.reconcileNow()
        expectOnePerDisplay(runtime, [61], panels: panels, streams: streams, "mirrored")

        // Some drivers report the mirror set as the same id twice instead.
        runtime.displayManager.simulatedScreens = [screen(61), screen(61)]
        runtime.reconcileNow()
        expectOnePerDisplay(runtime, [61], panels: panels, streams: streams, "the same id twice")

        runtime.displayManager.simulatedScreens = [screen(61), screen(62, x: 1440)]
        runtime.reconcileNow()
        expectOnePerDisplay(runtime, [61, 62], panels: panels, streams: streams, "mirroring off again")
        await tearDown(runtime, suite)
        #expect(OverlayPanel.openCount == panels && CaptureSession.liveStreams == streams)
    }

    // MARK: geometry, Stage Manager, Spaces

    @Test func aResolutionChangeRestartsTheStreamWithoutASecondPanel() async {
        let panels = OverlayPanel.openCount, streams = CaptureSession.liveStreams
        let (runtime, suite) = makeRuntime([screen(71)])
        let before = runtime.displayManager.displays[0]
        runtime.displayManager.simulatedScreens = [screen(71, width: 1920, height: 1080, scale: 1)]
        runtime.reconcileNow()
        expectOnePerDisplay(runtime, [71], panels: panels, streams: streams, "after the resolution change")
        let after = runtime.displayManager.displays[0]
        #expect(ObjectIdentifier(after.panel) == ObjectIdentifier(before.panel))  // moved, not replaced
        #expect(ObjectIdentifier(after.session) == ObjectIdentifier(before.session))
        #expect(after.frame == CGRect(x: 0, y: 0, width: 1920, height: 1080) && after.scale == 1)
        #expect(after.panel.frame.size == CGSize(width: 1920, height: 1080))
        await tearDown(runtime, suite)
    }

    /// Stage Manager and a Space switch move windows, not displays: the screen list is identical afterwards, so the only
    /// thing that must survive is repeated no-op reconciliation. The panel properties that keep a cover on screen through
    /// both are checked on the real `OverlayPanel` here, since neither can be driven from a unit test.
    @Test func stageManagerAndSpaceSwitchesNeitherHideNorDuplicateAPanel() async {
        let panels = OverlayPanel.openCount, streams = CaptureSession.liveStreams
        let (runtime, suite) = makeRuntime([screen(81)])
        let panel = runtime.displayManager.displays[0].panel
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))  // a Space switch does not take the cover away
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))  // nor does a fullscreen app
        #expect(panel.collectionBehavior.contains(.stationary))
        #expect(panel.level.rawValue > NSWindow.Level.screenSaver.rawValue)  // above Stage Manager's strip and its windows
        #expect(!panel.hidesOnDeactivate && panel.ignoresMouseEvents && !panel.isReleasedWhenClosed)

        for _ in 0..<20 { runtime.reconcileNow() }
        expectOnePerDisplay(runtime, [81], panels: panels, streams: streams, "twenty no-op reconciliations")
        #expect(ObjectIdentifier(runtime.displayManager.displays[0].panel) == ObjectIdentifier(panel))
        #expect(runtime.pendingStallChecks == 0)
        await tearDown(runtime, suite)
        #expect(OverlayPanel.openCount == panels && CaptureSession.liveStreams == streams)
    }

    // MARK: health and covers across a transition

    @Test func aWakeDoesNotReportALostGrantAndKeepsFailClosedCoversUp() async {
        let (runtime, suite) = makeRuntime([screen(91)])
        runtime.checkHealth()
        let settled = runtime.model.policy.health
        runtime.systemEvents.simulate(.willSleep)
        runtime.checkHealth()
        #expect(runtime.model.policy.health == settled, "our own stop is not a lost grant")
        #expect(!runtime.systemEvents.capturesFrames, "FR10: Curtain windows stay covered while capture is parked")
        runtime.systemEvents.simulate(.didWake)
        runtime.checkHealth()
        #expect(runtime.model.policy.health == settled)
        #expect(!runtime.systemEvents.capturesFrames, "and through the wake, until a frame proves capture is back")
        #expect(runtime.systemEvents.framesResumed())
        #expect(runtime.systemEvents.capturesFrames)
        await tearDown(runtime, suite)
    }

    // MARK: the restart policy on a real session

    @Test func aBurstOfFailuresSchedulesOneRetryAndAGoneDisplayNone() {
        let session = CaptureSession(displayID: 4242, permission: PermissionMonitor(), simulated: true)
        var present = true
        session.captureAllowed = { true }
        session.displayIsPresent = { present }
        session.start()
        #expect(session.isConnected && session.health.isOK && session.restarts == 0)

        // Three failures inside one turn — a delegate error, the failed reconnect, a topology change — are one retry.
        for _ in 0..<3 { session.simulateStreamFailure() }
        #expect(session.restarts == 1)
        #expect(!session.isConnected)
        #expect((session.pendingRetryDelay ?? 0) > 0.5 && (session.pendingRetryDelay ?? 0) <= 1)

        // The display is unplugged: the pending retry goes and nothing new is scheduled.
        present = false
        session.simulateStreamFailure()
        #expect(session.restarts == 1 && session.pendingRetryDelay == nil)
        session.stop()
        #expect(session.pendingRetryDelay == nil && !session.isConnected)
    }

    @Test func aStoppedSessionRetriesNothing() {
        let session = CaptureSession(displayID: 4243, permission: PermissionMonitor(), simulated: true)
        session.captureAllowed = { true }
        session.start()
        session.stop()
        session.simulateStreamFailure()
        #expect(session.restarts == 0 && session.pendingRetryDelay == nil)
        // Nor does one whose grant has gone.
        session.captureAllowed = { false }
        session.start()
        session.simulateStreamFailure()
        #expect(session.restarts == 0 && session.pendingRetryDelay == nil)
        session.stop()
    }
}
