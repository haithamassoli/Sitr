// M4-T06 / M4-T07 unit tests for the app layer: the Low Power frame rate and the General toggle that governs it, the
// per-display detection meter, and the notification spacing through the real `Notifier` with an injected clock. The live
// wiring (power notification → `SCStream.updateConfiguration`, slow frames → menu bar) is `Sitr --selftest lowpower|degraded`.
import CoreGraphics
import Foundation
import SitrCore
import Testing

@testable import Sitr

@MainActor @Suite struct LowPowerTests {
    @Test func frameRateFollowsThePowerStateAndTheToggle() {
        #expect(LowPowerMonitor.standardFPS == 15 && LowPowerMonitor.lowPowerFPS == 8)
        #expect(LowPowerMonitor.fps(lowPower: false, reduce: true) == 15)
        #expect(LowPowerMonitor.fps(lowPower: true, reduce: true) == 8)
        #expect(LowPowerMonitor.fps(lowPower: true, reduce: false) == 15)  // the General toggle wins
        #expect(LowPowerMonitor.fps(lowPower: false, reduce: false) == 15)
    }

    @Test func updatesReportEveryChangeExactlyOnce() {
        var reduce = true
        let monitor = LowPowerMonitor(reducesFrameRate: { reduce })
        var seen: [Int] = []
        monitor.onChange = { seen.append($0) }
        monitor.simulatedLowPower = false
        monitor.update()
        #expect(monitor.fps == 15 && seen.isEmpty)  // no change from the default: nothing to push
        monitor.simulatedLowPower = true
        monitor.update()
        monitor.update()  // a second notification for the same state must not re-push
        #expect(monitor.fps == 8 && seen == [8])
        reduce = false  // Settings › General switched off while Low Power Mode stays on
        monitor.update()
        #expect(monitor.fps == 15 && seen == [8, 15])
        reduce = true
        monitor.update()
        #expect(monitor.fps == 8 && seen == [8, 15, 8])
        monitor.simulatedLowPower = false
        monitor.update()
        #expect(monitor.fps == 15 && seen == [8, 15, 8, 15])
    }

    @Test func theRuntimeReadsTheToggleFromPreferences() {
        let suite = "SitrTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = Preferences(defaults: defaults)
        let runtime = Runtime(model: AppModel(preferences: preferences))
        runtime.lowPower.simulatedLowPower = true
        runtime.lowPower.update()
        #expect(runtime.lowPower.fps == 8)
        preferences.lowPowerReducesFrameRate = false
        runtime.lowPower.update()
        #expect(runtime.lowPower.fps == 15)
        defaults.removePersistentDomain(forName: suite)
    }
}

@Suite struct DetectionMeterTests {
    /// Not `.shared`: these run in parallel with everything else in the target.
    private func feed(
        _ meter: DetectionMeter, display: CGDirectDisplayID, ms: Double, from start: Double, seconds: Double
    ) {
        let step = ms / 1000
        var t = start
        while t + step <= start + seconds + 1e-9 {
            t += step
            meter.record(display: display, seconds: step, at: t)
        }
    }

    @Test func oneSlowDisplayDegradesTheApp() {
        let meter = DetectionMeter()
        feed(meter, display: 1, ms: 50, from: 0, seconds: 10)
        feed(meter, display: 2, ms: 50, from: 0, seconds: 10)
        #expect(!meter.isDegraded)
        feed(meter, display: 2, ms: 300, from: 10, seconds: 3.5)
        #expect(meter.isDegraded)
        #expect(meter.degradedDisplays == [2])  // display 1 is still keeping up
        feed(meter, display: 2, ms: 50, from: 14, seconds: 5.5)
        #expect(!meter.isDegraded && meter.degradedDisplays.isEmpty)
    }

    @Test func anUnpluggedDisplayLeavesNoDegradedStateBehind() {
        let meter = DetectionMeter()
        feed(meter, display: 7, ms: 400, from: 0, seconds: 3.5)
        #expect(meter.degradedDisplays == [7])
        meter.forget(display: 7)
        #expect(!meter.isDegraded)
        feed(meter, display: 7, ms: 400, from: 100, seconds: 3.5)
        #expect(meter.isDegraded)
        meter.reset()
        #expect(!meter.isDegraded && meter.degradedDisplays.isEmpty)
    }
}

@MainActor @Suite struct NotifierSpacingTests {
    /// The `Notifier` with `dryRun` (nothing reaches UNUserNotificationCenter) and a clock the test moves by hand.
    private func makeNotifier() -> (Notifier, clock: Clock) {
        Notifier.dryRun = true
        let clock = Clock()
        let notifier = Notifier()
        notifier.now = { clock.now }
        return (notifier, clock)
    }

    @MainActor final class Clock {
        var now = 1_000.0
    }

    @Test func oneNotificationPerTransition() {
        let (notifier, clock) = makeNotifier()
        notifier.healthChanged(to: .ok)  // launch: healthy from the start, nothing to say
        #expect(notifier.posted == 0)
        notifier.healthChanged(to: .degraded)
        clock.now += 1
        notifier.healthChanged(to: .degraded)  // the same state again is not a transition
        #expect(notifier.posted == 1)
        #expect(notifier.lastHealth == .degraded)
    }

    @Test func repeatsOfTheSameTransitionWaitFiveMinutes() {
        let (notifier, clock) = makeNotifier()
        notifier.healthChanged(to: .degraded)
        clock.now += 10
        notifier.healthChanged(to: .ok)
        #expect(notifier.posted == 2)
        // Detection flaps for the next four minutes: the state follows, the user is not told again.
        for _ in 0..<8 {
            clock.now += 15
            notifier.healthChanged(to: .degraded)
            clock.now += 15
            notifier.healthChanged(to: .ok)
        }
        #expect(notifier.posted == 2)
        #expect(notifier.lastHealth == .ok)  // suppressed transitions still track the real state
        clock.now += 100  // past five minutes since the last post of each transition
        notifier.healthChanged(to: .degraded)
        #expect(notifier.posted == 3)
        clock.now += 10
        notifier.healthChanged(to: .ok)
        #expect(notifier.posted == 4)
    }

    @Test func aLostGrantIsAnnouncedEvenWhileADegradedRepeatIsHeldBack() {
        let (notifier, clock) = makeNotifier()
        notifier.healthChanged(to: .degraded)
        clock.now += 5
        notifier.healthChanged(to: .ok)
        clock.now += 5
        notifier.healthChanged(to: .degraded)  // throttled
        #expect(notifier.posted == 2)
        clock.now += 5
        notifier.healthChanged(to: .needsPermission)  // a different transition: the user hears about it at once
        #expect(notifier.posted == 3)
        clock.now += 5
        notifier.healthChanged(to: .ok)  // needsPermission → ok is its own transition, not the degraded recovery
        #expect(notifier.posted == 4)
    }
}
