import Testing
@testable import SitrCore

@Suite struct RevealStateTests {
    @Test func startsCovered() {
        #expect(!RevealState.covered.isRevealed)
    }

    @Test func pressReveals() {
        var state = RevealState.covered
        state.press(at: 10)
        #expect(state.isRevealed)
        #expect(state == .revealed(since: 10))
    }

    @Test func releaseCovers() {
        var state = RevealState.covered
        state.press(at: 10)
        state.release()
        #expect(state == .covered)
        state.release()  // release while covered is harmless
        #expect(state == .covered)
    }

    @Test func safetyTimeoutCoversAfter30Seconds() {
        var state = RevealState.covered
        state.press(at: 100)
        state.tick(now: 129.9)
        #expect(state.isRevealed)
        state.tick(now: 130)
        #expect(state == .covered)
        #expect(RevealState.timeout == 30)
    }

    @Test func tickWhileCoveredIsNoop() {
        var state = RevealState.covered
        state.tick(now: 1e6)
        #expect(state == .covered)
    }

    @Test func lostReleaseCovers() {
        var state = RevealState.covered
        state.press(at: 0)
        state.lostRelease()
        #expect(state == .covered)
    }

    @Test func pressWhileRevealedIsIdempotent() {
        var state = RevealState.covered
        state.press(at: 0)
        state.press(at: 20)  // key repeat must not restart the safety timer
        #expect(state == .revealed(since: 0))
        state.tick(now: 30)
        #expect(state == .covered)
    }
}
