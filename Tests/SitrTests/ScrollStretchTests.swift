import CoreGraphics
import Testing

@testable import Sitr

@Suite struct ScrollStretchTests {
    @Test func stretchCoversWhereContentWasAndEverywhereItWent() {
        let r = CGRect(x: 10, y: 300, width: 100, height: 200)
        #expect(scrollStretched(r, reach: .zero) == r)
        // Page scrolled down 80 pt: content moved up 80 pt on screen.
        #expect(scrollStretched(r, reach: CGRect(x: 0, y: -80, width: 0, height: 80)) == CGRect(x: 10, y: 220, width: 100, height: 280))
        #expect(scrollStretched(r, reach: CGRect(x: 0, y: 0, width: 30, height: 0)) == CGRect(x: 10, y: 300, width: 130, height: 200))
        // A runaway delta is capped.
        #expect(scrollStretched(r, reach: CGRect(x: 0, y: 0, width: 0, height: 5000), cap: 600) == CGRect(x: 10, y: 300, width: 100, height: 800))
    }

    @Test func reachKeepsTheWayOutWhenTheScrollComesBack() {
        var o = Odometer()
        o.add(dx: 0, dy: -50, at: 1.0)
        o.add(dx: 0, dy: -50, at: 1.1)
        o.add(dx: 0, dy: 70, at: 1.2)  // reversed: net -30, but the page went to -100 on the way
        #expect(o.reach(since: 0.5) == CGRect(x: 0, y: -100, width: 0, height: 100))
        #expect(o.reach(since: 1.05) == CGRect(x: 0, y: -50, width: 0, height: 70))  // from -50: to -100, back to -30
        #expect(o.reach(since: 2) == .zero)
    }

    @Test func odometerReadsTheTotalAtAnyTimeAndForgetsOldSteps() {
        var o = Odometer()
        #expect(o.offset(at: 0) == .zero)
        o.add(dx: 0, dy: -20, at: 1.0)
        o.add(dx: 0, dy: -20, at: 1.016)
        o.add(dx: 5, dy: 10, at: 1.032)
        #expect(o.offset(at: 0.5) == .zero)
        #expect(o.offset(at: 1.02) == CGVector(dx: 0, dy: -40))
        #expect(o.offset(at: 2) == CGVector(dx: 5, dy: -30))
        // Steps older than the window fold into the base: the total is unchanged.
        o.add(dx: 0, dy: -1, at: 10)
        #expect(o.offset(at: 9) == CGVector(dx: 5, dy: -30))
        #expect(o.offset(at: 10) == CGVector(dx: 5, dy: -31))
    }
}

@Suite struct StickyFrameTests {
    let display = CGSize(width: 1000, height: 800)

    @Test func coverStaysPutWhileThePersonFitsInside() {
        let first = stickyFrame(previous: nil, target: CGRect(x: 100, y: 100, width: 100, height: 200), display: display)
        #expect(first == CGRect(x: 96, y: 92, width: 108, height: 216))  // 4 % slack on each side
        // Jitter of a few points: same frame, so no edge shimmer and the pixels can be reused.
        #expect(stickyFrame(previous: first, target: CGRect(x: 102, y: 97, width: 99, height: 203), display: display) == first)
    }

    @Test func coverFollowsWhenThePersonLeavesItOrItIsTooBig() {
        let first = CGRect(x: 96, y: 92, width: 108, height: 216)
        #expect(stickyFrame(previous: first, target: CGRect(x: 150, y: 100, width: 100, height: 200), display: display) != first)
        // Person shrank to a third: the old cover is far too big, so it is replaced.
        let small = CGRect(x: 120, y: 120, width: 50, height: 100)
        #expect(stickyFrame(previous: first, target: small, display: display) == CGRect(x: 118, y: 116, width: 54, height: 108))
    }
}
