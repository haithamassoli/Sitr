// M1-T01: SCStream loop on the main display. Per second: complete frames, .idle skipped, dirtyRects, size, contentRect, scaleFactor.
import AppKit
import ScreenCaptureKit

@MainActor
func runCapture(_ args: [String]) {
    if args.contains("--help") {
        print("usage: sitr-spike capture [--seconds N=10] [--motion] [--long-side PX=1280 (0 = native)]")
        exit(0)
    }
    let seconds = option(args, "--seconds", default: 10.0)
    let longSide = option(args, "--long-side", default: 1280)
    let motion = args.contains("--motion")
    Rig.boot()
    Rig.deadline(seconds + 15, "capture")
    Rig.run {
        if motion { motionWindow() }
        let content = try await RigStream.shareable()
        let display = RigStream.mainDisplay(content)
        let rig = RigStream(buffering: .bufferingNewest(1))  // stats are counted in the callback; nobody consumes frames here
        try await rig.start(filter: SCContentFilter(display: display, excludingWindows: []), longSide: longSide)
        var prev = StreamStats()
        let wall = CACurrentMediaTime()
        for t in 1...max(1, Int(seconds)) {
            try await Task.sleep(for: .seconds(1))
            let s = rig.stats.withLock { $0 }
            print("t=\(t)s complete=\(s.complete - prev.complete) idle=\(s.idle - prev.idle) other=\(s.other - prev.other) "
                + "dirtyRects=\(s.dirty - prev.dirty) size=\(Int(s.size.width))x\(Int(s.size.height)) "
                + "contentRect=\(rectString(s.contentRect)) scaleFactor=\(s.scaleFactor) contentScale=\(s.contentScale)")
            prev = s
        }
        let elapsed = CACurrentMediaTime() - wall
        await rig.stop()
        print("capture_fps mean=\(String(format: "%.2f", Double(prev.complete) / elapsed)) complete=\(prev.complete) idle=\(prev.idle) "
            + "other=\(prev.other) seconds=\(String(format: "%.1f", elapsed)) motion=\(motion) long_side=\(longSide) "
            + "size=\(Int(prev.size.width))x\(Int(prev.size.height))")
        Rig.finish(0)
    }
}

/// Small always-on-top window with a dot bouncing at display refresh, so the screen is never static.
@MainActor
private func motionWindow() {
    let d = mainDisplayBounds()
    let p = Rig.panel(NSRect(x: d.width - 280, y: 60, width: 240, height: 160), level: .screenSaver, color: .darkGray)
    p.ignoresMouseEvents = true
    let dot = CALayer()
    dot.backgroundColor = NSColor.systemYellow.cgColor
    dot.frame = CGRect(x: 0, y: 60, width: 40, height: 40)
    dot.cornerRadius = 20
    p.contentView!.layer!.addSublayer(dot)
    let a = CABasicAnimation(keyPath: "position.x")
    a.fromValue = 20
    a.toValue = 220
    a.duration = 0.8
    a.autoreverses = true
    a.repeatCount = .infinity
    dot.add(a, forKey: "move")
    p.orderFrontRegardless()
}
