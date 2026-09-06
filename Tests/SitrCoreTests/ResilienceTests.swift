// M4-T10 unit tests: the stream-restart backoff (1, 2, 4, 8, 10, 10 … s), the suspend/resume bookkeeping behind
// sleep/wake, lock/unlock and fast user switching, and the mirror/duplicate dedupe of the display list. Every clock value
// is passed in, so twenty wake cycles and a week of failing reconnects cost no real seconds and no hardware.
import Testing

@testable import SitrCore

@Suite struct BackoffTests {
    @Test func theCaptureStreamSequenceIsOneTwoFourEightThenTen() {
        let backoff = Backoff.captureStream
        #expect(backoff.cap == 10 && backoff.resetAfter == 30)
        #expect((0..<8).map { backoff.delay(attempt: $0) } == [1, 2, 4, 8, 10, 10, 10, 10])
    }

    @Test func theCapHoldsHoweverLongItHasBeenFailing() {
        let backoff = Backoff.captureStream
        // A session that has been retrying for a week: multiplied, never `pow`ed, so nothing overflows past the ceiling.
        #expect(backoff.delay(attempt: 60) == 10)
        #expect(backoff.delay(attempt: 100_000) == 10)
        #expect(backoff.delay(attempt: -3) == 1)  // nonsense in, the first delay out
    }

    @Test func aCapUnderTheFirstDelayStillHolds() {
        let tight = Backoff(first: 5, factor: 2, cap: 2)
        #expect((0..<4).map { tight.delay(attempt: $0) } == [2, 2, 2, 2])
    }
}

@Suite struct RestartPolicyTests {
    @Test func failuresClimbTheBackoffAndStopAtTheCap() {
        var policy = RestartPolicy()
        var delays: [Double] = []
        var now = 0.0
        for _ in 0..<6 {
            guard case .retry(let after) = policy.failed(at: now, retryable: true) else {
                Issue.record("expected a retry")
                break
            }
            delays.append(after)
            now += after
            policy.retryFired()
        }
        #expect(delays == [1, 2, 4, 8, 10, 10])
        #expect(policy.retries == 6)
    }

    @Test func severalFailuresAtOnceScheduleOneRetry() {
        var policy = RestartPolicy()
        let first = policy.failed(at: 100, retryable: true)
        // The delegate error, the failed reconnect and a topology change all land inside the same second.
        let second = policy.failed(at: 100, retryable: true)
        let third = policy.failed(at: 100.4, retryable: true)
        #expect(first == .retry(after: 1))
        #expect(second == .alreadyScheduled(after: 1))
        if case .alreadyScheduled(let left) = third { #expect(abs(left - 0.6) < 1e-9) } else { Issue.record("stacked a retry") }
        #expect(policy.retries == 1)  // one timer, not three
        #expect(policy.attempt == 1)  // and the backoff did not jump to 8 s because of a burst
    }

    @Test func theNextFailureAfterTheRetryFiredSchedulesAgain() {
        var policy = RestartPolicy()
        _ = policy.failed(at: 0, retryable: true)
        policy.retryFired()
        #expect(policy.failed(at: 1, retryable: true) == .retry(after: 2))
        #expect(policy.retries == 2)
    }

    @Test func aDisplayThatWentAwayStopsTheRetries() {
        var policy = RestartPolicy()
        _ = policy.failed(at: 0, retryable: true)
        policy.retryFired()
        _ = policy.failed(at: 1, retryable: true)
        policy.retryFired()
        #expect(policy.attempt == 2)
        // The display is unplugged (or the grant went, or capture was stopped): nothing pending, nothing scheduled.
        #expect(policy.failed(at: 3, retryable: false) == .stop)
        #expect(policy.retryAt == nil && policy.attempt == 0)
        #expect(policy.retries == 2)  // the two that were scheduled stay counted
        // Plugged back in: the sequence starts from the first delay, not from where it left off.
        #expect(policy.failed(at: 90, retryable: true) == .retry(after: 1))
    }

    @Test func aFailureWhileAPendingRetryIsAlreadyDueSchedulesTheNextOne() {
        var policy = RestartPolicy()
        #expect(policy.failed(at: 0, retryable: true) == .retry(after: 1))
        // The retry was due at t=1 and something failed at t=2 without `retryFired` having run: not "already scheduled".
        #expect(policy.failed(at: 2, retryable: true) == .retry(after: 2))
    }

    @Test func aStreamThatRanForHalfAMinuteEarnsAFreshBackoff() {
        var policy = RestartPolicy()
        for _ in 0..<5 {
            _ = policy.failed(at: 0, retryable: true)
            policy.retryFired()
        }
        #expect(policy.attempt == 5)
        policy.connected(at: 100)
        #expect(policy.failed(at: 129, retryable: true) == .retry(after: 10))  // 29 s is not enough
        policy.retryFired()
        policy.connected(at: 200)
        #expect(policy.failed(at: 230, retryable: true) == .retry(after: 1))  // 30 s is
    }

    @Test func connectingClearsThePendingRetryButNotTheClimb() {
        var policy = RestartPolicy()
        _ = policy.failed(at: 0, retryable: true)
        policy.connected(at: 1)
        #expect(policy.retryAt == nil)
        #expect(policy.failed(at: 2, retryable: true) == .retry(after: 2))  // died again at once: keep climbing
    }

    @Test func timeToRetryCountsDownAndThenReadsNil() {
        var policy = RestartPolicy()
        _ = policy.failed(at: 10, retryable: true)
        #expect(policy.timeToRetry(at: 10.25) == 0.75)
        #expect(policy.timeToRetry(at: 11) == nil)
        policy.reset()
        #expect(policy.timeToRetry(at: 10.1) == nil && policy.attempt == 0 && policy.retryAt == nil)
    }
}

@Suite struct SystemActivityMachineTests {
    @Test func twentySleepWakeCyclesEndActiveWithNothingHeldOpen() {
        var machine = SystemActivityMachine()
        var now = 0.0
        for _ in 0..<20 {
            now += 1
            #expect(machine.handle(.willSleep, at: now) == .suspended)
            #expect(!machine.capturesFrames)
            now += 1
            #expect(machine.handle(.didWake, at: now) == .resuming)
            #expect(!machine.capturesFrames)  // the covers stay up until a frame proves capture is back
            now += 0.4
            #expect(machine.framesResumed(at: now) == .active)
            #expect(machine.capturesFrames && machine.reasons.isEmpty)
        }
        #expect(machine.state == .active && machine.reasons == [])
    }

    @Test func lockAndFastUserSwitchingUseTheSamePath() {
        var machine = SystemActivityMachine()
        #expect(machine.handle(.screenLocked, at: 0) == .suspended)
        #expect(machine.handle(.screenUnlocked, at: 5) == .resuming)
        #expect(machine.framesResumed(at: 5.2) == .active)
        #expect(machine.handle(.sessionResignedActive, at: 10) == .suspended)
        #expect(machine.handle(.sessionBecameActive, at: 30) == .resuming)
        #expect(machine.framesResumed(at: 30.3) == .active)
        #expect(machine.handle(.screensDidSleep, at: 40) == .suspended)
        #expect(machine.handle(.screensDidWake, at: 50) == .resuming)
        #expect(machine.framesResumed(at: 50.1) == .active)
    }

    @Test func overlappingReasonsAllHaveToClear() {
        // The real order on a MacBook lid close: lock, screens off, sleep. Waking undoes them in another order.
        var machine = SystemActivityMachine()
        #expect(machine.handle(.screenLocked, at: 0) == .suspended)
        #expect(machine.handle(.screensDidSleep, at: 1) == nil)  // already suspended
        #expect(machine.handle(.willSleep, at: 2) == nil)
        #expect(machine.reasons == [.screenLocked, .screensAsleep, .systemSleep])
        #expect(machine.handle(.didWake, at: 100) == nil)  // still locked and dark
        #expect(machine.handle(.screensDidWake, at: 101) == nil)
        #expect(machine.handle(.screenUnlocked, at: 105) == .resuming)  // the last one clears it
        #expect(machine.framesResumed(at: 105.3) == .active)
    }

    @Test func duplicateAndUnpairedEventsChangeNothing() {
        var machine = SystemActivityMachine()
        #expect(machine.handle(.didWake, at: 0) == nil)  // a wake with no sleep before it
        #expect(machine.state == .active)
        #expect(machine.handle(.willSleep, at: 1) == .suspended)
        #expect(machine.handle(.willSleep, at: 2) == nil)  // macOS posting it twice
        #expect(machine.handle(.didWake, at: 3) == .resuming)
        #expect(machine.handle(.didWake, at: 4) == nil)
        #expect(machine.framesResumed(at: 5) == .active)
        #expect(machine.framesResumed(at: 6) == nil)  // frames keep coming; the state has already moved
    }

    @Test func goingBackToSleepBeforeTheFirstFrameSuspendsAgain() {
        var machine = SystemActivityMachine()
        #expect(machine.handle(.willSleep, at: 0) == .suspended)
        #expect(machine.handle(.didWake, at: 10) == .resuming)
        #expect(machine.handle(.willSleep, at: 10.2) == .suspended)  // a wake for a Time Machine run, straight back down
        #expect(machine.framesResumed(at: 10.3) == nil)  // a late frame from the old stream does not clear it
        #expect(machine.handle(.didWake, at: 60) == .resuming)
        #expect(machine.framesResumed(at: 60.4) == .active)
    }

    @Test func healthIsHeldWhileSuspendedAndForTheSettleWindowAfterAWake() {
        var machine = SystemActivityMachine()
        #expect(!machine.holdsHealth(at: 0))  // nothing is happening: a stopped stream really is a failure
        machine.handle(.willSleep, at: 10)
        #expect(machine.holdsHealth(at: 10_000))  // asleep for as long as it takes
        machine.handle(.didWake, at: 20_000)
        #expect(machine.holdsHealth(at: 20_004.9))
        #expect(SystemActivityMachine.settleFor == 5)
        #expect(!machine.holdsHealth(at: 20_005))  // capture had five seconds and never came back: that is a real failure
        machine.framesResumed(at: 20_006)
        #expect(!machine.holdsHealth(at: 20_006))
    }

    @Test func resetGoesBackToACleanActiveState() {
        var machine = SystemActivityMachine()
        machine.handle(.willSleep, at: 1)
        machine.handle(.screenLocked, at: 2)
        machine.reset()
        #expect(machine.state == .active && machine.reasons == [] && machine.changedAt == 0)
        #expect(!machine.holdsHealth(at: 3))
    }
}

@Suite struct DisplayTopologyTests {
    @Test func aPlainListIsManagedInOrder() {
        #expect(DisplayTopology.managed([DisplayLink(id: 1), DisplayLink(id: 7), DisplayLink(id: 3)]) == [1, 7, 3])
        #expect(DisplayTopology.managed([]) == [])
    }

    @Test func aRepeatedIDGetsOnePanel() {
        // A mirror set can report the same `CGDirectDisplayID` twice; two panels on it would draw every cover twice.
        #expect(DisplayTopology.managed([DisplayLink(id: 2), DisplayLink(id: 2), DisplayLink(id: 5)]) == [2, 5])
    }

    @Test func aDisplayMirroringAManagedOneIsDropped() {
        // Display 9 shows display 4's pixels: one stream and one panel, on 4.
        #expect(DisplayTopology.managed([DisplayLink(id: 4), DisplayLink(id: 9, mirrors: 4)]) == [4])
        #expect(DisplayTopology.managed([DisplayLink(id: 9, mirrors: 4), DisplayLink(id: 4)]) == [4])
    }

    @Test func aMirrorMasterThatIsNotInTheListKeepsItsSlave() {
        // The master is off (a closed lid mirroring an external panel): the slave is the only display there is.
        #expect(DisplayTopology.managed([DisplayLink(id: 9, mirrors: 4)]) == [9])
        #expect(DisplayTopology.managed([DisplayLink(id: 9, mirrors: 9)]) == [9])  // mirroring itself means nothing
    }

    @Test func aListWhereEverythingMirrorsSomethingIsKeptWhole() {
        // Cannot happen on real hardware; covering nothing would be worse than covering twice.
        #expect(DisplayTopology.managed([DisplayLink(id: 1, mirrors: 2), DisplayLink(id: 2, mirrors: 1)]) == [1, 2])
    }

    @Test func threeDisplaysWithOneMirrorPairKeepTwo() {
        let links = [DisplayLink(id: 1), DisplayLink(id: 2), DisplayLink(id: 3, mirrors: 1)]
        #expect(DisplayTopology.managed(links) == [1, 2])
    }
}
