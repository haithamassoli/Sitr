// M4-T07 unit tests: the degraded-state hysteresis (250 ms for 3 s in, 150 ms for 5 s out) and the notification spacing.
// Every clock value is passed in, so the 3 s, 5 s and 5 min windows are exercised without a real second passing.
// `record` and `feed` mutate, which `#expect` cannot do inline, hence the `let` before each check.
import Testing

@testable import SitrCore

@Suite struct DegradedMonitorTests {
    /// Frames of `ms` back to back, the first ending at `start + ms` and the last no later than `end`. Stops at the
    /// first flip and returns when it happened, nil when the run finished without one.
    private func feed(_ monitor: inout DegradedMonitor, ms: Double, from start: Double, until end: Double) -> Double? {
        let step = ms / 1000
        var t = start
        while t + step <= end + 1e-9 {
            t += step
            if monitor.record(seconds: step, at: t) != nil { return t }
        }
        return nil
    }

    @Test func standardThresholdsFollowTheProductSpec() {
        let t = DegradedThresholds.standard
        #expect(t.enter == 0.250 && t.enterFor == 3)
        #expect(t.exit == 0.150 && t.exitFor == 5)
    }

    @Test func slowFramesForThreeSecondsDegrade() {
        var monitor = DegradedMonitor()
        #expect(!monitor.isDegraded)
        // 300 ms frames from t=0: the run starts at the first frame's start, so the flip lands exactly on t=3.
        let first = monitor.record(seconds: 0.3, at: 0.3)
        let almost = feed(&monitor, ms: 300, from: 0.3, until: 2.9)
        #expect(first == nil && almost == nil)
        #expect(!monitor.isDegraded)
        let flip = monitor.record(seconds: 0.3, at: 3.0)
        #expect(flip == true)
        #expect(monitor.isDegraded)
        let again = monitor.record(seconds: 0.3, at: 3.3)
        #expect(again == nil)  // already degraded: no second flip
    }

    @Test func framesAtOrUnderTheLimitAreNotSlow() {
        var monitor = DegradedMonitor()
        let atTheLimit = feed(&monitor, ms: 250, from: 0, until: 30)  // exactly 250 ms is not "> 250 ms"
        let under = feed(&monitor, ms: 240, from: 30, until: 60)
        #expect(atTheLimit == nil && under == nil)
        #expect(!monitor.isDegraded)
    }

    @Test func oneVeryLongFrameIsAlreadyThreeSecondsOfSlowness() {
        var monitor = DegradedMonitor()
        let flip = monitor.record(seconds: 4, at: 104)  // a 4 s frame need not wait for three more seconds
        #expect(flip == true)
        #expect(monitor.isDegraded)
    }

    @Test func aFastFrameBreaksTheSlowRun() {
        var monitor = DegradedMonitor()
        let before = feed(&monitor, ms: 300, from: 0, until: 2.6)
        let quick = monitor.record(seconds: 0.05, at: 2.75)  // one quick frame: the run starts over
        let after = feed(&monitor, ms: 300, from: 2.75, until: 5.6)
        #expect(before == nil && quick == nil && after == nil)
        #expect(!monitor.isDegraded)
        let flip = feed(&monitor, ms: 300, from: 5.6, until: 8)
        #expect(flip != nil && (flip ?? 0) > 5.75)  // three seconds after the quick frame, not after the first slow one
        #expect(monitor.isDegraded)
    }

    @Test func fastFramesForFiveSecondsRecover() {
        var monitor = DegradedMonitor()
        let down = monitor.record(seconds: 4, at: 4)
        let first = monitor.record(seconds: 0.05, at: 4.05)  // the run starts at 4.00, the frame's own start
        let almost = feed(&monitor, ms: 50, from: 4.05, until: 8.9)
        #expect(down == true && first == nil && almost == nil)
        #expect(monitor.isDegraded)
        let up = monitor.record(seconds: 0.05, at: 9.0)
        #expect(up == false)
        #expect(!monitor.isDegraded)
    }

    @Test func theHysteresisBandHoldsWhicheverStateIsCurrent() {
        // 200 ms is neither slow enough to degrade nor fast enough to recover: it holds both states, however long it lasts.
        var healthy = DegradedMonitor()
        let stayed = feed(&healthy, ms: 200, from: 0, until: 60)
        #expect(stayed == nil && !healthy.isDegraded)
        var degraded = DegradedMonitor()
        let down = degraded.record(seconds: 4, at: 4)
        let held = feed(&degraded, ms: 200, from: 4, until: 60)
        #expect(down == true && held == nil && degraded.isDegraded)
        // Only frames under 150 ms bring it back, and 150 exactly is not "under".
        let atTheLimit = feed(&degraded, ms: 150, from: 60, until: 90)
        #expect(atTheLimit == nil && degraded.isDegraded)
        let up = feed(&degraded, ms: 100, from: 90, until: 96)
        #expect(up != nil && !degraded.isDegraded)
    }

    @Test func aSlowFrameBreaksTheRecoveryRun() {
        var monitor = DegradedMonitor()
        let down = monitor.record(seconds: 4, at: 4)
        let almost = feed(&monitor, ms: 50, from: 4, until: 8.5)
        let slow = monitor.record(seconds: 0.4, at: 8.9)  // one slow frame: the five seconds start over
        let restarted = feed(&monitor, ms: 50, from: 8.9, until: 13.5)
        #expect(down == true && almost == nil && slow == nil && restarted == nil)
        #expect(monitor.isDegraded)
        let up = feed(&monitor, ms: 50, from: 13.5, until: 14.5)
        #expect(up != nil && !monitor.isDegraded)
    }

    @Test func customThresholdsAreHonoured() {
        var monitor = DegradedMonitor(thresholds: DegradedThresholds(enter: 0.02, exit: 0.01, enterFor: 1, exitFor: 2))
        let almost = feed(&monitor, ms: 30, from: 0, until: 0.9)
        let down = feed(&monitor, ms: 30, from: 0.9, until: 1.2)
        #expect(almost == nil && down != nil && monitor.isDegraded)
        let recovering = feed(&monitor, ms: 5, from: 1.2, until: 3.1)
        let up = feed(&monitor, ms: 5, from: 3.1, until: 3.4)
        #expect(recovering == nil && up != nil && !monitor.isDegraded)
    }

    @Test func resetForgetsTheRunAndTheState() {
        var monitor = DegradedMonitor()
        let down = monitor.record(seconds: 4, at: 4)
        #expect(down == true)
        monitor.reset()
        #expect(!monitor.isDegraded)
        let almost = feed(&monitor, ms: 300, from: 4, until: 6.9)  // the old run is gone too
        let again = feed(&monitor, ms: 300, from: 6.9, until: 7.5)
        #expect(almost == nil && again != nil)
    }
}

@Suite struct HealthNotificationGateTests {
    @Test func spacingIsFiveMinutes() {
        #expect(HealthNotificationGate.repeatSpacing == 300)
    }

    @Test func onlyRealTransitionsAreAnnounced() {
        var gate = HealthNotificationGate()
        let same = gate.allows(from: .ok, to: .ok, at: 0)
        let changed = gate.allows(from: .ok, to: .degraded, at: 1)
        let sameAgain = gate.allows(from: .degraded, to: .degraded, at: 2)
        #expect(!same && changed && !sameAgain)
    }

    @Test func theSameTransitionIsThrottledForFiveMinutes() {
        var gate = HealthNotificationGate()
        let down = gate.allows(from: .ok, to: .degraded, at: 1000)
        let up = gate.allows(from: .degraded, to: .ok, at: 1010)
        #expect(down && up)
        let downAgain = gate.allows(from: .ok, to: .degraded, at: 1020)  // flapping: the user was told 20 s ago
        let upAgain = gate.allows(from: .degraded, to: .ok, at: 1030)
        let justBefore = gate.allows(from: .ok, to: .degraded, at: 1299.9)
        #expect(!downAgain && !upAgain && !justBefore)
        let allowed = gate.allows(from: .ok, to: .degraded, at: 1300)  // 5 min after the last one that was posted
        let allowedUp = gate.allows(from: .degraded, to: .ok, at: 1310)
        #expect(allowed && allowedUp)
    }

    @Test func aSuppressedTransitionDoesNotRestartTheClock() {
        var gate = HealthNotificationGate()
        let first = gate.allows(from: .ok, to: .degraded, at: 0)
        #expect(first)
        var suppressed = 0
        for t in stride(from: 10.0, to: 300.0, by: 10) where !gate.allows(from: .ok, to: .degraded, at: t) {
            suppressed += 1
        }
        #expect(suppressed == 29)
        // Five minutes after the post that went out, not after the last attempt.
        let allowed = gate.allows(from: .ok, to: .degraded, at: 300)
        #expect(allowed)
    }

    @Test func transitionsAreThrottledIndependently() {
        var gate = HealthNotificationGate()
        let lost = gate.allows(from: .ok, to: .needsPermission, at: 0)
        let back = gate.allows(from: .needsPermission, to: .ok, at: 5)
        let slow = gate.allows(from: .ok, to: .degraded, at: 10)  // a different transition is not held back
        let fast = gate.allows(from: .degraded, to: .ok, at: 15)  // "restored" after a slowdown ≠ after a lost grant
        #expect(lost && back && slow && fast)
        let repeated = gate.allows(from: .needsPermission, to: .ok, at: 20)
        let other = gate.allows(from: .degraded, to: .needsPermission, at: 25)
        #expect(!repeated && other)
    }

    @Test func spacingIsConfigurable() {
        var gate = HealthNotificationGate(spacing: 10)
        let first = gate.allows(from: .ok, to: .degraded, at: 0)
        let tooSoon = gate.allows(from: .ok, to: .degraded, at: 9.5)
        let allowed = gate.allows(from: .ok, to: .degraded, at: 10)
        #expect(first && !tooSoon && allowed)
    }
}
