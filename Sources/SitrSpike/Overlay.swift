// M1-T02: transparent click-through overlay NSPanel + feedback-loop check (own process excluded from the SCContentFilter).
import AppKit
import ScreenCaptureKit

@MainActor
func runOverlay(_ args: [String]) {
    if args.contains("--help") {
        print("usage: sitr-spike overlay [--long-side PX=1280] [--skip-fullscreen]")
        exit(0)
    }
    let longSide = option(args, "--long-side", default: 1280)
    Rig.boot()
    Rig.deadline(60, "overlay")
    Rig.run {
        let d = mainDisplayBounds()
        // Overlay panel: whole main display, transparent, click-through, above the screen saver level; one solid red rectangle.
        let panel = Rig.panel(NSRect(x: 0, y: 0, width: d.width, height: d.height),
                              level: NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1), color: nil)
        panel.ignoresMouseEvents = true
        let redRect = CGRect(x: (d.width - 400) / 2, y: (d.height - 300) / 2, width: 400, height: 300)  // AppKit coords == screen points here
        let red = CALayer()
        red.backgroundColor = NSColor.red.cgColor
        red.frame = redRect
        panel.contentView!.layer!.addSublayer(red)
        panel.orderFrontRegardless()
        // Target window beneath the rectangle: solid blue, records mouseDown. Level .screenSaver = above the user's windows, below the panel.
        let target = Rig.panel(redRect.insetBy(dx: -60, dy: -60), level: .screenSaver, color: .blue)
        let clickView = ClickView(frame: target.contentView!.bounds)
        clickView.autoresizingMask = [.width, .height]
        target.contentView!.addSubview(clickView)
        target.orderFrontRegardless()
        let centre = CGPoint(x: redRect.midX, y: redRect.midY)
        try await Task.sleep(for: .milliseconds(500))

        let content = try await RigStream.shareable()
        let display = RigStream.mainDisplay(content)
        let ownApp = content.applications.first { $0.processID == getpid() }
        let panelWindows = content.windows.filter { $0.windowID == CGWindowID(max(0, panel.windowNumber)) }
        let targetWindows = content.windows.filter { $0.windowID == CGWindowID(max(0, target.windowNumber)) }
        print("overlay_own_process listed_in_SCShareableContent=\(ownApp != nil) name=\(ownApp?.applicationName ?? "-") "
            + "bundle=\(ownApp?.bundleIdentifier ?? "-") panel_scwindows=\(panelWindows.count) target_scwindows=\(targetWindows.count)")

        // (name, filter, red expected at the centre?)
        var phases: [(String, SCContentFilter, Bool)] = []
        if let app = ownApp {
            phases.append(("excludingApplications", SCContentFilter(display: display, excludingApplications: [app], exceptingWindows: []), false))
            phases.append(("excludingApplications+exceptingTarget", SCContentFilter(display: display, excludingApplications: [app], exceptingWindows: targetWindows), false))
        }
        phases.append(("excludingWindows(panel)", SCContentFilter(display: display, excludingWindows: panelWindows), false))
        phases.append(("none", SCContentFilter(display: display, excludingWindows: []), true))
        var worked: [String] = []
        for (name, filter, expectRed) in phases {
            let s = try await sampleFrames(filter, longSide: longSide, points: [centre], seconds: 1.5)[0]
            let redPresent = s.red > 0
            let ok = s.n > 0 && redPresent == expectRed
            if ok && !expectRed { worked.append(name) }
            print("overlay_red filter=\(name) present=\(redPresent) expected=\(expectRed) ok=\(ok) frames=\(s.n) red_frames=\(s.red) "
                + "blue_frames=\(s.blue) last_rgb=\(rgbString(s.last))")
        }
        print("overlay_exclusion_api worked=\(worked.isEmpty ? "NONE" : worked.joined(separator: ","))")

        // Fullscreen: a normal window the rig owns goes fullscreen; the panel must stay above it (no exclusion, so red must show).
        if !args.contains("--skip-fullscreen") {
            target.orderOut(nil)
            let fs = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 400),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            Rig.track(fs)
            fs.title = "sitr-spike fullscreen"
            fs.collectionBehavior = [.fullScreenPrimary]
            fs.contentView!.wantsLayer = true
            fs.contentView!.layer!.backgroundColor = NSColor.systemGreen.cgColor
            fs.orderFrontRegardless()
            NSApplication.shared.activate()
            fs.toggleFullScreen(nil)
            try await Task.sleep(for: .seconds(2.5))
            let entered = fs.styleMask.contains(.fullScreen)
            let outside = CGPoint(x: redRect.minX - 120, y: redRect.midY)
            let s = try await sampleFrames(SCContentFilter(display: display, excludingWindows: []), longSide: longSide,
                                           points: [centre, outside], seconds: 1.5)
            let green = s[1].last.map { $0.g > 140 && $0.r < 120 && $0.b < 140 } ?? false
            print("overlay_fullscreen entered=\(entered) red_over_fullscreen=\(s[0].n > 0 && s[0].red == s[0].n) "
                + "fullscreen_window_visible_beside=\(green) centre_rgb=\(rgbString(s[0].last)) beside_rgb=\(rgbString(s[1].last)) frames=\(s[0].n)")
            fs.toggleFullScreen(nil)
            try await Task.sleep(for: .seconds(2))
            fs.close()
            target.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(300))
        }

        // Click-through: synthetic click at the centre. Control run with the panel hidden tells whether posting works at all.
        let saved = CGEvent(source: nil)?.location
        panel.orderOut(nil)
        try await Task.sleep(for: .milliseconds(200))
        let before = clickView.hits
        postClick(CGPoint(x: centre.x, y: d.height - centre.y))
        try await Task.sleep(for: .milliseconds(400))
        let control = clickView.hits - before
        panel.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(300))
        let before2 = clickView.hits
        postClick(CGPoint(x: centre.x, y: d.height - centre.y))
        try await Task.sleep(for: .milliseconds(400))
        let through = clickView.hits - before2
        if let saved { CGWarpMouseCursorPosition(saved) }
        if control == 0 {
            print("overlay_clickthrough manual pending: CGEvent click not delivered even without the panel (AXIsProcessTrusted=\(AXIsProcessTrusted()))")
        } else {
            print("overlay_clickthrough passed=\(through > 0) control_hits=\(control) hits_through_panel=\(through)")
        }
        print("overlay_space_switch manual pending (rig never switches the user's Spaces)")
        print("overlay_safari_fullscreen_video manual pending (rig never touches the user's apps)")
        Rig.finish(0)
    }
}

struct Samples {
    var n = 0, red = 0, blue = 0
    var last: (r: Int, g: Int, b: Int)?
}

/// Streams the main display through `filter` for `seconds` and samples every `.complete` frame at `points` (screen points).
@MainActor
func sampleFrames(_ filter: SCContentFilter, longSide: Int, points: [CGPoint], seconds: Double) async throws -> [Samples] {
    let rig = RigStream()
    try await rig.start(filter: filter, longSide: longSide)
    var out = Array(repeating: Samples(), count: points.count)
    let end = CACurrentMediaTime() + seconds
    for await f in rig.frames {  // idle frames keep this loop ticking on a static screen
        if CACurrentMediaTime() > end { break }
        guard f.info.status == .complete, let pb = f.pixels else { continue }
        for (i, pt) in points.enumerated() {
            let (x, y) = capturePixel(pt, in: pb)
            guard let c = sampleRGB(pb, x: x, y: y) else { continue }
            out[i].n += 1
            if isRed(c) { out[i].red += 1 }
            if isBlue(c) { out[i].blue += 1 }
            out[i].last = c
        }
    }
    await rig.stop()
    return out
}

/// Left click at a CoreGraphics global point (origin top-left). Moves the real cursor; callers restore it.
func postClick(_ p: CGPoint) {
    let src = CGEventSource(stateID: .hidSystemState)
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
}

final class ClickView: NSView {
    var hits = 0
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { hits += 1 }
}
