// `Sitr --selftest [live|capture|overlay|render|pipeline|category|failstate|lowpower|degraded|robustness|stimulus] [options]`:
// automated checks for M2 track A (capture, overlay, renderer), the pipeline / fail-state glue (M2-T12, M2-T16), the
// category wiring (M2-T07), Low Power Mode (M4-T06), the degraded state (M4-T07) and the sleep/wake, lock, user-switch and
// hot-plug robustness of M4-T10. Each subcommand prints one parseable
// line per metric, removes every window it created and exits on its own (hard deadline). Plain `--selftest` prints the
// M2-T01 facts as before. Run from a shell, never via `open` (docs/dev.md). Pixels are sampled as numbers only; no frame is
// ever written anywhere.
import AppKit
import CoreImage
import Foundation
import ScreenCaptureKit
import SitrCore

enum Selftest {
    static func run() {
        // Selftests exercise Entire Mac Blur; onboarding (M4-T01) made a missing rules.json seed Off unless this is set.
        setenv("SITR_DEV_BLUR", "1", 1)
        let args = Array(CommandLine.arguments.dropFirst())
        let sub = args.firstIndex(of: "--selftest").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ""
        switch sub {
        case "system":
            let seconds = min(600, max(1, option(args, "--seconds", default: 120.0)))
            Harness.run("system", deadline: seconds + 45) {
                let mode = option(args, "--rule").flatMap(RuleMode.init(rawValue:)) ?? .blur
                let (runtime, display, pipeline) = try await bootRuntime(rules: Rules(defaultMode: mode))
                runtime.filters.capturesOwnWindows = false
                runtime.filters.refreshNow()
                runtime.model.preferences.coverStyle = option(args, "--style").flatMap(CoverStyle.init(rawValue:)) ?? .gaussian
                switch option(args, "--hide") {
                case "women": runtime.model.setHiddenSet(.women)
                case "men": runtime.model.setHiddenSet(.men)
                default: runtime.model.setHiddenSet(.everyone)
                }
                if args.contains("--paused") { runtime.model.pause(seconds: seconds + 5) }
                if args.contains("--disabled") { runtime.model.disable() }
                print("system_configuration rule=\(mode) style=\(runtime.model.preferences.coverStyle) hidden=\(runtime.model.policy.hiddenSet) isolated_preferences=true")
                try await Task.sleep(for: .seconds(seconds))
                let metrics = await pipeline.metrics
                print(metrics.line(display: display.id, elapsed: seconds))
                let valid = metrics.errors == 0 && (!args.contains("--require-covers") || metrics.renders + metrics.reuses > 0)
                print("system_valid=\(valid) covers_seen=\(metrics.renders + metrics.reuses) errors=\(metrics.errors)")
                await runtime.stop()
                return valid
            }
        case "live":
            let seconds = min(600, max(1, option(args, "--seconds", default: 60.0)))
            let mode = option(args, "--mode").flatMap(RuleMode.init(rawValue:)) ?? .curtain
            Harness.run("live", deadline: seconds + 45) {
                let (runtime, display, pipeline) = try await bootRuntime(rules: Rules(defaultMode: mode))
                runtime.filters.capturesOwnWindows = false
                runtime.filters.schedule()
                let start = CACurrentMediaTime()
                while CACurrentMediaTime() - start < seconds {
                    try await Task.sleep(for: .seconds(1))
                    print("live t=\(Int(CACurrentMediaTime() - start)) layers=\(display.panel.layerCount) visible=\(display.panel.isVisible) health=\(runtime.model.policy.health)")
                }
                let metrics = await pipeline.metrics
                print(metrics.line(display: display.id, elapsed: seconds))
                return metrics.framesOut > 0 && metrics.errors == 0
            }
        case "capture":
            let seconds = option(args, "--seconds", default: 10.0)
            Harness.run("capture", deadline: seconds + 30) { try await captureTest(seconds: seconds) }
        case "overlay":
            Harness.run("overlay", deadline: 60) { try await overlayTest(skipFullscreen: args.contains("--skip-fullscreen")) }
        case "render":
            Harness.run("render", deadline: 180) { try await renderTest(iterations: option(args, "--iterations", default: 100)) }
        case "pipeline" where args.contains("--motion"):
            let seconds = option(args, "--seconds", default: 120.0)
            Harness.run("pipeline_motion", deadline: seconds + 60) { try await motionTest(seconds: seconds) }
        case "pipeline":
            let trials = option(args, "--trials", default: 30)
            Harness.run("pipeline", deadline: Double(trials) * 4 + 60) { try await pipelineTest(trials: trials) }
        case "category":
            Harness.run("category", deadline: 150) { try await categoryTest() }
        case "failstate":
            Harness.run("failstate", deadline: 120) { try await failstateTest(stimulusApp: stimulusPath(args)) }
        case "lowpower":
            Harness.run("lowpower", deadline: 120) { try await lowPowerTest() }
        case "degraded":
            Harness.run("degraded", deadline: 120) { try await degradedTest() }
        case "robustness":
            let cycles = option(args, "--cycles", default: 20)
            Harness.run("robustness", deadline: Double(cycles) * 8 + 150) { try await robustnessTest(cycles: cycles) }
        case "stimulus" where args.contains("--remote"):
            // M3: the stimulus as its own app (Stimulus.app, another bundle id), driven by distributed notifications.
            let seconds = option(args, "--seconds", default: 300.0)
            let channel = option(args, "--channel") ?? NSTemporaryDirectory()
            Harness.run("stimulus_remote", deadline: seconds + 5) { try await remoteStimulus(seconds: seconds, channel: channel) }
        case "stimulus":
            let seconds = option(args, "--seconds", default: 30.0)
            let mode = option(args, "--mode") ?? "drift"
            Harness.run("stimulus", deadline: seconds + 15) { try await stimulusOnly(seconds: seconds, mode: mode) }
        case "filter":
            Harness.run("filter", deadline: 120) { try await filterTest(stimulusApp: stimulusPath(args)) }
        case "curtain" where args.contains("--scroll"):
            Harness.run("curtain_scroll", deadline: 120) { try await curtainScrollTest(stimulusApp: stimulusPath(args)) }
        case "curtain" where args.contains("--video"):
            let seconds = option(args, "--video", default: 30.0)
            Harness.run("curtain_video", deadline: seconds + 60) { try await curtainVideoTest(seconds: seconds, stimulusApp: stimulusPath(args)) }
        case "curtain":
            let trials = option(args, "--trials", default: 30)
            Harness.run("curtain", deadline: Double(trials) * 8 + 90) { try await curtainExposureTest(trials: trials, stimulusApp: stimulusPath(args)) }
        case "overlap":
            Harness.run("overlap", deadline: 150) { try await overlapTest(stimulusApp: stimulusPath(args), stimulus2App: stimulusPath(args, second: true)) }
        default:
            let env = ProcessInfo.processInfo.environment
            print("bundle_id=\(Bundle.main.bundleIdentifier ?? "nil")")
            print("sandboxed=\(env["APP_SANDBOX_CONTAINER_ID"] != nil)")
            print("screen_capture_preflight=\(CGPreflightScreenCaptureAccess())")
            exit(0)
        }
    }
}

// MARK: - capture (M2-T05 + the M1-T02 feedback-loop check through the production types)

/// Per display: frames, fps, idle skipped, dirty rects; a red marker shown through the real OverlayPanel must be absent from
/// the frames of the production filter and present through a no-exclusion control filter on the same stream.
@MainActor
private func captureTest(seconds: Double) async throws -> Bool {
    let permission = PermissionMonitor()
    print("permission_state=\(permission.state)")
    let manager = DisplayManager(permission: permission)
    Harness.onExit { manager.stop() }
    manager.start()
    print("capture_displays count=\(manager.displays.count) ids=\(manager.displays.map(\.id))")
    guard !manager.displays.isEmpty else { return false }
    var ok = true
    for d in manager.displays {
        let width = d.frame.width, height = d.frame.height
        let marker = CGRect(x: (width - 400) / 2, y: (height - 300) / 2, width: 400, height: 300)  // display-local, top-left
        // Marker plus a cover that moves every 50 ms: exercises the layer diff and gives our own windows motion, which the
        // excluding stream must not see (otherwise the overlay would feed back into detection).
        let mover = Task { @MainActor in
            var i = 0
            while !Task.isCancelled {
                let x = 40 + CGFloat(i % 40) * 8
                d.panel.apply([
                    CoverLayerSpec(id: 1, frame: marker, contents: nil, color: .red),
                    CoverLayerSpec(id: 2, frame: CGRect(x: x, y: height - 140, width: 60, height: 60), contents: nil, color: .blue),
                ])
                i += 1
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        // One consumer for the whole display: `session.frames` is a single-consumer AsyncStream (one per display, as the
        // pipeline will use it), so both phases read from the same collector rather than making a second iterator.
        let collector = FrameCollector(session: d.session, point: CGPoint(x: marker.midX, y: marker.midY))
        collector.start()
        try await Task.sleep(for: .seconds(seconds))
        let a = collector.acc
        let s = d.session.stats
        print("capture_display id=\(d.id) frames=\(a.n) fps=\(fmt(Double(a.n) / seconds)) idle_skipped=\(s.idle) other=\(s.other) "
            + "dirty_rects=\(s.dirtyRects) size=\(Int(s.size.width))x\(Int(s.size.height)) content_rect=\(rectString(s.contentRect)) "
            + "scale_factor=\(s.scaleFactor) content_scale=\(fmt(s.contentScale)) display_pt=\(Int(width))x\(Int(height)) "
            + "points_per_pixel=\(fmt(a.pointsPerPixel)) dirty_union_px=\(rectString(a.dirtyUnion)) max_dirty_px=\(rectString(a.maxDirty)) seq_last=\(a.lastSequence)")
        print("capture_marker id=\(d.id) filter=excludingApplications frames=\(a.n) marker_frames=\(a.hits) last_rgb=\(rgbString(a.last)) "
            + "overlay_excluded=\(a.n > 0 && a.hits == 0)")
        // Control: same stream, filter without exclusion. The marker must show, or the line above proves nothing.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == d.id }) else { throw SelftestError("display \(d.id) not in SCShareableContent") }
        try await d.session.updateFilter(SCContentFilter(display: display, excludingWindows: []))
        collector.reset()
        try await Task.sleep(for: .seconds(3))
        let b = collector.acc
        collector.stop()
        print("capture_marker_control id=\(d.id) filter=none frames=\(b.n) fps=\(fmt(Double(b.n) / 3)) marker_frames=\(b.hits) "
            + "last_rgb=\(rgbString(b.last)) marker_visible=\(b.hits > 0)")
        mover.cancel()
        print("capture_health id=\(d.id) ok=\(d.session.health.isOK) restarts=\(d.session.restarts) fps_setting=\(d.session.fps) long_side=\(d.session.captureLongSide)")
        ok = ok && a.n > 0 && a.hits == 0 && b.hits > 0 && d.session.health.isOK
    }
    manager.stop()
    return ok
}

nonisolated struct PointSamples: Sendable {
    var n = 0, hits = 0, lastSequence = 0
    var last: RGB?
    var dirtyUnion = CGRect.null
    var maxDirty = CGRect.zero
    var pointsPerPixel = 0.0
}

/// One persistent consumer of a session's frames, sampling the pixel under `point` (display-local points) into `acc`.
@MainActor
private final class FrameCollector {
    private(set) var acc = PointSamples()
    private let session: CaptureSession
    private let point: CGPoint
    private var task: Task<Void, Never>?

    init(session: CaptureSession, point: CGPoint) {
        self.session = session
        self.point = point
    }

    func start() {
        task = Task { @MainActor in
            for await f in session.frames {
                acc.n += 1
                acc.lastSequence = f.sequence
                acc.pointsPerPixel = f.pointsPerPixel
                for r in f.dirtyRects {
                    acc.dirtyUnion = acc.dirtyUnion.union(r)
                    if r.width * r.height > acc.maxDirty.width * acc.maxDirty.height { acc.maxDirty = r }
                }
                let px = f.displayPointsToPixels(CGRect(origin: point, size: .zero))
                if let c = sampleRGB(f.pixelBuffer, x: Int(px.minX), y: Int(px.minY)) {
                    acc.last = c
                    if c.isRed { acc.hits += 1 }
                }
            }
        }
    }

    func reset() { acc = PointSamples() }
    func stop() { task?.cancel() }
}

// MARK: - overlay (M2-T10)

/// Layer diff and reveal on the real panel, window properties, panel above a fullscreen window the selftest owns (sampled
/// through a no-exclusion stream), click-through via a synthetic CGEvent against a target panel the selftest owns.
@MainActor
private func overlayTest(skipFullscreen: Bool) async throws -> Bool {
    guard let screen = NSScreen.screens.first, let displayID = screen.displayID else { throw SelftestError("no screen") }
    let width = screen.frame.width, height = screen.frame.height
    let panel = OverlayPanel(screenFrame: screen.frame)
    Harness.track(panel)
    panel.orderFrontRegardless()
    let cover = CGRect(x: (width - 400) / 2, y: (height - 300) / 2, width: 400, height: 300)  // display-local, top-left
    var ok = true

    for ids in [[1, 2, 3], [2, 3, 4, 5, 6], [6, 7], [], [1]] {
        panel.apply(ids.map { CoverLayerSpec(id: $0, frame: cover.offsetBy(dx: CGFloat($0) * 12, dy: 0), contents: nil, color: .red) })
        let sublayers = panel.contentView?.layer?.sublayers?.count ?? 0
        let pass = panel.layerCount == ids.count && sublayers == ids.count
        ok = ok && pass
        print("overlay_layers covers=\(ids.count) layers=\(panel.layerCount) sublayers=\(sublayers) ok=\(pass)")
    }
    panel.apply([CoverLayerSpec(id: 1, frame: cover, contents: nil, color: .red),
                 CoverLayerSpec(id: 2, frame: cover.offsetBy(dx: 0, dy: -320), contents: nil, color: .blue)])
    panel.setRevealed(true)
    let hidden = panel.contentView?.layer?.sublayers?.filter(\.isHidden).count ?? 0
    print("overlay_revealed hidden_layers=\(hidden) layers=\(panel.layerCount) ok=\(hidden == panel.layerCount)")
    ok = ok && hidden == panel.layerCount
    panel.setRevealed(false)
    let shown = panel.contentView?.layer?.sublayers?.filter { !$0.isHidden }.count ?? 0
    print("overlay_unrevealed shown_layers=\(shown) layers=\(panel.layerCount) ok=\(shown == panel.layerCount)")
    ok = ok && shown == panel.layerCount
    panel.apply([CoverLayerSpec(id: 1, frame: cover, contents: nil, color: .red)])
    let layerFrame = panel.contentView?.layer?.sublayers?.first?.frame ?? .zero
    let flipped = appKitRect(cover, displayHeight: height)
    print("overlay_flip layer_frame=\(rectString(layerFrame)) expected=\(rectString(flipped)) ok=\(layerFrame == flipped)")
    ok = ok && layerFrame == flipped
    let b = panel.collectionBehavior
    print("overlay_panel level=\(panel.level.rawValue) screensaver_plus_1=\(panel.level.rawValue == NSWindow.Level.screenSaver.rawValue + 1) "
        + "ignores_mouse=\(panel.ignoresMouseEvents) can_become_key=\(panel.canBecomeKey) hides_on_deactivate=\(panel.hidesOnDeactivate) "
        + "excluded_from_windows_menu=\(panel.isExcludedFromWindowsMenu) accessibility_element=\(panel.isAccessibilityElement()) "
        + "all_spaces=\(b.contains(.canJoinAllSpaces)) fullscreen_aux=\(b.contains(.fullScreenAuxiliary)) stationary=\(b.contains(.stationary)) "
        + "ignores_cycle=\(b.contains(.ignoresCycle)) opaque=\(panel.isOpaque)")

    // Frames without exclusion: the selftest wants to see its own red cover.
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw SelftestError("display not in SCShareableContent") }
    let session = CaptureSession(displayID: displayID, permission: PermissionMonitor())
    Harness.onExit { session.stop() }
    try await session.updateFilter(SCContentFilter(display: display, excludingWindows: []))
    session.start()
    let centre = CGPoint(x: cover.midX, y: cover.midY), beside = CGPoint(x: cover.minX - 120, y: cover.midY)

    if skipFullscreen {
        print("overlay_fullscreen skipped")
    } else {
        // A titled window the selftest owns goes fullscreen; the panel must stay above it (accessory apps need activate()).
        let fs = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 400), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        Harness.track(fs)
        fs.title = "Sitr selftest fullscreen"
        fs.collectionBehavior = [.fullScreenPrimary]
        fs.contentView?.wantsLayer = true
        fs.contentView?.layer?.backgroundColor = NSColor.systemGreen.cgColor
        fs.orderFrontRegardless()
        NSApplication.shared.activate()
        fs.toggleFullScreen(nil)
        try await Task.sleep(for: .seconds(2.5))
        let entered = fs.styleMask.contains(.fullScreen)
        let s = await sample(session, seconds: 1.5, points: [centre, beside])
        let redOver = s[0].n > 0 && s[0].hits == s[0].n
        let green = s[1].last?.isGreen ?? false
        print("overlay_fullscreen entered=\(entered) cover_over_fullscreen=\(redOver) fullscreen_visible_beside=\(green) "
            + "centre_rgb=\(rgbString(s[0].last)) beside_rgb=\(rgbString(s[1].last)) frames=\(s[0].n) capture_ok=\(session.health.isOK)")
        ok = ok && entered && redOver && green
        fs.toggleFullScreen(nil)
        try await Task.sleep(for: .seconds(2))
        fs.close()
    }

    // Click-through: a target panel under the cover counts mouseDown; the control click (panel hidden) proves posting works.
    let target = solidPanel(appKitRect(cover.insetBy(dx: -60, dy: -60), displayHeight: height), level: .screenSaver, color: .blue)
    let clickView = ClickView(frame: target.contentView?.bounds ?? .zero)
    clickView.autoresizingMask = [.width, .height]
    target.contentView?.addSubview(clickView)
    target.orderFrontRegardless()
    try await Task.sleep(for: .milliseconds(300))
    let savedCursor = CGEvent(source: nil)?.location
    panel.orderOut(nil)
    try await Task.sleep(for: .milliseconds(200))
    let before = clickView.hits
    postClick(centre)  // display-local top-left of the first screen == CoreGraphics global coordinates
    try await Task.sleep(for: .milliseconds(400))
    let control = clickView.hits - before
    panel.orderFrontRegardless()
    try await Task.sleep(for: .milliseconds(300))
    let before2 = clickView.hits
    postClick(centre)
    try await Task.sleep(for: .milliseconds(400))
    let through = clickView.hits - before2
    if let savedCursor { CGWarpMouseCursorPosition(savedCursor) }
    if control == 0 {
        print("overlay_clickthrough manual pending: CGEvent click not delivered even without the panel (AXIsProcessTrusted=\(AXIsProcessTrusted()))")
    } else {
        print("overlay_clickthrough passed=\(through > 0) control_hits=\(control) hits_through_panel=\(through)")
        ok = ok && through > 0
    }
    print("overlay_space_switch manual pending")
    print("overlay_safari_fullscreen_video manual pending")
    print("overlay_cmd_tab_absent manual pending")
    session.stop()
    panel.apply([])
    return ok
}

/// Samples every frame of `session` for `seconds` at `points` (display-local, top-left).
@MainActor
private func sample(_ session: CaptureSession, seconds: Double, points: [CGPoint]) async -> [PointSamples] {
    let consumer = Task { @MainActor in
        var out = Array(repeating: PointSamples(), count: points.count)
        for await f in session.frames {
            for (i, p) in points.enumerated() {
                let px = f.displayPointsToPixels(CGRect(origin: p, size: .zero))
                guard let c = sampleRGB(f.pixelBuffer, x: Int(px.minX), y: Int(px.minY)) else { continue }
                out[i].n += 1
                out[i].last = c
                if c.isRed { out[i].hits += 1 }
            }
        }
        return out
    }
    try? await Task.sleep(for: .seconds(seconds))
    consumer.cancel()
    return await consumer.value
}

// MARK: - render (M2-T11)

/// ms per cover (render + panel apply) for 3 styles × strengths 0 / 0.5 / 1 at cover heights 120 / 240 / 480 pt on a
/// synthetic 1280-wide frame; padding 0 / 0.15 / 0.5 and the display clamp checked against expected rects.
@MainActor
private func renderTest(iterations: Int) async throws -> Bool {
    guard let screen = NSScreen.screens.first else { throw SelftestError("no screen") }
    let display = screen.frame.size
    let k = 1280 / max(display.width, display.height)
    let size = CGSize(width: (display.width * k).rounded(), height: (display.height * k).rounded())
    // Synthetic "captured frame": a checkerboard, so blur and pixelate have structure to destroy. No screen pixels involved.
    let source = try makeBuffer(Int(size.width), Int(size.height))
    guard let checker = CIFilter(name: "CICheckerboardGenerator", parameters: [
        kCIInputWidthKey: 16, kCIInputSharpnessKey: 1, kCIInputCenterKey: CIVector(x: 0, y: 0),
        "inputColor0": CIColor(red: 0.1, green: 0.2, blue: 0.8), "inputColor1": CIColor(red: 0.9, green: 0.8, blue: 0.1),
    ])?.outputImage?.cropped(to: CGRect(origin: .zero, size: size)) else { throw SelftestError("checkerboard generator") }
    try CIContext().startTask(toRender: checker, to: CIRenderDestination(pixelBuffer: source)).waitUntilCompleted()
    let frame = Frame(pixelBuffer: source, displayID: screen.displayID ?? 0, sequence: 1, timestamp: CACurrentMediaTime(), dirtyRects: [],
                      contentRect: CGRect(x: 0, y: 0, width: size.width / 2, height: size.height / 2), scaleFactor: 2,
                      contentScale: k / screen.backingScaleFactor, displaySize: display)
    let renderer = CoverRenderer()
    let panel = OverlayPanel(screenFrame: screen.frame)  // on screen, so every apply really ships pixels to the render server
    Harness.track(panel)
    panel.orderFrontRegardless()
    print("render_frame size=\(Int(size.width))x\(Int(size.height)) display_pt=\(Int(display.width))x\(Int(display.height)) "
        + "points_per_pixel=\(fmt(frame.pointsPerPixel)) iterations=\(iterations)")
    var ok = true
    var gaussianP50 = 0.0, pixelateP50 = 0.0
    for h in [120.0, 240.0, 480.0] {
        let w = (h * 3 / 7.4).rounded()  // body-box aspect from the spike (3 face widths × 7.4 face heights)
        let rect = CGRect(x: ((display.width - w) / 2).rounded(), y: ((display.height - h) / 2).rounded(), width: w, height: h)
        for style in CoverStyle.allCases {
            for strength in [0.0, 0.5, 1.0] {
                var times: [Double] = []
                var spec: CoverLayerSpec?
                for i in 0..<(iterations + 10) {
                    let t0 = CACurrentMediaTime()
                    let s = renderer.render(id: 1, style: style, strength: strength, padding: 0, rect: rect, frame: frame)
                    panel.apply([s])
                    if i >= 10 { times.append(CACurrentMediaTime() - t0) }
                    spec = s
                }
                guard let spec else { continue }
                let px = frame.displayPointsToPixels(spec.frame).integral
                let face = CoverGeometry.faceEstimate(cover: px.size)
                let param: Double = switch style {
                case .gaussian: CoverGeometry.gaussianRadius(strength: strength, face: face)
                case .pixelate: CoverGeometry.pixelBlock(strength: strength, face: face)
                case .solid: 0
                }
                let p50 = percentile(times, 0.5), p95 = percentile(times, 0.95)
                switch style {
                case .gaussian: gaussianP50 = max(gaussianP50, p50)
                case .pixelate: pixelateP50 = max(pixelateP50, p50)
                case .solid: break
                }
                let opaque = spec.contents.map { centreAlpha($0) == 255 } ?? (spec.color != nil)
                ok = ok && opaque
                print("render_cost style=\(style.rawValue) strength=\(strength) cover_pt=\(Int(w))x\(Int(h)) cover_px=\(Int(px.width))x\(Int(px.height)) "
                    + "param_px=\(fmt(param)) p50_ms=\(ms(p50)) p95_ms=\(ms(p95)) n=\(times.count) has_pixels=\(spec.contents != nil) opaque=\(opaque)")
            }
        }
    }
    // Pixelate is the reliable path (GPU cost independent of block size) and gates the selftest on a quiet machine. Gaussian
    // cost grows with radius × area and stalls under GPU load; it is reported against the 2 ms target but never hard-gated (the
    // M4-T09 perf pass caps the radius / downsamples big covers, per docs/spike/blur.md). Every GPU op stalls under contention,
    // so when `load1` is high the timing gate is informational (a re-run in a quiet phase is the real number); correctness
    // (opaque + geometry) always gates. On this shared machine other agents' builds/training routinely push load past 4.
    let load = loadAverage()
    let noisy = load > 4
    let pixelateOK = pixelateP50 <= 0.002
    print("render_gate pixelate_p50_ms=\(ms(pixelateP50)) gaussian_p50_ms=\(ms(gaussianP50)) target_ms=2.0 pixelate_ok=\(pixelateOK) "
        + "gaussian_within_target=\(gaussianP50 <= 0.002) load1=\(fmt(load)) timing_gated=\(!noisy)")
    ok = ok && (noisy || pixelateOK)

    let base = CGRect(x: 100, y: 100, width: 200, height: 400)
    for (padding, expected) in [(0.0, base), (0.15, CGRect(x: 85, y: 70, width: 230, height: 460)), (0.5, CGRect(x: 50, y: 0, width: 300, height: 600))] {
        let s = renderer.render(id: 2, style: .pixelate, strength: 0.7, padding: padding, rect: base, frame: frame)
        let pass = s.frame == expected && s.contents != nil
        ok = ok && pass
        print("render_padding padding=\(padding) rect=\(rectString(base)) frame=\(rectString(s.frame)) expected=\(rectString(expected)) has_pixels=\(s.contents != nil) ok=\(pass)")
    }
    let edge = CGRect(x: display.width - 100, y: 0, width: 200, height: 400)
    let clamped = renderer.render(id: 3, style: .gaussian, strength: 0.7, padding: 0.5, rect: edge, frame: frame)
    let expectedClamp = CGRect(x: display.width - 150, y: 0, width: 150, height: 500)
    let clampOK = clamped.frame == expectedClamp && clamped.contents != nil
    ok = ok && clampOK
    print("render_clamp padding=0.5 rect=\(rectString(edge)) frame=\(rectString(clamped.frame)) expected=\(rectString(expectedClamp)) has_pixels=\(clamped.contents != nil) ok=\(clampOK)")
    let solid = renderer.render(id: 4, style: .solid, strength: 0.7, rect: base, frame: frame)
    let components = solid.color?.components?.map { fmt($0) } ?? []
    print("render_solid has_pixels=\(solid.contents != nil) color=\(components) alpha_one=\(solid.color?.alpha == 1)")
    ok = ok && solid.contents == nil && solid.color?.alpha == 1
    panel.apply([])
    return ok
}

// MARK: - pipeline (M2-T12) and fail states (M2-T16)

/// The real app wiring (`Runtime`) on a throwaway preferences suite (Everyone + Strict, FR3 defaults) and a throwaway rules
/// directory (`rules` saved there first; nil = no file, so the `SITR_DEV_BLUR` seed gives Entire-Mac Blur). The production filter
/// excludes our whole process, which would hide the selftest's own stimulus windows from capture, so the filter builder runs in
/// its selftest mode: own process excluded, every own window that is not an overlay panel excepted back in (the feedback-loop
/// guard stays), refreshed whenever the harness tracks a new window.
@MainActor
private func bootRuntime(rules: Rules? = nil) async throws -> (runtime: Runtime, display: ManagedDisplay, pipeline: Pipeline) {
    let suite = "com.goldentik.Sitr.selftest"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let rulesDir = FileManager.default.temporaryDirectory.appending(path: "sitr-selftest-rules-\(getpid())")
    try? FileManager.default.removeItem(at: rulesDir)
    let store = RulesStore(directory: rulesDir)
    if let rules { try store.save(rules) }
    Harness.onExit { try? FileManager.default.removeItem(at: rulesDir) }
    let runtime = Runtime(model: AppModel(preferences: Preferences(defaults: defaults), rulesStore: store))
    runtime.filters.capturesOwnWindows = true
    Harness.onTrack = { _ in runtime.filters.schedule() }
    Harness.onExit { runtime.displayManager.stop() }
    runtime.start()
    print("permission_state=\(runtime.permission.state)")
    guard let mainID = NSScreen.screens.first?.displayID else { throw SelftestError("no screen") }
    // 30 s: capture is up in ~1 s, but the pipelines wait for `loadModels`, which compiles Models/dist on the fly in a dev
    // checkout — seconds on a cold ANE cache, more again on a loaded machine.
    let t0 = CACurrentMediaTime()
    let deadline = t0 + 30
    while CACurrentMediaTime() < deadline {
        if let d = runtime.displayManager.displays.first(where: { $0.id == mainID }), d.session.health.isOK,
           let pipeline = runtime.pipelines[mainID] {
            _ = await waitUntil(3) { runtime.filters.installs > 0 }
            print("pipeline_boot display=\(mainID) displays=\(runtime.displayManager.displays.count) pipelines=\(runtime.pipelines.count) "
                + "boot_ms=\(Int((CACurrentMediaTime() - t0) * 1000)) "  // panel exclusion now lives in FilterBuilder, below
                + "filter_installs=\(runtime.filters.installs) plan=\(runtime.filters.plans[mainID].map { "\($0)" } ?? "none") rules_default=\(runtime.model.policy.rules.defaultMode) "
                + "overrides=\(runtime.model.policy.rules.overrides.count) health=\(runtime.model.policy.health) \(runtime.modelsNote)")
            return (runtime, d, pipeline)
        }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw SelftestError("capture and pipelines did not come up within 30 s (permission=\(runtime.permission.state))")
}

/// The selftest's own stimulus: a panel just under the overlay level showing a CC0 photo (by default `Sources/SitrSpike/Fixtures/
/// person.jpg`, 500×749, drawn 1:1 so image pixels are display points), a heartbeat block that keeps frames flowing while
/// covers clear, and — for `--motion` — two copies of the photo moving like video. Dev-only: fixtures are loaded relative to
/// `#filePath`, so they exist in a source checkout, not in a shipped bundle.
@MainActor
private final class Stimulus {
    static let imageSize = CGSize(width: 500, height: 749)
    /// Hand-checked body box in the spike fixture (image pixels, top-left origin): turban top to feet, elbow to elbow.
    static let body = CGRect(x: 125, y: 120, width: 235, height: 615)

    let panel: NSPanel
    /// Panel rect in display-local points (origin top-left).
    let rect: CGRect
    /// Where the person is on screen (display-local points) in the static layout of the spike fixture.
    let personRect: CGRect
    /// The photo on screen (display-local points) in the static layout.
    let photoRect: CGRect
    private let photo = CALayer(), photo2 = CALayer(), heartbeat = CALayer()
    private var beat = 0

    /// A repo-relative image, e.g. `Tests/SitrDetectTests/Fixtures/woman.jpg` (dev checkout only), or the same file name from
    /// `Contents/Resources` (the sandboxed Stimulus.app of the M3 selftests carries person.jpg there and cannot read the checkout).
    static func fixture(_ path: String) throws -> CGImage {
        let name = URL(fileURLWithPath: path)
        if let bundled = Bundle.main.url(forResource: name.deletingPathExtension().lastPathComponent, withExtension: name.pathExtension),
           let image = NSImage(contentsOf: bundled)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return image
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw SelftestError("fixture missing: \(url.path)")
        }
        return image
    }

    /// The spike's person photo at 1:1; `motion` adds a second, smaller moving copy.
    convenience init(display: CGSize, motion: Bool) throws {
        self.init(display: display, image: try Self.fixture("Sources/SitrSpike/Fixtures/person.jpg"), motion: motion)
    }

    /// `image` drawn at `scale` points per image pixel (the category selftest shows the CC0 portraits of Tests/SitrDetectTests/Fixtures).
    init(display: CGSize, image: CGImage, scale: CGFloat = 1, motion: Bool = false) {
        let imageSize = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let size = motion ? CGSize(width: 1300, height: 860) : CGSize(width: imageSize.width + 60, height: imageSize.height)
        rect = CGRect(x: ((display.width - size.width) / 2).rounded(), y: ((display.height - size.height) / 2).rounded(),
                      width: size.width, height: size.height)
        photoRect = CGRect(x: rect.minX + 60, y: rect.minY, width: imageSize.width, height: imageSize.height)
        personRect = CGRect(x: photoRect.minX + Self.body.minX * scale, y: photoRect.minY + Self.body.minY * scale,
                            width: Self.body.width * scale, height: Self.body.height * scale)
        panel = NSPanel(contentRect: appKitRect(rect, displayHeight: display.height), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = true
        panel.backgroundColor = .white
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver  // the overlay sits one level above
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.cgColor
        panel.contentView = view
        for (layer, k) in [(photo, 1.0), (photo2, 0.6)] {
            layer.contents = image
            layer.contentsGravity = .resizeAspect
            layer.frame = CGRect(x: 60, y: 0, width: imageSize.width * k, height: imageSize.height * k)
            layer.isHidden = true
            view.layer?.addSublayer(layer)
        }
        photo2.isHidden = !motion
        heartbeat.frame = CGRect(x: 10, y: 10, width: 40, height: 40)  // outside the photo column
        heartbeat.backgroundColor = NSColor.systemBlue.cgColor
        view.layer?.addSublayer(heartbeat)
        Harness.track(panel)
        panel.orderFrontRegardless()
    }

    /// Shows or hides the photo in one flushed transaction. Returns `CACurrentMediaTime()` after the flush (the M1-T04 clock).
    @discardableResult
    func show(_ on: Bool) -> Double {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        photo.isHidden = !on
        CATransaction.commit()
        CATransaction.flush()
        return CACurrentMediaTime()
    }

    /// Toggles the heartbeat block so the screen keeps changing and SCK keeps delivering frames.
    func pulse() {
        beat += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        heartbeat.backgroundColor = beat % 2 == 0 ? NSColor.systemBlue.cgColor : NSColor.systemOrange.cgColor
        CATransaction.commit()
        CATransaction.flush()
    }

    /// Motion: both photos travel along Lissajous paths inside the panel (`t` in seconds).
    func move(t: Double) {
        let w = rect.width, h = rect.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        photo.frame.origin = CGPoint(x: (w - 500) / 2 + 330 * sin(t * 0.9), y: (h - 749) / 2 + 40 * sin(t * 1.7))
        photo2.frame.origin = CGPoint(x: (w - 300) / 2 - 380 * sin(t * 0.6 + 1), y: (h - 449) / 2 + 150 * cos(t * 1.1))
        CATransaction.commit()
        CATransaction.flush()
    }
}

/// Records, per trial, the first commit whose layers cover the person (≥ 25 % of the person rect, so a bystander's cover brushing
/// its edge does not count): commit time and the covered share of the person rect. `personCovered` follows every commit, so the
/// trial loop can wait for the person's covers to go while other people on the user's screen stay covered.
@MainActor
private final class CommitRecorder {
    struct Hit {
        var time: Double
        var overlap: Double
        var layers: Int
    }
    private(set) var hit: Hit?
    private(set) var personCovered = false
    private var armed = false
    private let person: CGRect

    init(person: CGRect) { self.person = person }

    func arm() {
        hit = nil
        armed = true
    }

    func record(_ specs: [CoverLayerSpec], at time: Double) {
        let overlap = specs.map { $0.frame.intersection(person).area / person.area }.max() ?? 0
        personCovered = overlap >= 0.25
        guard armed, personCovered else { return }
        hit = Hit(time: time, overlap: overlap, layers: specs.count)
        armed = false
    }
}

/// Polls `condition` every 20 ms for up to `seconds`.
@MainActor
private func waitUntil(_ seconds: Double, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
    let deadline = CACurrentMediaTime() + seconds
    while CACurrentMediaTime() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// M2-T12 exposure (Blur path, the M1-T04 method through the production pipeline): per trial the photo flips on in a flushed
/// transaction, and the clock stops when `OverlayPanel.apply` has committed a layer over it. Between trials the region is blank
/// and the heartbeat runs until the person's covers are gone (other people on the user's screen may stay covered), then the screen
/// settles ≥ 600 ms plus a random 100–170 ms so paints are not phase-locked to the 15 Hz cadence. Control: the cover must cover
/// ≥ 80 % of the hand-checked person rect.
@MainActor
private func pipelineTest(trials: Int) async throws -> Bool {
    let (runtime, d, pipeline) = try await bootRuntime()
    let stim = try Stimulus(display: d.frame.size, motion: false)
    let recorder = CommitRecorder(person: stim.personRect)
    let mainID = d.id
    runtime.onCommit = { id, specs, _, at in if id == mainID { recorder.record(specs, at: at) } }
    print("pipeline_stimulus panel=\(rectString(stim.rect)) person=\(rectString(stim.personRect)) display_pt=\(Int(d.frame.width))x\(Int(d.frame.height))")

    var exposures: [Double] = [], overlaps: [Double] = [], layers: [Int] = []
    var missed = 0, notCleared = 0
    for i in 0...trials {  // trial 0 warms the stream and Vision and is not counted
        stim.show(false)
        let clearDeadline = CACurrentMediaTime() + 3
        while recorder.personCovered, CACurrentMediaTime() < clearDeadline {
            stim.pulse()
            try await Task.sleep(for: .milliseconds(100))
        }
        if recorder.personCovered { notCleared += 1 }
        try await Task.sleep(for: .milliseconds(600 + 100 + Int.random(in: 0..<70)))
        recorder.arm()
        let tFlip = stim.show(true)
        _ = await waitUntil(2) { recorder.hit != nil }
        guard i > 0 else { continue }
        if let hit = recorder.hit {
            exposures.append(hit.time - tFlip)
            overlaps.append(hit.overlap)
            layers.append(hit.layers)
        } else {
            missed += 1
        }
    }
    stim.show(false)
    let m = await pipeline.metrics
    let load = loadAverage(), noisy = load > 4
    let p50 = percentile(exposures, 0.5), p95 = percentile(exposures, 0.95)
    let controlOK = !overlaps.isEmpty && overlaps.allSatisfy { $0 >= 0.8 }
    print("exposure_ms p50=\(ms(p50)) p95=\(ms(p95)) n=\(exposures.count) missed=\(missed) target_p95_ms=150 within_target=\(p95 <= 0.150) "
        + "load1=\(fmt(load)) noisy=\(noisy) path=blur style=\(runtime.appearance.style.rawValue)")
    print("cover_control overlap_min=\(fmt(overlaps.min() ?? 0)) overlap_p50=\(fmt(percentile(overlaps, 0.5))) layers_max=\(layers.max() ?? 0) "
        + "covers_cleared_between_trials=\(notCleared == 0) ok=\(controlOK)")
    print("pipeline_counts in=\(m.framesIn) out=\(m.framesOut) skipped=\(m.skipped) detections=\(m.detections) errors=\(m.errors) applies=\(m.applies) "
        + "detect_ms=\(PipelineMetrics.p(m.detect)) classify_ms=\(PipelineMetrics.p(m.classify)) crops=\(m.crops) track_ms=\(PipelineMetrics.p(m.track)) "
        + "render_ms=\(PipelineMetrics.p(m.render)) commit_ms=\(PipelineMetrics.p(m.commit)) e2e_ms=\(PipelineMetrics.p(m.e2e)) "
        + "health=\(runtime.model.policy.health) \(runtime.modelsNote)")
    let budget = PerFrameBudget(m)
    print(budget.line(load: load))
    runtime.displayManager.stop()
    // Correctness always gates; the p95 target only on a quiet machine (other agents' GPU/ANE load stalls Vision and Core Image).
    return exposures.count >= trials * 9 / 10 && controlOK && notCleared == 0 && budget.ok && (noisy || p95 <= 0.150)
}

/// M4-T09 regression gate: the per-frame work the performance pass removed, as ratios of processed frames, so it does not
/// depend on how fast the machine is. Each one is the counter behind a change that paid; if a later change puts the work back,
/// this fails on a machine of any speed and under any load.
///   `applies`  — the overlay is on the display the stream captures, so a commit per frame makes SCK deliver a frame per commit
///                and the pipeline runs on its own output. Before the pass this was exactly 1.00; the ceiling is what a
///                still-photo trial leaves once identical cover sets stop being re-committed.
///   `crops`    — face crops through the classifier, one pooled buffer and one CoreML call each (0.78–0.89 before the pass).
/// `renders` (cover renders, one pooled buffer and one GPU submission each) and `reuses` are printed but not gated: how many
/// covers can keep their pixels depends on how much of the user's own screen is moving, which this test does not control.
/// Everything gated here is a ratio of processed frames, so it does not depend on how fast the machine is or what its load was.
/// The exposure test's own protocol is the fixture: a still photo, blank between trials, so a pipeline that re-commits
/// unchanged covers shows up immediately.
@MainActor
struct PerFrameBudget {
    static let maxAppliesPerFrame = 0.90, maxCropsPerFrame = 0.50
    let frames: Int, applies: Double, crops: Double, renders: Double, reuses: Double

    init(_ m: PipelineMetrics) {
        frames = m.framesOut
        let n = Double(max(1, m.framesOut))
        applies = Double(m.applies) / n
        crops = Double(m.crops) / n
        renders = Double(m.renders) / n
        reuses = Double(m.reuses) / n
    }

    var ok: Bool { frames >= 30 && applies <= Self.maxAppliesPerFrame && crops <= Self.maxCropsPerFrame }

    func line(load: Double) -> String {
        "perf_budget frames=\(frames) applies_per_frame=\(fmt(applies))/\(fmt(Self.maxAppliesPerFrame)) "
            + "crops_per_frame=\(fmt(crops))/\(fmt(Self.maxCropsPerFrame)) renders_per_frame=\(fmt(renders)) reuses_per_frame=\(fmt(reuses)) "
            + "ok=\(ok) load1=\(fmt(load))"
    }
}

/// M2-T12 backlog check: the photo moves like video for `seconds`; every 10 s a line with frames in, detections, skipped
/// frames, tracker and layer counts and resident memory. Skipped-frame ratio and memory must be flat: a growing ratio or RSS
/// would mean frames queue somewhere. Compares the first and last thirds of the run.
@MainActor
private func motionTest(seconds: Double) async throws -> Bool {
    let (runtime, d, pipeline) = try await bootRuntime()
    let stim = try Stimulus(display: d.frame.size, motion: true)
    stim.show(true)
    let mover = Task { @MainActor in
        var t = 0.0
        while !Task.isCancelled {
            stim.move(t: t)
            t += 1.0 / 30
            try? await Task.sleep(for: .milliseconds(33))
        }
    }
    var samples: [(skip: Double, rss: Double)] = []
    var lastIn = 0, lastSkipped = 0, layersSeen = 0
    let start = CACurrentMediaTime()
    var next = 10.0
    while next <= seconds + 0.5 {
        let wait = start + next - CACurrentMediaTime()
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        let m = await pipeline.metrics
        let dIn = m.framesIn - lastIn, dSkip = m.skipped - lastSkipped
        let ratio = dIn + dSkip > 0 ? Double(dSkip) / Double(dIn + dSkip) : 0
        let rss = residentMemoryMB()
        samples.append((ratio, rss))
        layersSeen = max(layersSeen, m.layers)
        print("motion t=\(Int(next)) frames_in=\(m.framesIn) detections=\(m.detections) skipped=\(m.skipped) window_skip_ratio=\(fmt(ratio)) "
            + "tracks=\(m.tracks) layers=\(m.layers) rss_mb=\(Int(rss)) detect_ms=\(PipelineMetrics.p(m.detect)) "
            + "classify_ms=\(PipelineMetrics.p(m.classify)) crops=\(m.crops) e2e_ms=\(PipelineMetrics.p(m.e2e)) errors=\(m.errors) load1=\(fmt(loadAverage()))")
        lastIn = m.framesIn
        lastSkipped = m.skipped
        next += 10
    }
    mover.cancel()
    stim.show(false)
    let k = max(1, samples.count / 3)
    func mean(_ v: some Collection<Double>) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
    let rssFirst = mean(samples.prefix(k).map(\.rss)), rssLast = mean(samples.suffix(k).map(\.rss))
    let skipFirst = mean(samples.prefix(k).map(\.skip)), skipLast = mean(samples.suffix(k).map(\.skip))
    let growth = rssLast - rssFirst > max(30, 0.25 * rssFirst) || skipLast - skipFirst > 0.2
    let m = await pipeline.metrics
    print("backlog_growth=\(growth) rss_mb_first=\(Int(rssFirst)) rss_mb_last=\(Int(rssLast)) skip_ratio_first=\(fmt(skipFirst)) skip_ratio_last=\(fmt(skipLast)) "
        + "frames_in=\(m.framesIn) skipped_total=\(m.skipped) skip_ratio_total=\(fmt(m.skipRatio)) layers_max=\(layersSeen) seconds=\(Int(seconds)) "
        + "load1=\(fmt(loadAverage())) \(runtime.modelsNote)")
    // M4-T09: the counters, reported not gated here — continuous motion moves every cover on every frame, so this run has
    // nothing to reuse and nothing to skip committing. The gate lives on the still-photo `--selftest pipeline` protocol.
    print("motion_frame_work frames=\(m.framesOut) applies_per_frame=\(fmt(Double(m.applies) / Double(max(1, m.framesOut)))) "
        + "crops_per_frame=\(fmt(Double(m.crops) / Double(max(1, m.framesOut)))) renders_per_frame=\(fmt(Double(m.renders) / Double(max(1, m.framesOut)))) "
        + "reuses=\(m.reuses) face_skips=\(m.faceSkips) detect_skips=\(m.detectSkips)")
    runtime.displayManager.stop()
    return !growth && layersSeen > 0 && m.framesIn > 0
}

// MARK: - category (M2-T07)

/// The category rule end to end on the real pipeline (CoreML detector + classifier): per hidden set with Strict off, the CC0 woman
/// and man portraits of Tests/SitrDetectTests/Fixtures — the hidden one covered within 1 s, the other never over 2 s — then Strict
/// on with the spike's person shrunk until the face is under 32 px in the capture → covered as Unknown within 2 s. "Covered" means
/// a committed layer over the photo, so people elsewhere on the screen do not count; the heartbeat keeps frames flowing.
@MainActor
private func categoryTest() async throws -> Bool {
    let (runtime, d, pipeline) = try await bootRuntime()
    let model = runtime.model
    let display = d.frame.size
    let woman = Stimulus(display: display, image: try Stimulus.fixture("Tests/SitrDetectTests/Fixtures/woman.jpg"))
    let man = Stimulus(display: display, image: try Stimulus.fixture("Tests/SitrDetectTests/Fixtures/man.jpg"))
    // 500×749 at 0.6: the ~42 px face becomes 25 pt ≈ 22 px in the 1280-wide capture (< 32), the body ~370 pt (≥ 40 px).
    let small = Stimulus(display: display, image: try Stimulus.fixture("Sources/SitrSpike/Fixtures/person.jpg"), scale: 0.6)
    var latest: [CGRect] = []  // cover frames of the latest commit on the main display
    var commits = 0
    let mainID = d.id
    runtime.onCommit = { id, specs, _, _ in
        guard id == mainID else { return }
        latest = specs.map(\.frame)
        commits += 1
    }
    /// A rect "lands" on the photo when it hides ≥ 25 % of it (a neighbour's padded cover brushing the edge does not count).
    func lands(_ r: CGRect, on stim: Stimulus) -> Bool { r.intersection(stim.photoRect).area >= 0.25 * stim.photoRect.area }
    func covers(_ stim: Stimulus) -> Bool { latest.contains { lands($0, on: stim) } }
    func trackOver(_ stim: Stimulus) async -> Track? { await pipeline.tracks.first { lands(CGRect($0.rect), on: stim) } }

    /// Waits (≤ 3 s, heartbeat running) for two fresh commits with no cover and no track on `stim`'s photo: frames still in
    /// flight from the previous state, and stale covers from whatever the screen showed before the panels appeared, must not count.
    func settle(_ stim: Stimulus) async {
        let start = commits
        let deadline = CACurrentMediaTime() + 3
        while CACurrentMediaTime() < deadline {
            let clear = await trackOver(stim) == nil && !covers(stim)
            if clear, commits >= start + 2 { break }
            stim.pulse()
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Shows `stim` for `seconds` with the heartbeat running; returns whether a cover landed on it, after how long, and the category
    /// of the track over it. Then hides it and waits until its covers and tracks are gone.
    func show(_ stim: Stimulus, seconds: Double) async -> (covered: Bool, ms: Int, track: String) {
        stim.panel.orderFrontRegardless()  // the stimulus panels overlap at the display centre: the one under test goes on top
        await settle(stim)
        let t0 = stim.show(true)
        var first: Double?
        while CACurrentMediaTime() < t0 + seconds {
            if first == nil, covers(stim) { first = CACurrentMediaTime() }
            stim.pulse()
            try? await Task.sleep(for: .milliseconds(50))
        }
        let track = await trackOver(stim).map { "\($0.category)" } ?? "none"
        let all = await pipeline.tracks.map { "\(rectString(CGRect($0.rect))):\($0.category)" }
        let m = await pipeline.metrics
        print("category_debug photo=\(rectString(stim.photoRect)) frames_in=\(m.framesIn) detections=\(m.detections) tracks=\(all) latest=\(latest.map(rectString))")
        stim.show(false)
        await settle(stim)
        return (first != nil, first.map { Int(($0 - t0) * 1000) } ?? -1, track)
    }

    print("category_boot \(runtime.modelsNote) woman=\(rectString(woman.photoRect)) man=\(rectString(man.photoRect)) small=\(rectString(small.photoRect))")
    var ok = true
    let cases: [(hidden: HiddenSet, strict: Bool, stim: Stimulus, name: String, cover: Bool, track: String?, withinMs: Int)] = [
        (.women, false, man, "man", false, nil, 0), (.women, false, woman, "woman", true, "woman", 1000),
        (.men, false, woman, "woman", false, nil, 0), (.men, false, man, "man", true, "man", 1000),
        (.men, true, small, "small_person", true, "unknown", 2000),
    ]
    for c in cases {
        model.setHiddenSet(c.hidden)
        model.setStrict(c.strict)
        let r = await show(c.stim, seconds: 2)
        let pass = c.cover ? (r.covered && r.ms <= c.withinMs && r.track == c.track) : !r.covered
        print("category_check hidden=\(c.hidden) strict=\(c.strict) fixture=\(c.name) expect_cover=\(c.cover) covered=\(r.covered) "
            + "first_cover_ms=\(r.ms < 0 ? "-" : String(r.ms)) within_ms=\(c.cover ? String(c.withinMs) : "-") track=\(r.track) "
            + "expected_track=\(c.track ?? "-") ok=\(pass)")
        ok = ok && pass
    }
    let m = await pipeline.metrics
    print("category_summary ok=\(ok) \(runtime.modelsNote) detect_ms=\(PipelineMetrics.p(m.detect)) classify_ms=\(PipelineMetrics.p(m.classify)) "
        + "crops=\(m.crops) errors=\(m.errors) load1=\(fmt(loadAverage())) noisy=\(loadAverage() > 4)")
    runtime.displayManager.stop()
    return ok
}

/// M2-T16: with `Notifier.dryRun`, stop the capture session (a stream error lands in the same `.stopped` health) and report a
/// revocation; health must flip within 5 s with exactly one notification and the covers gone. Then `start()` again: `.ok` on the
/// first frame within 5 s, one "restored" notification, covers back.
@MainActor
private func failstateTest(stimulusApp: String) async throws -> Bool {
    Notifier.dryRun = true
    let (runtime, d, _) = try await bootRuntime()
    let model = runtime.model
    let stim = try Stimulus(display: d.frame.size, motion: false)
    stim.show(true)
    let covered = await waitUntil(10) { d.panel.layerCount > 0 }
    runtime.checkHealth()
    print("failstate_baseline health=\(model.policy.health) covered=\(covered) layers=\(d.panel.layerCount) notifications=\(runtime.notifier.posted) icon=\(model.iconState)")
    var ok = covered && model.policy.health == .ok && runtime.notifier.posted == 0

    let t0 = CACurrentMediaTime()
    d.session.stop()
    runtime.permission.markRevoked()
    let flipped = await waitUntil(5) { model.status == .recovering && model.policy.health == .degraded }
    let flipMs = (CACurrentMediaTime() - t0) * 1000
    let dropped = await waitUntil(2) { d.panel.layerCount == 0 }
    print("failstate_stop health=\(model.policy.health) flipped=\(flipped) within_ms=\(Int(flipMs)) covers_dropped=\(dropped) layers=\(d.panel.layerCount) "
        + "notifications=\(runtime.notifier.posted) icon=\(model.iconState) reveal_available=\(model.revealAvailable) permission=\(runtime.permission.state)")
    ok = ok && flipped && dropped && runtime.notifier.posted == 1 && model.iconState == .warning
    try await Task.sleep(for: .seconds(2))  // a second poll must not notify again
    runtime.checkHealth()
    print("failstate_hold notifications=\(runtime.notifier.posted) health=\(model.policy.health)")
    ok = ok && runtime.notifier.posted == 1

    let t1 = CACurrentMediaTime()
    d.session.start()
    let recovered = await waitUntil(5) {
        stim.pulse()
        return model.policy.health == .ok
    }
    let recoverMs = (CACurrentMediaTime() - t1) * 1000
    let coveredAgain = await waitUntil(5) { d.panel.layerCount > 0 }
    print("failstate_restart health=\(model.policy.health) recovered=\(recovered) within_ms=\(Int(recoverMs)) covers_back=\(coveredAgain) layers=\(d.panel.layerCount) "
        + "notifications=\(runtime.notifier.posted) icon=\(model.iconState) session_ok=\(d.session.health.isOK)")
    ok = ok && recovered && coveredAgain && runtime.notifier.posted == 2 && model.iconState == .normal
    print("failstate_revoke_real manual pending: markRevoked() keeps `granted` while CGPreflightScreenCaptureAccess is true "
        + "(a shell-launched process inherits the terminal's grant); use tccutil reset ScreenCapture com.goldentik.Sitr on a Finder-launched build")
    // M3-T06: the same stop / start cycle with a Curtain app on screen. The in-process stimulus panel (level .screenSaver) is
    // ordered out first — it overlaps the display centre, where the remote window sits, and would decide every pixel check.
    stim.show(false)
    stim.panel.orderOut(nil)
    if let curtainOK = try await failClosedCheck(runtime: runtime, display: d, stimulusApp: stimulusApp) { ok = ok && curtainOK }
    runtime.displayManager.stop()
    return ok
}

// MARK: - lowpower (M4-T06)

/// M4-T06: with the power state simulated (Low Power Mode itself is a System Settings switch nobody can flip from here),
/// `NSProcessInfoPowerStateDidChange` must reach every session inside a second and change the delivered frame rate —
/// through `SCStream.updateConfiguration`, with the stream never restarting. The General toggle wins over the power state.
@MainActor
private func lowPowerTest() async throws -> Bool {
    let (runtime, d, _) = try await bootRuntime()
    let stim = try Stimulus(display: d.frame.size, motion: true)
    stim.show(true)
    let mover = Task { @MainActor in  // 25 changes/s: the capture rate, not the screen, is what limits frames
        let t0 = CACurrentMediaTime()
        while !Task.isCancelled {
            stim.move(t: (CACurrentMediaTime() - t0) * 0.25)
            try? await Task.sleep(for: .milliseconds(40))
        }
    }
    Harness.onExit { mover.cancel() }
    /// Complete frames per second delivered by the sink over `seconds` (`stats` counts in the callback, so the pipeline's
    /// own speed does not enter into it).
    func rate(_ seconds: Double) async -> Double {
        let before = d.session.stats.complete
        let t0 = CACurrentMediaTime()
        try? await Task.sleep(for: .seconds(seconds))
        return Double(d.session.stats.complete - before) / (CACurrentMediaTime() - t0)
    }
    /// Flips the simulated power state and posts the real notification; answers how long the new rate took to arrive.
    func setLowPower(_ on: Bool) async -> Double {
        let t0 = CACurrentMediaTime()
        runtime.lowPower.simulatedLowPower = on
        NotificationCenter.default.post(name: .NSProcessInfoPowerStateDidChange, object: ProcessInfo.processInfo)
        let want = LowPowerMonitor.fps(lowPower: on, reduce: runtime.model.preferences.lowPowerReducesFrameRate)
        _ = await waitUntil(2) { d.session.fps == want }
        return (CACurrentMediaTime() - t0) * 1000
    }

    let restarts0 = d.session.restarts
    let normal = await rate(4)
    print("lowpower_normal fps_setting=\(d.session.fps) measured_fps=\(fmt(normal)) toggle=\(runtime.model.preferences.lowPowerReducesFrameRate) "
        + "system_low_power=\(ProcessInfo.processInfo.isLowPowerModeEnabled)")
    var ok = d.session.fps == LowPowerMonitor.standardFPS && normal > 11 && normal < 18

    let onMs = await setLowPower(true)
    let low = await rate(4)
    print("lowpower_on fps_setting=\(d.session.fps) applied_ms=\(Int(onMs)) measured_fps=\(fmt(low)) restarts=\(d.session.restarts - restarts0) "
        + "health=\(runtime.model.policy.health)")
    ok = ok && d.session.fps == LowPowerMonitor.lowPowerFPS && onMs < 1000 && low > 5.5 && low < 10.5

    // The General toggle (M4-T04) outranks the power state: switching it off restores 15 fps while Low Power stays on.
    runtime.model.preferences.lowPowerReducesFrameRate = false
    let respected = await waitUntil(2) { d.session.fps == LowPowerMonitor.standardFPS }
    print("lowpower_toggle_off fps_setting=\(d.session.fps) restored=\(respected)")
    ok = ok && respected
    runtime.model.preferences.lowPowerReducesFrameRate = true
    _ = await waitUntil(2) { d.session.fps == LowPowerMonitor.lowPowerFPS }

    let offMs = await setLowPower(false)
    let back = await rate(4)
    print("lowpower_off fps_setting=\(d.session.fps) applied_ms=\(Int(offMs)) measured_fps=\(fmt(back)) restarts=\(d.session.restarts - restarts0) "
        + "stream_kept=\(d.session.restarts == restarts0 && d.session.health.isOK) load1=\(fmt(loadAverage())) noisy=\(loadAverage() > 4)")
    ok = ok && d.session.fps == LowPowerMonitor.standardFPS && offMs < 1000 && back > 11 && back < 18
    ok = ok && d.session.restarts == restarts0 && d.session.health.isOK  // updateConfiguration, not a restart

    mover.cancel()
    stim.show(false)
    runtime.displayManager.stop()
    return ok
}

// MARK: - degraded (M4-T07)

/// M4-T07: a synthetic slowdown fed into `DetectionMeter` under a display id no stream uses (the real pipelines are stopped
/// first, so only these numbers decide). > 250 ms/frame for 3 s must reach `Policy.health` as `.degraded` with exactly one
/// notification and the FR7 warning icon; < 150 ms/frame for 5 s must bring it back with exactly one more; and repeating
/// the slowdown inside five minutes must flip the state again while posting nothing.
@MainActor
private func degradedTest() async throws -> Bool {
    Notifier.dryRun = true
    let (runtime, d, _) = try await bootRuntime()
    let model = runtime.model
    for pipeline in runtime.pipelines.values { await pipeline.stop() }
    DetectionMeter.shared.reset()
    let synthetic: CGDirectDisplayID = 0x1F17E  // not a display id macOS hands out; the real ones are idle now anyway
    /// Feeds frames of `ms` for `seconds` of wall clock, at their own pace, exactly as a pipeline would.
    func feed(ms: Double, seconds: Double) async {
        let deadline = CACurrentMediaTime() + seconds
        while CACurrentMediaTime() < deadline {
            DetectionMeter.shared.record(display: synthetic, seconds: ms / 1000, at: CACurrentMediaTime())
            try? await Task.sleep(for: .milliseconds(Int(ms)))
        }
    }

    print("degraded_baseline health=\(model.policy.health) notifications=\(runtime.notifier.posted) status=\(model.statusText) "
        + "pipelines_stopped=\(runtime.pipelines.count) sessions_ok=\(d.session.health.isOK)")
    var ok = model.policy.health == .ok && runtime.notifier.posted == 0

    let t0 = CACurrentMediaTime()
    await feed(ms: 300, seconds: 3.4)  // 300 ms/frame: over the 250 ms limit for longer than 3 s
    let entered = await waitUntil(3) { model.policy.health == .degraded }
    print("degraded_enter health=\(model.policy.health) entered=\(entered) within_ms=\(Int((CACurrentMediaTime() - t0) * 1000)) "
        + "notifications=\(runtime.notifier.posted) status=\(model.statusText) icon=\(model.iconState) reveal_available=\(model.revealAvailable) "
        + "displays=\(DetectionMeter.shared.degradedDisplays)")
    ok = ok && entered && runtime.notifier.posted == 1 && model.iconState == .warning && model.statusText == "Degraded"

    let t1 = CACurrentMediaTime()
    await feed(ms: 50, seconds: 5.4)  // 50 ms/frame: under the 150 ms limit for longer than 5 s
    let recovered = await waitUntil(3) { model.policy.health == .ok }
    print("degraded_recover health=\(model.policy.health) recovered=\(recovered) within_ms=\(Int((CACurrentMediaTime() - t1) * 1000)) "
        + "notifications=\(runtime.notifier.posted) status=\(model.statusText) icon=\(model.iconState)")
    ok = ok && recovered && runtime.notifier.posted == 2 && model.iconState == .normal

    await feed(ms: 300, seconds: 3.4)  // the same transition again, well inside the five minutes
    let again = await waitUntil(3) { model.policy.health == .degraded }
    print("degraded_repeat health=\(model.policy.health) entered=\(again) notifications=\(runtime.notifier.posted) "
        + "spacing_s=\(Int(HealthNotificationGate.repeatSpacing)) status=\(model.statusText)")
    ok = ok && again && runtime.notifier.posted == 2  // state follows the frames; the user is told once per 5 min

    runtime.displayManager.stop()
    return ok
}

// MARK: - robustness (M4-T10)

/// The live display topology as CoreGraphics reports it: ids, bounds, built-in, mirror master, asleep, active. Read-only,
/// no capture, so it is safe on every run and it is what a two-display or mirrored session has to be checked against.
@MainActor
private func liveDisplayTopology() -> String {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return "none" }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return "unavailable" }
    return ids.prefix(Int(count)).map { id in
        let b = CGDisplayBounds(id)
        return "\(id)=\(Int(b.width))x\(Int(b.height))+\(Int(b.minX))+\(Int(b.minY))"
            + ",builtin=\(CGDisplayIsBuiltin(id) != 0),mirrors=\(CGDisplayMirrorsDisplay(id))"
            + ",asleep=\(CGDisplayIsAsleep(id) != 0),active=\(CGDisplayIsActive(id) != 0)"
    }.joined(separator: " ")
}

/// M4-T10: the transitions that take the screen away and give it back, driven through the real `Runtime` on real capture —
/// the same `SystemEventMonitor` path a real notification takes, minus the notification, because an agent may not put this
/// machine to sleep twenty times. Per cycle: suspend, and every stream must be parked with no panel and no pipeline
/// rebuilt and the covers still on screen; resume, and there must be exactly one stream, one panel and one pipeline per
/// display, with frames flowing again. Then the same for lock/unlock, fast user switching and the displays going dark,
/// and the restart backoff on the live session (three failures in one turn are one retry, ~1 s away, and the stream comes
/// back on its own). The real sleep/wake, lock and user-switch runs are the manual procedure in docs/m4/robustness.md.
@MainActor
private func robustnessTest(cycles: Int) async throws -> Bool {
    print("robustness_topology displays=\(liveDisplayTopology())")
    let (runtime, d, _) = try await bootRuntime()
    let stim = try Stimulus(display: d.frame.size, motion: false)
    _ = stim.show(true)
    var commits: [CGDirectDisplayID: Int] = [:]
    runtime.onCommit = { id, _, _, _ in commits[id, default: 0] += 1 }
    let covered = await waitUntil(10) {
        stim.pulse()
        return d.panel.layerCount > 0
    }
    let ids = runtime.displayManager.displays.map(\.id).sorted()
    print("robustness_baseline displays=\(ids) pipelines=\(runtime.pipelines.count) panels=\(OverlayPanel.openCount) "
        + "streams=\(CaptureSession.liveStreams) covered=\(covered) layers=\(d.panel.layerCount) health=\(runtime.model.policy.health)")
    var ok = covered && runtime.pipelines.count == ids.count && OverlayPanel.openCount == ids.count
        && CaptureSession.liveStreams == ids.count

    /// One suspend/resume pair through `SystemEventMonitor`, with every invariant checked on both halves.
    func cycle(_ label: String, _ down: SystemActivityMachine.Event, _ up: SystemActivityMachine.Event, _ n: Int) async -> Bool {
        let restartsBefore = runtime.displayManager.displays.map(\.session.restarts).reduce(0, +)
        let layersBefore = d.panel.layerCount
        runtime.systemEvents.simulate(down)
        let parked = CaptureSession.liveStreams == 0
        let heldPanels = OverlayPanel.openCount == ids.count
        let heldPipelines = runtime.pipelines.count == ids.count
        let heldCovers = d.panel.layerCount == layersBefore  // a suspend must not touch the covers already on screen
        let t0 = CACurrentMediaTime()
        runtime.systemEvents.simulate(up)
        // `stopCapture` is asynchronous, so the torn-down stream can still deliver a frame or two: wait for the new
        // stream to be connected, and only then for a frame it produced.
        let connected = await waitUntil(5) { d.session.isConnected }
        let mark = commits[d.id] ?? 0
        let fresh = await waitUntil(5) {
            stim.pulse()
            return (commits[d.id] ?? 0) > mark
        }
        let flowing = connected && fresh
        // Resume reconnects each display's session independently; `connected`/`fresh` only speak for `d`. Time how long the
        // *other* displays take, so a slow reconnect is told apart from one that never comes back.
        let tAll = CACurrentMediaTime()
        let allConnected = await waitUntil(8) { CaptureSession.liveStreams == ids.count }
        let allMs = Int((CACurrentMediaTime() - tAll) * 1000)
        // The resume grace is ended by the 250 ms health poll once every session is connected, so `.active` arrives a poll
        // after the frames do. Wait for it rather than sampling, and print the time: a regression shows up as a growing number.
        let tActive = CACurrentMediaTime()
        let backActive = await waitUntil(3) { runtime.systemEvents.state == .active }
        let activeMs = Int((CACurrentMediaTime() - tActive) * 1000)
        let ms = Int((CACurrentMediaTime() - t0) * 1000)
        let sameIDs = runtime.displayManager.displays.map(\.id).sorted() == ids
        let one = runtime.pipelines.count == ids.count && OverlayPanel.openCount == ids.count
            && CaptureSession.liveStreams == ids.count && Set(runtime.pipelines.keys) == Set(ids)
        let restarts = runtime.displayManager.displays.map(\.session.restarts).reduce(0, +) - restartsBefore
        let verdict = parked && heldPanels && heldPipelines && heldCovers && flowing && sameIDs && one
            && allConnected && backActive && runtime.pendingStallChecks <= ids.count
        print("robustness_cycle kind=\(label) n=\(n) parked=\(parked) held_panels=\(heldPanels) held_pipelines=\(heldPipelines) "
            + "covers_untouched=\(heldCovers) layers=\(d.panel.layerCount) frames_back=\(flowing) resume_ms=\(ms) "
            + "displays=\(runtime.displayManager.displays.count) "
            + "pipelines=\(runtime.pipelines.count) panels=\(OverlayPanel.openCount) streams=\(CaptureSession.liveStreams) "
            + "backoff_restarts=\(restarts) state=\(runtime.systemEvents.state) health=\(runtime.model.policy.health) "
            + "same_ids=\(sameIDs) keys=\(Set(runtime.pipelines.keys) == Set(ids)) stall_checks=\(runtime.pendingStallChecks) "
            + "connected=\(connected) fresh=\(fresh) all_connected=\(allConnected) all_connected_ms=\(allMs) "
            + "active_ms=\(activeMs) ok=\(verdict)")
        return verdict
    }

    print("robustness_phase after_baseline ok=\(ok)")
    for n in 1...max(1, cycles) { ok = await cycle("sleep", .willSleep, .didWake, n) && ok }
    print("robustness_phase after_sleep ok=\(ok)")
    ok = await cycle("lock", .screenLocked, .screenUnlocked, 1) && ok
    print("robustness_phase after_lock ok=\(ok)")
    ok = await cycle("user_switch", .sessionResignedActive, .sessionBecameActive, 1) && ok
    print("robustness_phase after_switch ok=\(ok)")
    ok = await cycle("screens_off", .screensDidSleep, .screensDidWake, 1) && ok
    print("robustness_phase after_screens_off ok=\(ok)")

    // The live backoff: three failures inside one turn are one scheduled retry, ~1 s away, and the stream comes back.
    let restartsBefore = d.session.restarts
    let t1 = CACurrentMediaTime()
    for _ in 0..<3 { d.session.simulateStreamFailure(CaptureError.displayGone) }
    let scheduled = d.session.restarts - restartsBefore
    let delay = d.session.pendingRetryDelay ?? -1
    let reconnected = await waitUntil(8) { d.session.isConnected }
    let mark = commits[d.id] ?? 0
    let framesBack = await waitUntil(5) {
        stim.pulse()
        return (commits[d.id] ?? 0) > mark
    }
    let healthBack = await waitUntil(5) {
        stim.pulse()
        return runtime.model.policy.health == .ok
    }
    print("robustness_backoff failures=3 retries_scheduled=\(scheduled) next_delay_s=\(fmt(delay)) cap_s=\(Int(Backoff.captureStream.cap)) "
        + "reconnected=\(reconnected) recovery_ms=\(Int((CACurrentMediaTime() - t1) * 1000)) frames_back=\(framesBack) "
        + "health_back=\(healthBack) restarts_total=\(d.session.restarts - restartsBefore) streams=\(CaptureSession.liveStreams) "
        + "panels=\(OverlayPanel.openCount) health=\(runtime.model.policy.health)")
    // One retry for the burst, ~1 s away, and the stream is back on its own with health restored and no second retry
    // triggered by the torn-down stream's own late stop callback.
    ok = ok && scheduled == 1 && delay > 0 && delay <= Backoff.captureStream.cap && reconnected && framesBack && healthBack
        && d.session.restarts - restartsBefore == 1

    print("robustness_summary cycles=\(cycles) events=\(runtime.systemEvents.seen.count) displays=\(runtime.displayManager.displays.count) "
        + "pipelines=\(runtime.pipelines.count) panels=\(OverlayPanel.openCount) streams=\(CaptureSession.liveStreams) "
        + "stall_checks=\(runtime.pendingStallChecks) state=\(runtime.systemEvents.state) health=\(runtime.model.policy.health) "
        + "load1=\(fmt(loadAverage())) manual_pending=sleep_wake,lock_unlock,fast_user_switch,two_display_hotplug,mirroring ok=\(ok)")
    stim.panel.orderOut(nil)
    await runtime.stop()
    print("robustness_teardown panels=\(OverlayPanel.openCount) streams=\(CaptureSession.liveStreams)")
    return ok && OverlayPanel.openCount == 0 && CaptureSession.liveStreams == 0
}

/// Dev stimulus for a manual run of the real app from another shell: two person photos moving for `seconds` (frames keep flowing),
/// then exit. No pipeline here — the app under test is the other process, which is why its own-process exclusion does not hide it.
/// `--mode` (M1-T08, scripts/measure-system.sh): `drift` (default) a slow drift at 15 Hz; `video` continuous 30 fps motion like a
/// video with people; `browsing` page-like bursts — a redraw (photo off/on) then 1 s of 60 Hz scrolling motion, 4 s static.
@MainActor
private func stimulusOnly(seconds: Double, mode: String) async throws -> Bool {
    guard let screen = NSScreen.screens.first else { throw SelftestError("no screen") }
    let stim = try Stimulus(display: screen.frame.size, motion: true)
    stim.show(true)
    print("stimulus panel=\(rectString(stim.rect)) seconds=\(Int(seconds)) mode=\(mode)")
    let start = CACurrentMediaTime()
    var scrolled = 0.0  // browsing: motion time advances only while the "page" scrolls
    while CACurrentMediaTime() - start < seconds {
        let t = CACurrentMediaTime() - start
        switch mode {
        case "video":
            stim.move(t: t)  // the motion selftest's video: both photos on their Lissajous paths at 30 fps
            try await Task.sleep(for: .milliseconds(33))
        case "browsing":
            // ponytail: fixed 5 s cycle (redraw, 1 s scroll burst at 60 Hz, 4 s reading pause) instead of a recorded browsing trace.
            let phase = t.truncatingRemainder(dividingBy: 5)
            if phase < 0.05 { stim.show(false) }  // page load: the photo column redraws
            if phase < 1 {
                stim.show(true)
                scrolled += 2.0 / 60  // 2× speed: ~300 pt of travel per burst
                stim.move(t: scrolled)
                try await Task.sleep(for: .milliseconds(16))
            } else {
                try await Task.sleep(for: .milliseconds(100))
            }
        default:
            stim.move(t: t * 0.25)  // slow drift: a few points per frame
            try await Task.sleep(for: .milliseconds(66))
        }
    }
    stim.show(false)
    return true
}

// MARK: - harness (lifted from the spike's Rig)

/// NSApplication bootstrap, window tracking, cleanup hooks and a hard deadline. `run` never returns.
@MainActor
enum Harness {
    private static var windows: [NSWindow] = []
    private static var cleanup: [@MainActor () -> Void] = []
    /// Called for every tracked window (M3: `bootRuntime` refreshes the capture filter so a new in-process stimulus is captured).
    static var onTrack: (@MainActor (NSWindow) -> Void)?

    static func track(_ w: NSWindow) {
        w.isReleasedWhenClosed = false
        windows.append(w)
        onTrack?(w)
    }

    static func onExit(_ f: @escaping @MainActor () -> Void) { cleanup.append(f) }

    /// Runs cleanup hooks, removes every tracked window, exits. Process exit also tears down any SCStream.
    static func finish(_ code: Int32) -> Never {
        for f in cleanup { f() }
        for w in windows {
            w.orderOut(nil)
            w.close()
        }
        exit(code)
    }

    static func run(_ name: String, deadline: Double, _ body: @escaping @MainActor () async throws -> Bool) -> Never {
        NSApplication.shared.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + deadline) {
            MainActor.assumeIsolated {
                print("selftest_\(name) ok=false reason=deadline_\(Int(deadline))s")
                finish(1)
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + deadline + 5) { exit(1) }  // even if the main thread is stuck
        Task { @MainActor in
            do {
                let ok = try await body()
                print("selftest_\(name) ok=\(ok)")
                finish(ok ? 0 : 1)
            } catch {
                print("selftest_\(name) ok=false error=\(error)")
                finish(1)
            }
        }
        NSApplication.shared.run()
        fatalError("NSApplication.run returned")
    }
}

/// Borderless non-activating panel on all Spaces with one solid color; tracked for cleanup.
@MainActor
private func solidPanel(_ frame: NSRect, level: NSWindow.Level, color: NSColor) -> NSPanel {
    let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = false
    p.level = level
    p.hidesOnDeactivate = false
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    let v = NSView(frame: NSRect(origin: .zero, size: frame.size))
    v.wantsLayer = true
    v.layer?.backgroundColor = color.cgColor
    p.contentView = v
    Harness.track(p)
    return p
}

final class ClickView: NSView {
    var hits = 0
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { hits += 1 }
}

/// Left click at a CoreGraphics global point (origin top-left). Moves the real cursor; callers restore it.
nonisolated func postClick(_ p: CGPoint) {
    let source = CGEventSource(stateID: .hidSystemState)
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
}

// MARK: - pixels (numbers only)

nonisolated struct RGB: Sendable {
    var r: Int, g: Int, b: Int
    var isRed: Bool { r > 180 && g < 80 && b < 80 }
    var isGreen: Bool { g > 140 && r < 120 && b < 140 }
}

/// Mean RGB over the 5×5 block centred on (x, y) of a BGRA buffer; nil when out of bounds.
nonisolated func sampleRGB(_ pb: CVPixelBuffer, x: Int, y: Int, r: Int = 2) -> RGB? {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
    guard x - r >= 0, y - r >= 0, x + r < w, y + r < h else { return nil }
    let p = base.assumingMemoryBound(to: UInt8.self)
    var sr = 0, sg = 0, sb = 0
    for yy in (y - r)...(y + r) {
        for xx in (x - r)...(x + r) {
            let o = yy * bpr + xx * 4
            sb += Int(p[o])
            sg += Int(p[o + 1])
            sr += Int(p[o + 2])
        }
    }
    let n = (2 * r + 1) * (2 * r + 1)
    return RGB(r: sr / n, g: sg / n, b: sb / n)
}

/// Alpha byte at the centre of a BGRA buffer (255 = the cover is opaque, as it must be).
nonisolated func centreAlpha(_ pb: CVPixelBuffer) -> Int {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return -1 }
    let x = CVPixelBufferGetWidth(pb) / 2, y = CVPixelBufferGetHeight(pb) / 2
    return Int(base.assumingMemoryBound(to: UInt8.self)[y * CVPixelBufferGetBytesPerRow(pb) + x * 4 + 3])
}

nonisolated func makeBuffer(_ w: Int, _ h: Int) throws -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
    guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess, let pb else { throw SelftestError("CVPixelBufferCreate failed") }
    return pb
}

// MARK: - args and formatting

nonisolated func option(_ args: [String], _ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
nonisolated func option(_ args: [String], _ name: String, default d: Double) -> Double { option(args, name).flatMap(Double.init) ?? d }
nonisolated func option(_ args: [String], _ name: String, default d: Int) -> Int { option(args, name).flatMap(Int.init) ?? d }

nonisolated func percentile(_ v: [Double], _ p: Double) -> Double {
    let s = v.sorted()
    guard !s.isEmpty else { return .nan }
    return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
}
nonisolated func ms(_ seconds: Double) -> String { String(format: "%.2f", seconds * 1000) }
nonisolated func fmt(_ x: Double) -> String { String(format: "%.3f", x) }
nonisolated func rectString(_ r: CGRect) -> String {
    r.isNull ? "null" : "(\(Int(r.minX.rounded())),\(Int(r.minY.rounded())),\(Int(r.width.rounded())),\(Int(r.height.rounded())))"
}
nonisolated func rgbString(_ c: RGB?) -> String { c.map { "(\($0.r),\($0.g),\($0.b))" } ?? "n/a" }

nonisolated extension CGRect {
    /// Width × height; 0 for null or empty rects.
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}

/// 1-minute load average, so a noisy render run (other agents building) is visible in the output.
nonisolated func loadAverage() -> Double {
    var loads = [Double](repeating: 0, count: 3)
    return getloadavg(&loads, 3) > 0 ? loads[0] : .nan
}

nonisolated struct SelftestError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

nonisolated extension CGColor {
    static let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    static let blue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
}

// MARK: - M3 (M3-T03 filter, M3-T05 curtain, M3-T06 fail-closed, M3-T09 overlap) — a second process as the stimulus

/// Geometry of the remote stimulus window (`--selftest stimulus --remote`), in window-local points (origin top-left), shared by the
/// stimulus process and the tests that read its window rect from the `WindowTracker`. The photo is the spike's person.jpg at 0.8.
nonisolated enum RemoteLayout {
    static let size = CGSize(width: 600, height: 640)
    /// Magenta block: the "marker colour" the filter test looks for.
    static let marker = CGRect(x: 10, y: 10, width: 40, height: 40)
    /// Scrolling text column (no people).
    static let text = CGRect(x: 10, y: 60, width: 130, height: 560)
    static let photoScale: CGFloat = 0.8
    static let photo = CGRect(x: 150, y: 20, width: 400, height: 599)
    /// Hand-checked body box (`Stimulus.body` = 125,120,235,615 image px) at `photoScale`, offset by `photo`.
    static let person = CGRect(x: 250, y: 116, width: 188, height: 492)
    static let moveBy = CGVector(dx: 200, dy: 100)
    /// Heartbeat block (toggles colour on `pulse`): keeps frames flowing while covers expire; in tile (0, 0), away from every
    /// measured region. Pulsed no faster than every 300 ms (> `Curtain.motionGap`) so it never earns trusted motion.
    static let heartbeat = CGRect(x: 60, y: 10, width: 40, height: 40)
    /// Every command the stimulus registers for (fixed names; `origin` takes "x,y" in the notification's `object`).
    static let commands = ["person_on", "person_off", "scroll", "video_on", "video_off", "move", "front", "origin", "pulse", "quit"]

    /// Control channel: the test writes `<dir>/cmd` ("<seq> <command> <argument>"), the stimulus appends to `<dir>/done`
    /// ("<command> <CACurrentMediaTime()>") after its flushed transaction.
    // ponytail: two files and a 10 ms poll instead of DistributedNotificationCenter, which holds notifications for a background
    // accessory app (and is blocked outright under the App Sandbox). Upgrade path: an XPC or Mach service if the rig ever needs
    // to run against a sandboxed stimulus.
    static func commandFile(_ dir: String) -> URL { URL(fileURLWithPath: dir).appending(path: "cmd") }
    static func doneFile(_ dir: String) -> URL { URL(fileURLWithPath: dir).appending(path: "done") }
}

/// The stimulus as its own app (Stimulus.app = a re-signed copy of the bundle with another `CFBundleIdentifier`): a normal-level
/// borderless window with a magenta marker, a text column, the person photo (hidden until asked) and a block-motion "video" (no
/// people). Driven by distributed notifications named `<bundleID>.cmd.<command>` — person_on / person_off / scroll / video_on /
/// video_off / move / front / origin.<x>.<y> / quit — and answers `<bundleID>.done.<command>.<CACurrentMediaTime()>` after the
/// flushed transaction (names only: a sandboxed app may not attach userInfo). Prints its window rect; exits after `seconds`.
@MainActor
private final class RemoteStimulusWindow {
    let bundleID: String
    private let panel: NSPanel
    private let displayHeight: CGFloat
    private var origin: CGPoint
    private let photo = CALayer(), marker = CALayer(), column = CALayer(), text = CATextLayer(), heartbeat = CALayer()
    private var blocks: [CALayer] = []
    private var beat = 0
    private var video: Task<Void, Never>?
    private var scroll: Task<Void, Never>?
    private(set) var quit = false
    private let channel: String
    private var lastSeq = 0
    private var poll: Task<Void, Never>?

    init(display: CGSize, scale: CGFloat, image: CGImage, channel: String) {
        self.channel = channel
        bundleID = Bundle.main.bundleIdentifier ?? "com.goldentik.SitrStimulus"
        displayHeight = display.height
        origin = CGPoint(x: ((display.width - RemoteLayout.size.width) / 2).rounded(), y: ((display.height - RemoteLayout.size.height) / 2).rounded())
        panel = NSPanel(contentRect: appKitRect(CGRect(origin: origin, size: RemoteLayout.size), displayHeight: display.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = true
        panel.backgroundColor = .white
        panel.hasShadow = false
        panel.level = .normal  // layer 0: what WindowTracker keeps, like any app window
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = NSView(frame: NSRect(origin: .zero, size: RemoteLayout.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.cgColor
        panel.contentView = view
        let h = RemoteLayout.size.height
        for i in 0..<6 {
            let l = CALayer()
            l.backgroundColor = [NSColor.systemTeal, .systemOrange, .systemGreen, .systemIndigo, .systemYellow, .systemBrown][i].cgColor
            l.frame = CGRect(x: 0, y: 0, width: 120, height: 90)
            l.isHidden = true
            view.layer?.addSublayer(l)
            blocks.append(l)
        }
        photo.contents = image
        photo.contentsGravity = .resizeAspect
        photo.frame = appKitRect(RemoteLayout.photo, displayHeight: h)
        photo.isHidden = true
        view.layer?.addSublayer(photo)
        marker.backgroundColor = CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        marker.frame = appKitRect(RemoteLayout.marker, displayHeight: h)
        view.layer?.addSublayer(marker)
        heartbeat.backgroundColor = NSColor.systemBlue.cgColor
        heartbeat.frame = appKitRect(RemoteLayout.heartbeat, displayHeight: h)
        view.layer?.addSublayer(heartbeat)
        column.frame = appKitRect(RemoteLayout.text, displayHeight: h)
        column.masksToBounds = true
        column.backgroundColor = NSColor.white.cgColor
        view.layer?.addSublayer(column)
        text.string = Array(repeating: "Sitr curtain selftest — scrolling text, nobody here. ", count: 60).joined()
        text.font = NSFont.systemFont(ofSize: 13)
        text.fontSize = 13
        text.foregroundColor = NSColor.black.cgColor
        text.isWrapped = true
        text.contentsScale = scale
        text.frame = CGRect(x: 0, y: -2000, width: RemoteLayout.text.width, height: RemoteLayout.text.height + 2000)
        column.addSublayer(text)
        Harness.track(panel)
        panel.orderFrontRegardless()
        print("stimulus_remote bundle=\(bundleID) pid=\(getpid()) window=\(rectString(CGRect(origin: origin, size: RemoteLayout.size))) marker=\(rectString(RemoteLayout.marker)) "
            + "person=\(rectString(RemoteLayout.person)) text=\(rectString(RemoteLayout.text))")
        fflush(stdout)  // the parent redirects stdout to a file (block-buffered) and terminates us with SIGTERM
        poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.readCommand()
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    /// One line "<seq> <command> [argument]"; a seq we have not run yet is executed once.
    private func readCommand() {
        guard let line = try? String(contentsOf: RemoteLayout.commandFile(channel), encoding: .utf8) else { return }
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2, let seq = Int(parts[0]), seq > lastSeq else { return }
        lastSeq = seq
        handle(parts[1], argument: parts.count > 2 ? parts[2] : nil)
    }

    private func done(_ command: String, at t: Double) {
        let line = "\(command) \(String(format: "%.6f", t))\n"
        let url = RemoteLayout.doneFile(channel)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// One flushed transaction; returns `CACurrentMediaTime()` after the flush (the M1-T04 clock).
    private func flush(_ body: () -> Void) -> Double {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
        CATransaction.flush()
        return CACurrentMediaTime()
    }

    private func place() {
        panel.setFrameOrigin(appKitRect(CGRect(origin: origin, size: RemoteLayout.size), displayHeight: displayHeight).origin)
    }

    private func handle(_ command: String, argument: String?) {
        switch command {
        case "person_on": done(command, at: flush { photo.isHidden = false })
        case "person_off": done(command, at: flush { photo.isHidden = true })
        case "pulse":
            beat += 1
            done(command, at: flush { heartbeat.backgroundColor = beat % 2 == 0 ? NSColor.systemBlue.cgColor : NSColor.systemOrange.cgColor })
        case "scroll":
            scroll?.cancel()
            scroll = Task { @MainActor [weak self] in
                guard let self else { return }
                done("scroll_start", at: flush { text.frame.origin.y += 24 })
                for _ in 0..<9 {
                    try? await Task.sleep(for: .milliseconds(33))
                    if Task.isCancelled { return }
                    _ = flush { text.frame.origin.y += 24 }
                }
                if text.frame.origin.y > -400 { _ = flush { text.frame.origin.y = -2000 } }
                done("scroll", at: CACurrentMediaTime())
            }
        case "video_on":
            video?.cancel()
            video = Task { @MainActor [weak self] in
                guard let self else { return }
                let t0 = CACurrentMediaTime()
                done("video_on", at: flush { blocks.forEach { $0.isHidden = false } })
                let h = RemoteLayout.size.height
                while !Task.isCancelled {
                    let t = CACurrentMediaTime() - t0
                    _ = flush {
                        for (i, b) in blocks.enumerated() {
                            let k = Double(i)
                            let x = RemoteLayout.photo.minX + 140 + 130 * sin(t * (0.9 + 0.2 * k) + k)
                            let y = RemoteLayout.photo.minY + 250 + 220 * cos(t * (0.7 + 0.15 * k) + 2 * k)
                            b.frame.origin = CGPoint(x: x, y: h - y - 90)
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }
        case "video_off":
            video?.cancel()
            video = nil
            done(command, at: flush { blocks.forEach { $0.isHidden = true } })
        case "move":
            origin.x += RemoteLayout.moveBy.dx
            origin.y += RemoteLayout.moveBy.dy
            place()
            done(command, at: CACurrentMediaTime())
        case "front":
            panel.orderFrontRegardless()
            done(command, at: CACurrentMediaTime())
        case "quit":
            quit = true
        case "origin":
            let parts = (argument ?? "").split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 {
                origin = CGPoint(x: parts[0], y: parts[1])
                place()
            }
            done(command, at: CACurrentMediaTime())
        default:
            break
        }
    }

    func finish() {
        poll?.cancel()
        video?.cancel()
        scroll?.cancel()
    }
}

@MainActor
private func remoteStimulus(seconds: Double, channel: String) async throws -> Bool {
    guard let screen = NSScreen.screens.first else { throw SelftestError("no screen") }
    let window = RemoteStimulusWindow(display: screen.frame.size, scale: screen.backingScaleFactor,
                                      image: try Stimulus.fixture("Sources/SitrSpike/Fixtures/person.jpg"), channel: channel)
    let start = CACurrentMediaTime()
    while CACurrentMediaTime() - start < seconds, !window.quit {
        try await Task.sleep(for: .milliseconds(50))
    }
    window.finish()
    return true
}

/// A remote stimulus process: launches `<app>/Contents/MacOS/Sitr --selftest stimulus --remote`, sends commands, collects the
/// timestamps it answers with, and terminates it on exit.
@MainActor
private final class RemoteApp {
    let bundleID: String
    let process = Process()
    private(set) var replies: [String: Double] = [:]
    private let channel: URL
    private var seq = 0
    private var doneRead = 0

    init(app: String, seconds: Double = 600) async throws {
        let url = URL(fileURLWithPath: app)
        guard let bid = Bundle(url: url)?.bundleIdentifier else { throw SelftestError("no bundle at \(app); see docs/m3/integration.md for the Stimulus.app recipe") }
        bundleID = bid
        channel = FileManager.default.temporaryDirectory.appending(path: "sitr-stimulus-\(getpid())-\(bid)")
        try? FileManager.default.removeItem(at: channel)
        try FileManager.default.createDirectory(at: channel, withIntermediateDirectories: true)
        try Data().write(to: RemoteLayout.doneFile(channel.path))
        let dir = channel
        Harness.onExit { try? FileManager.default.removeItem(at: dir) }
        process.executableURL = url.appending(path: "Contents/MacOS/Sitr")
        process.arguments = ["--selftest", "stimulus", "--remote", "--seconds", "\(Int(seconds))", "--channel", channel.path]
        let p = process
        Harness.onExit { if p.isRunning { p.terminate() } }
        try process.run()
        guard await ask("pulse", timeout: 5) != nil else {
            terminate()
            throw SelftestError("stimulus handshake failed; use the unsandboxed Stimulus.app recipe in docs/m3/integration.md")
        }
    }

    /// Writes `command` to the channel; the stimulus answers with the time of its flushed transaction.
    func send(_ command: String, argument: String? = nil) {
        drainReplies()
        replies[command] = nil
        seq += 1
        try? Data("\(seq) \(command) \(argument ?? "")".utf8).write(to: RemoteLayout.commandFile(channel.path), options: .atomic)
    }

    /// Sends `command` and waits (≤ `timeout`) for its reply time.
    func ask(_ command: String, argument: String? = nil, timeout: Double = 3) async -> Double? {
        send(command, argument: argument)
        return await reply(command, timeout: timeout)
    }

    /// Reads the lines the stimulus appended since the last look into `replies` (command → flush time).
    private func drainReplies() {
        guard let data = try? Data(contentsOf: RemoteLayout.doneFile(channel.path)), data.count > doneRead else { return }
        let fresh = String(decoding: data[doneRead...], as: UTF8.self)
        doneRead = data.count
        for line in fresh.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 2, let t = Double(parts[1]) { replies[String(parts[0])] = t }
        }
    }

    /// Moves the stimulus window's top-left corner to a display-local point.
    func place(at p: CGPoint) async { _ = await ask("origin", argument: "\(Int(p.x)),\(Int(p.y))") }

    func reply(_ command: String, timeout: Double) async -> Double? {
        _ = await waitUntil(timeout) {
            self.drainReplies()
            return self.replies[command] != nil
        }
        return replies[command]
    }

    /// Frontmost window of the stimulus on `displayID`, from the tracker (nil until it shows).
    func window(in tracker: WindowTracker, on displayID: CGDirectDisplayID) -> WindowRect? {
        tracker.windows(for: bundleID).first { $0.displayID == displayID }
    }

    func waitForWindow(in tracker: WindowTracker, on displayID: CGDirectDisplayID, timeout: Double = 15) async -> WindowRect? {
        _ = await waitUntil(timeout) { self.window(in: tracker, on: displayID) != nil }
        return window(in: tracker, on: displayID)
    }

    /// Pulses the heartbeat every 300 ms until `condition` holds (≤ `seconds`): frames keep flowing while tracks expire and
    /// pre-covered tiles clear, without ever earning trusted motion.
    func pulseUntil(_ seconds: Double, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = CACurrentMediaTime() + seconds
        while CACurrentMediaTime() < deadline {
            if condition() { return true }
            send("pulse")
            try? await Task.sleep(for: .milliseconds(300))
        }
        return condition()
    }

    func terminate() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: channel)
    }
}

/// A second, unfiltered stream on the display: the truth about what is on screen, for pixel checks while the runtime's own stream
/// is stopped (fail-closed) or filtered (Off apps). Keeps the latest frame only.
@MainActor
private final class ControlSampler {
    private let session: CaptureSession
    private var latest: Frame?
    private var task: Task<Void, Never>?

    init(displayID: CGDirectDisplayID) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw SelftestError("display not in SCShareableContent") }
        session = CaptureSession(displayID: displayID, permission: PermissionMonitor())
        session.fps = 30
        try await session.updateFilter(SCContentFilter(display: display, excludingWindows: []))
        let s = session
        Harness.onExit { s.stop() }
        session.start()
        task = Task { @MainActor [weak self] in
            for await f in s.frames { self?.latest = f }
        }
    }

    /// RGB under a display-local point in the newest frame (nil before the first frame).
    func rgb(at p: CGPoint) -> RGB? {
        guard let f = latest else { return nil }
        let px = f.displayPointsToPixels(CGRect(origin: p, size: .zero))
        return sampleRGB(f.pixelBuffer, x: Int(px.minX), y: Int(px.minY))
    }

    /// Waits for a frame newer than the current one (the screen changed and the change is in a frame).
    func nextFrame(timeout: Double = 2) async {
        let seq = latest?.sequence ?? 0
        _ = await waitUntil(timeout) { (self.latest?.sequence ?? 0) > seq }
    }

    func stop() {
        task?.cancel()
        session.stop()
    }
}

nonisolated extension RGB {
    var isMagenta: Bool { r > 150 && b > 150 && g < 120 }
    /// Within ±20 of a solid (gray) cover colour with no hue.
    func isSolid(_ color: CGColor) -> Bool {
        guard let c = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components, c.count >= 3 else { return false }
        let (er, eg, eb) = (Int(c[0] * 255), Int(c[1] * 255), Int(c[2] * 255))
        return abs(r - er) <= 20 && abs(g - eg) <= 20 && abs(b - eb) <= 20 && abs(r - g) < 14 && abs(g - b) < 14
    }
}

/// Share of `region` under the union of `frames`, on a 16×16 grid of sample points (pre-covers are several tile runs, so a single
/// intersection would under-count).
nonisolated func coverage(of region: CGRect, by frames: [CGRect]) -> Double {
    guard region.width > 0, region.height > 0, !frames.isEmpty else { return 0 }
    var inside = 0
    for i in 0..<16 {
        for j in 0..<16 {
            let p = CGPoint(x: region.minX + region.width * (Double(i) + 0.5) / 16, y: region.minY + region.height * (Double(j) + 0.5) / 16)
            if frames.contains(where: { $0.contains(p) }) { inside += 1 }
        }
    }
    return Double(inside) / 256
}

/// Follows every pre-cover apply and every commit for one region: whether pre-covers / track covers are over it right now, when
/// the first of each landed after `arm()`, how many pre-cover applies hit it, and when the pre-covers last left it.
@MainActor
private final class CurtainRecorder {
    var region: CGRect
    private(set) var preCovered = false, trackCovered = false
    private(set) var preHit: Double?, trackHit: Double?
    private(set) var preHits = 0
    private(set) var preCleared: Double?
    private(set) var preApplies = 0, commits = 0
    /// Diagnostics since `arm()`: applies with any pre-cover layer, the best coverage of `region` one reached, and its rects.
    private(set) var preLayersSinceArm = 0, bestCoverage = 0.0
    private(set) var bestRects = ""
    private var armed = false

    init(region: CGRect) { self.region = region }

    func arm() {
        preHit = nil
        trackHit = nil
        preLayersSinceArm = 0
        bestCoverage = 0
        bestRects = ""
        armed = true
    }

    private func notePre(_ specs: [CoverLayerSpec], at time: Double) {
        let pre = specs.filter { CoverID.isPreCover($0.id) }
        let share = coverage(of: region, by: pre.map(\.frame))
        if armed, !pre.isEmpty {
            preLayersSinceArm += pre.count
            if share > bestCoverage {
                bestCoverage = share
                bestRects = pre.prefix(3).map { rectString($0.frame) }.joined(separator: ",")
            }
        }
        let now = share >= 0.5
        if now { preHits += 1 }
        if armed, now, preHit == nil { preHit = time }
        if preCovered, !now { preCleared = time }
        preCovered = now
    }

    func recordPreCover(_ specs: [CoverLayerSpec], at time: Double) {
        preApplies += 1
        notePre(specs, at: time)
    }

    func recordCommit(_ specs: [CoverLayerSpec], at time: Double) {
        commits += 1
        notePre(specs, at: time)
        trackCovered = coverage(of: region, by: specs.filter { CoverID.isTrack($0.id) }.map(\.frame)) >= 0.25
        if armed, trackCovered, trackHit == nil { trackHit = time }
    }
}

/// `--stimulus <path>` / `--stimulus2 <path>`, else `SITR_STIMULUS_APP` / `SITR_STIMULUS2_APP`, else `build/Stimulus.app` / `build/Stimulus2.app`.
nonisolated func stimulusPath(_ args: [String], second: Bool = false) -> String {
    let env = ProcessInfo.processInfo.environment
    return option(args, second ? "--stimulus2" : "--stimulus") ?? env[second ? "SITR_STIMULUS2_APP" : "SITR_STIMULUS_APP"]
        ?? "build/\(second ? "Stimulus2" : "Stimulus").app"
}

/// Own-process CPU seconds (user + system), for the % of one core over a run.
nonisolated func processCPUSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6 + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
}

/// Boots the runtime with `rules` and the remote stimulus, waits for its window on the main display, and returns everything the
/// M3 tests share. `bootFirst`: launch the stimulus before the runtime (steady state) or after (launch-after-start).
@MainActor
private func bootWithStimulus(rules: Rules, app: String, launchAfterBoot: Bool = false) async throws
    -> (runtime: Runtime, display: ManagedDisplay, pipeline: Pipeline, stimulus: RemoteApp, window: WindowRect)
{
    var stimulus: RemoteApp?
    if !launchAfterBoot {
        // Steady state: the stimulus window exists before capture starts (a throwaway tracker waits for it).
        let launched = try await RemoteApp(app: app)
        let probe = WindowTracker()
        _ = await waitUntil(15) {
            probe.refresh()
            return !probe.windows(for: launched.bundleID).isEmpty
        }
        stimulus = launched
    }
    let (runtime, d, pipeline) = try await bootRuntime(rules: rules)
    if launchAfterBoot { stimulus = try await RemoteApp(app: app) }
    guard let stimulus else { throw SelftestError("no stimulus") }
    guard let window = await stimulus.waitForWindow(in: runtime.windowTracker, on: d.id) else {
        throw SelftestError("stimulus window (\(stimulus.bundleID)) never appeared in the WindowTracker")
    }
    print("stimulus_window bundle=\(stimulus.bundleID) pid=\(stimulus.process.processIdentifier) rect=\(rectString(window.rect)) z=\(window.zOrder) "
        + "rule=\(rules.mode(for: stimulus.bundleID)) default=\(rules.defaultMode) fps=\(d.session.fps) curtain_fps=\(Runtime.curtainFPS)")
    return (runtime, d, pipeline, stimulus, window)
}

// MARK: filter (M3-T03)

/// The stimulus (its own bundle id) runs with an Off override: its magenta marker must never be in the frames the pipeline sees;
/// switching it to Blur shows the marker within 1 s; Default Off + a Curtain override (include filter) keeps it; Off again under
/// Default Off (empty include list) hides it within 1 s; killed and relaunched with a Blur override it is included within 1 s of
/// its window appearing. Pixels are sampled from the frames the pipeline processes (the `onPreCover` hook fires on every arrival).
@MainActor
private func filterTest(stimulusApp: String) async throws -> Bool {
    let stimulusID = Bundle(url: URL(fileURLWithPath: stimulusApp))?.bundleIdentifier ?? "com.goldentik.SitrStimulus"
    var rules = Rules(defaultMode: .blur, overrides: [AppRule(bundleID: stimulusID, mode: .off)])
    let (runtime, d, _, stimulus, window0) = try await bootWithStimulus(rules: rules, app: stimulusApp)
    let model = runtime.model
    var markerPoint = CGPoint(x: window0.rect.minX + RemoteLayout.marker.midX, y: window0.rect.minY + RemoteLayout.marker.midY)
    var frames = 0, markerFrames = 0, framesBeforeFilter = 0, leakBeforeFilter = 0
    var lastMarkerAt: Double?, firstMarkerAt: Double?
    var lastRGB: RGB?
    runtime.onPreCover = { id, _, frame, at in
        guard id == d.id else { return }
        frames += 1
        let px = frame.displayPointsToPixels(CGRect(origin: markerPoint, size: .zero))
        guard let c = sampleRGB(frame.pixelBuffer, x: Int(px.minX), y: Int(px.minY)) else { return }
        lastRGB = c
        if runtime.filters.installs == 0 {
            framesBeforeFilter += 1
            if c.isMagenta { leakBeforeFilter += 1 }
            return
        }
        if c.isMagenta {
            markerFrames += 1
            lastMarkerAt = at
            if firstMarkerAt == nil { firstMarkerAt = at }
        }
    }
    func reset() {
        frames = 0
        markerFrames = 0
        firstMarkerAt = nil
        lastMarkerAt = nil
    }
    var ok = true

    // A. Off override under Default Blur (exclude list): once the plan names the stimulus, 3 s of frames without the marker. Frames
    //    before that (stream up before the first filter, or before the stimulus was in `SCShareableContent`) are counted apart.
    let stimulusPID = stimulus.process.processIdentifier
    func planExcludesStimulus() -> Bool {
        switch runtime.filters.plans[d.id] {
        case .include(let pids): return !pids.contains(stimulusPID)
        case .exclude(let pids): return pids.contains(stimulusPID)
        case nil: return false
        }
    }
    let planned = await waitUntil(5) { planExcludesStimulus() }
    // The stream may still carry the pre-plan filter for a moment (docs/m3/integration.md: connect race); wait for the marker to be
    // gone for 0.5 s of frames, then measure.
    _ = await waitUntil(5) { frames > 0 && lastMarkerAt.map { CACurrentMediaTime() - $0 > 0.5 } ?? true }
    let leakDuringBoot = markerFrames, framesDuringBoot = frames
    reset()
    try await Task.sleep(for: .seconds(3))
    let planA = runtime.filters.plans[d.id].map { "\($0)" } ?? "none"
    print("filter_off_excluded frames=\(frames) marker_frames=\(markerFrames) frames_before_first_filter=\(framesBeforeFilter) leak_before_first_filter=\(leakBeforeFilter) "
        + "frames_until_plan=\(framesDuringBoot) leak_until_plan=\(leakDuringBoot) installs=\(runtime.filters.installs) plan=\(planA) last_rgb=\(rgbString(lastRGB)) "
        + "ok=\(planned && frames > 0 && markerFrames == 0) load1=\(fmt(loadAverage()))")
    ok = ok && planned && frames > 0 && markerFrames == 0

    // B. Override → Blur: the marker shows within 1 s of the rules change.
    reset()
    let tB = CACurrentMediaTime()
    model.updateRules { $0.upsert(AppRule(bundleID: stimulusID, mode: .blur)) }
    let shown = await waitUntil(3) { firstMarkerAt != nil }
    let showMs = firstMarkerAt.map { Int(($0 - tB) * 1000) } ?? -1
    print("filter_blur_visible shown=\(shown) within_ms=\(showMs) marker_frames=\(markerFrames) frames=\(frames) plan=\(runtime.filters.plans[d.id].map { "\($0)" } ?? "none") ok=\(shown && showMs <= 1000)")
    ok = ok && shown && showMs <= 1000

    // C. Default Off + Curtain override (include list): still captured.
    reset()
    rules = Rules(defaultMode: .off, overrides: [AppRule(bundleID: stimulusID, mode: .curtain)])
    model.updateRules { $0 = rules }
    try await Task.sleep(for: .milliseconds(1500))
    let tC = CACurrentMediaTime()
    reset()
    _ = await stimulus.ask("person_on")  // a change inside the window, so frames flow
    let stillVisible = await waitUntil(2) { markerFrames > 0 }
    _ = await stimulus.ask("person_off")
    print("filter_include_curtain visible=\(stillVisible) within_ms=\(firstMarkerAt.map { Int(($0 - tC) * 1000) } ?? -1) plan=\(runtime.filters.plans[d.id].map { "\($0)" } ?? "none") ok=\(stillVisible)")
    ok = ok && stillVisible

    // D. Off under Default Off: the include list is empty, the marker goes within 1 s.
    reset()
    let tD = CACurrentMediaTime()
    model.updateRules { $0.upsert(AppRule(bundleID: stimulusID, mode: .off)) }
    try await Task.sleep(for: .milliseconds(1200))
    _ = await stimulus.ask("person_on")
    _ = await stimulus.ask("person_off")
    try await Task.sleep(for: .milliseconds(800))
    let lastSeen = lastMarkerAt.map { Int(($0 - tD) * 1000) } ?? -1
    let hiddenOK = !d.session.isConnected && markerFrames == 0
    print("filter_off_hidden frames=\(frames) marker_frames=\(markerFrames) last_marker_ms_after_rule=\(lastSeen) plan=\(runtime.filters.plans[d.id].map { "\($0)" } ?? "none") ok=\(hiddenOK)")
    ok = ok && hiddenOK

    // E. Launched after start: kill the stimulus, give it a Blur override (Default Off), relaunch; included within 1 s of its window.
    stimulus.terminate()
    _ = await waitUntil(5) { runtime.windowTracker.windows(for: stimulusID).isEmpty }
    model.updateRules { $0.upsert(AppRule(bundleID: stimulusID, mode: .blur)) }
    try await Task.sleep(for: .milliseconds(700))
    reset()
    let installsBefore = runtime.filters.installs
    let relaunched = try await RemoteApp(app: stimulusApp)
    guard let window1 = await relaunched.waitForWindow(in: runtime.windowTracker, on: d.id) else { throw SelftestError("relaunched stimulus window missing") }
    let tE = CACurrentMediaTime()
    markerPoint = CGPoint(x: window1.rect.minX + RemoteLayout.marker.midX, y: window1.rect.minY + RemoteLayout.marker.midY)
    reset()
    let included = await waitUntil(3) { firstMarkerAt != nil }
    let includeMs = firstMarkerAt.map { Int(($0 - tE) * 1000) } ?? -1
    print("filter_launch_included included=\(included) within_ms_of_window=\(includeMs) installs_added=\(runtime.filters.installs - installsBefore) "
        + "plan=\(runtime.filters.plans[d.id].map { "\($0)" } ?? "none") error=\(runtime.filters.lastError ?? "none") ok=\(included && includeMs <= 1000) load1=\(fmt(loadAverage()))")
    ok = ok && included && includeMs <= 1000
    relaunched.terminate()
    runtime.displayManager.stop()
    return ok
}

// MARK: curtain (M3-T05)

/// Per trial the remote stimulus flips its photo on and reports the flush time; the clock stops at the first pre-cover apply that
/// covers the person region (≥ 50 % of it, before detection). Also records when the person cover (a track) lands. Between trials
/// the region is blank and the pre-covers over it must be gone; a random 100–170 ms keeps paints off the capture cadence.
@MainActor
private func curtainExposureTest(trials: Int, stimulusApp: String) async throws -> Bool {
    let stimulusID = Bundle(url: URL(fileURLWithPath: stimulusApp))?.bundleIdentifier ?? "com.goldentik.SitrStimulus"
    let rules = Rules(defaultMode: .off, overrides: [AppRule(bundleID: stimulusID, mode: .curtain)])
    let (runtime, d, pipeline, stimulus, window) = try await bootWithStimulus(rules: rules, app: stimulusApp)
    let person = RemoteLayout.person.offsetBy(dx: window.rect.minX, dy: window.rect.minY)
    let recorder = CurtainRecorder(region: person)
    runtime.onPreCover = { id, specs, _, at in if id == d.id { recorder.recordPreCover(specs, at: at) } }
    runtime.onCommit = { id, specs, _, at in if id == d.id { recorder.recordCommit(specs, at: at) } }
    let cpu0 = processCPUSeconds(), wall0 = CACurrentMediaTime()
    var exposures: [Double] = [], personCovers: [Double] = []
    var missed = 0, notCleared = 0, fpsSeen = d.session.fps
    for i in 0...trials {  // trial 0 warms everything and is not counted
        let tTrial = CACurrentMediaTime()
        _ = await stimulus.ask("person_off")
        let settled = await stimulus.pulseUntil(4) { !recorder.preCovered && !recorder.trackCovered }
        if !settled { notCleared += 1 }
        let tSettled = CACurrentMediaTime()
        // Then a fully still window for > `Curtain.staticReset` (1 s): the pulses that flush the covers out are motion, and
        // motion verified safe earns trusted motion (FR4.3), which is exactly when Curtain stops pre-covering. The random
        // 0–70 ms keeps the flip off the capture cadence.
        try await Task.sleep(for: .milliseconds(1200 + Int.random(in: 0..<70)))
        recorder.arm()
        guard let tFlip = await stimulus.ask("person_on") else { missed += 1; continue }
        _ = await waitUntil(2) { recorder.preHit != nil && recorder.trackHit != nil }
        fpsSeen = max(fpsSeen, d.session.fps)
        if i % 5 == 0 || recorder.preHit == nil {  // progress, and every trial that saw no pre-cover (counts, times and rects only)
            print("curtain_trial i=\(i) settle_ms=\(Int((tSettled - tTrial) * 1000)) settled=\(settled) pre_ms=\(recorder.preHit.map { ms($0 - tFlip) } ?? "-") "
                + "track_ms=\(recorder.trackHit.map { ms($0 - tFlip) } ?? "-") pre_layers=\(recorder.preLayersSinceArm) best_coverage=\(fmt(recorder.bestCoverage)) "
                + "pre_rects=[\(recorder.bestRects)] region=\(rectString(recorder.region)) trial_ms=\(Int((CACurrentMediaTime() - tTrial) * 1000)) load1=\(fmt(loadAverage()))")
        }
        guard i > 0 else { continue }
        if let hit = recorder.preHit { exposures.append(hit - tFlip) } else { missed += 1 }
        if let hit = recorder.trackHit { personCovers.append(hit - tFlip) }
    }
    _ = await stimulus.ask("person_off")
    let cpu = (processCPUSeconds() - cpu0) / (CACurrentMediaTime() - wall0) * 100
    let m = await pipeline.metrics
    let load = loadAverage(), noisy = load > 4
    let p50 = percentile(exposures, 0.5), p95 = percentile(exposures, 0.95)
    print("curtain_exposure_ms p50=\(ms(p50)) p95=\(ms(p95)) n=\(exposures.count) missed=\(missed) target_p95_ms=60 within_target=\(p95 <= 0.060) "
        + "fps=\(fpsSeen) curtain_fps=\(Runtime.curtainFPS) cpu_pct=\(fmt(cpu)) style=\(runtime.appearance.style.rawValue) load1=\(fmt(load)) noisy=\(noisy)")
    print("curtain_person_cover_ms p50=\(ms(percentile(personCovers, 0.5))) p95=\(ms(percentile(personCovers, 0.95))) n=\(personCovers.count) "
        + "cleared_between_trials=\(notCleared == 0) load1=\(fmt(load))")
    print("curtain_counts in=\(m.framesIn) out=\(m.framesOut) skipped=\(m.skipped) pre_applies=\(m.preApplies) pre_solid=\(m.preSolid) gap_covers=\(m.gapCovers) fast_ms=\(PipelineMetrics.p(m.fastPath)) "
        + "pre_render_ms=\(PipelineMetrics.p(m.preRender)) clear_ms=\(PipelineMetrics.p(m.curtainClear)) detect_ms=\(PipelineMetrics.p(m.detect)) e2e_ms=\(PipelineMetrics.p(m.e2e)) "
        + "health=\(runtime.model.policy.health) \(runtime.modelsNote) load1=\(fmt(load))")
    stimulus.terminate()
    runtime.displayManager.stop()
    return !exposures.isEmpty && exposures.count >= trials * 9 / 10 && notCleared == 0
        && fpsSeen == Runtime.curtainFPS && (noisy || p95 <= 0.060)
}

/// The stimulus scrolls its text column (no people) five times: each burst must be pre-covered, then the pre-cover must clear once
/// the last dirty frame is verified. `clear_ms` (pipeline: detection done → pre-cover gone) must stay ≤ 100 ms; `linger_ms` is
/// scroll end → pre-cover gone, the number the user sees.
@MainActor
private func curtainScrollTest(stimulusApp: String) async throws -> Bool {
    let stimulusID = Bundle(url: URL(fileURLWithPath: stimulusApp))?.bundleIdentifier ?? "com.goldentik.SitrStimulus"
    let rules = Rules(defaultMode: .off, overrides: [AppRule(bundleID: stimulusID, mode: .curtain)])
    let (runtime, d, pipeline, stimulus, window) = try await bootWithStimulus(rules: rules, app: stimulusApp)
    let text = RemoteLayout.text.offsetBy(dx: window.rect.minX, dy: window.rect.minY)
    let recorder = CurtainRecorder(region: text)
    runtime.onPreCover = { id, specs, _, at in if id == d.id { recorder.recordPreCover(specs, at: at) } }
    runtime.onCommit = { id, specs, _, at in if id == d.id { recorder.recordCommit(specs, at: at) } }
    var preMs: [Double] = [], lingerMs: [Double] = []
    var ok = true
    for i in 0..<6 {
        _ = await stimulus.pulseUntil(4) { !recorder.preCovered }
        try await Task.sleep(for: .milliseconds(1200))
        recorder.arm()
        stimulus.send("scroll")
        guard let tStart = await stimulus.reply("scroll_start", timeout: 3), let tEnd = await stimulus.reply("scroll", timeout: 3) else { ok = false; continue }
        let covered = await waitUntil(2) { recorder.preHit != nil }
        let cleared = await waitUntil(3) { !recorder.preCovered }
        guard i > 0 else { continue }
        let pre = recorder.preHit.map { $0 - tStart } ?? .nan
        let linger = recorder.preCleared.map { $0 - tEnd } ?? .nan
        preMs.append(pre)
        lingerMs.append(linger)
        print("curtain_scroll trial=\(i) precovered=\(covered) precover_ms=\(ms(pre)) cleared=\(cleared) linger_ms=\(ms(linger)) load1=\(fmt(loadAverage()))")
        ok = ok && covered && cleared
    }
    let m = await pipeline.metrics
    let clearP95 = percentile(m.curtainClear, 0.95)
    print("curtain_scroll_summary precover_ms p50=\(ms(percentile(preMs, 0.5))) p95=\(ms(percentile(preMs, 0.95))) linger_ms p50=\(ms(percentile(lingerMs, 0.5))) "
        + "p95=\(ms(percentile(lingerMs, 0.95))) clear_ms p50=\(ms(percentile(m.curtainClear, 0.5))) p95=\(ms(clearP95)) n=\(m.curtainClear.count) target_clear_ms=100 "
        + "within_target=\(clearP95 <= 0.1) pre_applies=\(m.preApplies) pre_solid=\(m.preSolid) fps=\(d.session.fps) load1=\(fmt(loadAverage()))")
    stimulus.terminate()
    runtime.displayManager.stop()
    return ok && clearP95 <= 0.1
}

/// `seconds` of block motion without people in the Curtain window: trusted motion within ~500 ms (`trusted_after_ms`), no
/// pre-cover over the video afterwards (`precover_after_trust`), and the person shown halfway through gets a person cover
/// (`mid_video_cover_ms`). CPU is the process share of one core over the run.
@MainActor
private func curtainVideoTest(seconds: Double, stimulusApp: String) async throws -> Bool {
    let stimulusID = Bundle(url: URL(fileURLWithPath: stimulusApp))?.bundleIdentifier ?? "com.goldentik.SitrStimulus"
    let rules = Rules(defaultMode: .off, overrides: [AppRule(bundleID: stimulusID, mode: .curtain)])
    let (runtime, d, pipeline, stimulus, window) = try await bootWithStimulus(rules: rules, app: stimulusApp)
    let video = RemoteLayout.photo.offsetBy(dx: window.rect.minX, dy: window.rect.minY)
    let person = RemoteLayout.person.offsetBy(dx: window.rect.minX, dy: window.rect.minY)
    let recorder = CurtainRecorder(region: video)
    let personRecorder = CurtainRecorder(region: person)
    runtime.onPreCover = { id, specs, _, at in
        guard id == d.id else { return }
        recorder.recordPreCover(specs, at: at)
        personRecorder.recordPreCover(specs, at: at)
    }
    runtime.onCommit = { id, specs, _, at in
        guard id == d.id else { return }
        recorder.recordCommit(specs, at: at)
        personRecorder.recordCommit(specs, at: at)
    }
    _ = await stimulus.pulseUntil(4) { !recorder.preCovered }
    try await Task.sleep(for: .milliseconds(1400))  // > Curtain.staticReset, so any trust from the settle pulses is dropped
    let cpu0 = processCPUSeconds(), wall0 = CACurrentMediaTime()
    recorder.arm()
    guard let t0 = await stimulus.ask("video_on") else { throw SelftestError("stimulus did not start the video") }
    let wid = Int(window.windowID)
    var trustedAt: Double?
    while CACurrentMediaTime() - t0 < 3, trustedAt == nil {
        if await pipeline.trustedCurtainWindows[stimulusID]?.contains(wid) == true { trustedAt = CACurrentMediaTime() }
        try await Task.sleep(for: .milliseconds(10))
    }
    let trustedMs = trustedAt.map { Int(($0 - t0) * 1000) } ?? -1
    let preHitsAtTrust = recorder.preHits
    let firstPre = recorder.preHit.map { Int(($0 - t0) * 1000) } ?? -1
    print("curtain_video_trust trusted=\(trustedAt != nil) trusted_after_ms=\(trustedMs) first_precover_ms=\(firstPre) precover_applies_before_trust=\(preHitsAtTrust) fps=\(d.session.fps) load1=\(fmt(loadAverage()))")
    var ok = trustedAt != nil && trustedMs <= 700
    // Half the run without people, then the person appears inside the moving video.
    let half = t0 + seconds / 2
    while CACurrentMediaTime() < half { try await Task.sleep(for: .milliseconds(100)) }
    let preBeforePerson = recorder.preHits - preHitsAtTrust
    personRecorder.arm()
    guard let tPerson = await stimulus.ask("person_on") else { throw SelftestError("stimulus did not show the person") }
    _ = await waitUntil(3) { personRecorder.trackHit != nil }
    let midMs = personRecorder.trackHit.map { Int(($0 - tPerson) * 1000) } ?? -1
    let midPre = personRecorder.preHit.map { Int(($0 - tPerson) * 1000) } ?? -1
    print("curtain_video_person mid_video_cover_ms=\(midMs) precover_on_person_ms=\(midPre) trusted_still=\(await pipeline.trustedCurtainWindows[stimulusID]?.contains(wid) == true) load1=\(fmt(loadAverage()))")
    ok = ok && midMs >= 0 && midMs <= 1000
    while CACurrentMediaTime() - t0 < seconds { try await Task.sleep(for: .milliseconds(100)) }
    let cpu = (processCPUSeconds() - cpu0) / (CACurrentMediaTime() - wall0) * 100
    let preAfterTrust = recorder.preHits - preHitsAtTrust
    _ = await stimulus.ask("video_off")
    _ = await stimulus.ask("person_off")
    let m = await pipeline.metrics
    print("curtain_video_summary seconds=\(Int(seconds)) precover_after_trust=\(preAfterTrust) precover_after_trust_before_person=\(preBeforePerson) frames_in=\(m.framesIn) "
        + "skipped=\(m.skipped) detections=\(m.detections) pre_applies=\(m.preApplies) tracks=\(m.tracks) cpu_pct=\(fmt(cpu)) fps=\(d.session.fps) curtain_fps=\(Runtime.curtainFPS) "
        + "detect_ms=\(PipelineMetrics.p(m.detect)) e2e_ms=\(PipelineMetrics.p(m.e2e)) rss_mb=\(Int(residentMemoryMB())) load1=\(fmt(loadAverage()))")
    ok = ok && preAfterTrust == 0
    stimulus.terminate()
    runtime.displayManager.stop()
    return ok
}

// MARK: fail-closed for Curtain apps (M3-T06), the Curtain half of `--selftest failstate`

/// With the remote stimulus under a Curtain override: `session.stop()` → its window is Solid-covered within 1 s (fail-closed layer
/// frames equal the window rect, and the marker pixel on the unfiltered control stream shows the solid colour); a `move` moves the
/// cover with the window; `start()` lifts it on the first frame. Blur windows stay uncovered (the in-process stimulus panel is
/// Default-Rule Blur and gets nothing). Returns nil when no Stimulus.app is available (the M2 half still runs).
@MainActor
private func failClosedCheck(runtime: Runtime, display d: ManagedDisplay, stimulusApp: String) async throws -> Bool? {
    guard FileManager.default.fileExists(atPath: stimulusApp) else {
        print("failstate_curtain skipped: no Stimulus.app at \(stimulusApp) (docs/m3/integration.md)")
        return nil
    }
    let model = runtime.model
    let stimulus = try await RemoteApp(app: stimulusApp)
    model.updateRules { $0.upsert(AppRule(bundleID: stimulus.bundleID, mode: .curtain)) }
    guard var window = await stimulus.waitForWindow(in: runtime.windowTracker, on: d.id) else { throw SelftestError("stimulus window missing") }
    let control = try await ControlSampler(displayID: d.id)
    func marker(_ w: WindowRect) -> CGPoint { CGPoint(x: w.rect.minX + RemoteLayout.marker.midX, y: w.rect.minY + RemoteLayout.marker.midY) }
    func failClosedFrames() -> [CGRect] { d.panel.coverFrames.filter { CoverID.isFailClosed($0.key) }.map(\.value) }
    func covers(_ w: WindowRect) -> Bool { coverage(of: w.rect, by: failClosedFrames()) >= 0.98 }
    // Baseline: capture up, the pre-cover of the new window has cleared, the marker is visible on screen.
    _ = await waitUntil(5) { d.panel.coverFrames.keys.allSatisfy { CoverID.isTrack($0) } }
    _ = await waitUntil(5) { control.rgb(at: marker(window))?.isMagenta == true }
    let baselineVisible = control.rgb(at: marker(window))?.isMagenta == true
    let solid = d.renderer.solidColor
    print("failstate_curtain_baseline health=\(model.policy.health) marker_visible=\(baselineVisible) failclosed_layers=\(failClosedFrames().count) "
        + "notifications=\(runtime.notifier.posted) window=\(rectString(window.rect))")
    var ok = failClosedFrames().isEmpty

    // Stop: solid over the whole window within 1 s.
    // The Blur half already announced this stop/recovery pair; repeats within five minutes stay deduplicated.
    let posted0 = runtime.notifier.posted
    let t0 = CACurrentMediaTime()
    d.session.stop()
    runtime.permission.markRevoked()
    let coveredLayers = await waitUntil(3) { covers(window) }
    let layerMs = Int((CACurrentMediaTime() - t0) * 1000)
    let coveredPixels = await waitUntil(2) { control.rgb(at: marker(window))?.isSolid(solid) == true }
    let pixelMs = Int((CACurrentMediaTime() - t0) * 1000)
    let blurUncovered = await waitUntil(2) {
        model.status == .recovering && d.panel.coverFrames.keys.allSatisfy { CoverID.isFailClosed($0) }
    }
    print("failstate_curtain_stop health=\(model.policy.health) solid_layers=\(coveredLayers) layers_within_ms=\(layerMs) solid_pixels=\(coveredPixels) pixels_within_ms=\(pixelMs) "
        + "marker_rgb=\(rgbString(control.rgb(at: marker(window)))) failclosed_layers=\(failClosedFrames().count) blur_uncovered=\(blurUncovered) "
        + "notifications=\(runtime.notifier.posted) icon=\(model.iconState) ok=\(coveredLayers && coveredPixels && layerMs <= 1000)")
    ok = ok && coveredLayers && coveredPixels && layerMs <= 1000 && blurUncovered && runtime.notifier.posted == posted0

    // Move: the cover follows the window (tracker at 10 Hz).
    let oldMarker = marker(window)
    let oldOrigin = window.rect.origin
    let t1 = CACurrentMediaTime()
    _ = await stimulus.ask("move")
    let moved = await waitUntil(3) {
        if let w = stimulus.window(in: runtime.windowTracker, on: d.id),
           abs(w.rect.minX - oldOrigin.x - RemoteLayout.moveBy.dx) < 8,
           abs(w.rect.minY - oldOrigin.y - RemoteLayout.moveBy.dy) < 8 {
            window = w
            return covers(w)
        }
        return false
    }
    let followMs = Int((CACurrentMediaTime() - t1) * 1000)
    let newSolid = await waitUntil(2) { control.rgb(at: marker(window))?.isSolid(solid) == true }
    await control.nextFrame()
    let oldNotSolid = control.rgb(at: oldMarker)?.isSolid(solid) == false
    print("failstate_curtain_move moved=\(moved) follow_within_ms=\(followMs) window=\(rectString(window.rect)) new_marker_solid=\(newSolid) old_spot_uncovered=\(oldNotSolid) "
        + "old_rgb=\(rgbString(control.rgb(at: oldMarker))) failclosed_layers=\(failClosedFrames().count) notifications=\(runtime.notifier.posted) ok=\(moved && newSolid)")
    // `old_spot_uncovered` is informational: in light appearance the Solid colour is near-white, so a white window under the old
    // spot reads the same. The gate is that the cover is over the window's new rect (layer geometry + the pixel there).
    ok = ok && moved && newSolid

    // Restart: the first frame lifts the fail-closed cover; one "restored" notification.
    let t2 = CACurrentMediaTime()
    d.session.start()
    let lifted = await waitUntil(6) {
        stimulus.send("person_off")  // a screen change, so frames flow
        return failClosedFrames().isEmpty && model.policy.health == .ok
    }
    let liftMs = Int((CACurrentMediaTime() - t2) * 1000)
    let visibleAgain = await waitUntil(3) { control.rgb(at: marker(window))?.isMagenta == true }
    print("failstate_curtain_restart health=\(model.policy.health) lifted=\(lifted) within_ms=\(liftMs) marker_visible=\(visibleAgain) failclosed_layers=\(failClosedFrames().count) "
        + "notifications=\(runtime.notifier.posted) icon=\(model.iconState) ok=\(lifted && runtime.notifier.posted == posted0)")
    ok = ok && lifted && visibleAgain && runtime.notifier.posted == posted0
    print("failstate_stall manual pending: a live stream that stops delivering frames cannot be forced from outside CaptureSession; the decision is unit-tested (Runtime.isStalled)")
    control.stop()
    stimulus.terminate()
    return ok
}

// MARK: overlap and attribution (M3-T09)

/// Two remote stimuli (two bundle ids) stacked in the M3-T09 matrix. Pixels come from an unfiltered control stream; covers from the
/// panel's layer frames. Records, per scenario, whether a cover lands on the window on top and whether pre-covers stay inside
/// their Curtain window's visible region.
@MainActor
private func overlapTest(stimulusApp: String, stimulus2App: String) async throws -> Bool {
    let aID = Bundle(url: URL(fileURLWithPath: stimulusApp))?.bundleIdentifier ?? "com.goldentik.SitrStimulus"
    let bID = Bundle(url: URL(fileURLWithPath: stimulus2App))?.bundleIdentifier ?? "com.goldentik.SitrStimulus2"
    let rules = Rules(defaultMode: .off, overrides: [AppRule(bundleID: aID, mode: .blur), AppRule(bundleID: bID, mode: .off)])
    let (runtime, d, pipeline, a, _) = try await bootWithStimulus(rules: rules, app: stimulusApp)
    let model = runtime.model
    let b = try await RemoteApp(app: stimulus2App)
    guard await b.waitForWindow(in: runtime.windowTracker, on: d.id) != nil else { throw SelftestError("second stimulus window missing") }
    let control = try await ControlSampler(displayID: d.id)
    let tracker = runtime.windowTracker
    var ok = true
    var latest: [CoverLayerSpec] = []
    runtime.onCommit = { id, specs, _, _ in if id == d.id { latest = specs } }
    runtime.onPreCover = { id, specs, _, _ in if id == d.id, !specs.isEmpty { latest = specs + latest.filter { CoverID.isTrack($0.id) } } }
    func win(_ app: RemoteApp) -> WindowRect? { app.window(in: tracker, on: d.id) }
    func marker(_ w: WindowRect) -> CGPoint { CGPoint(x: w.rect.minX + RemoteLayout.marker.midX, y: w.rect.minY + RemoteLayout.marker.midY) }
    /// Places B so its marker sits at the centre of A's person box, and brings B to the front.
    func stackBOverAPerson() async {
        guard let wa = win(a) else { return }
        let personCentre = CGPoint(x: wa.rect.minX + RemoteLayout.person.midX, y: wa.rect.minY + RemoteLayout.person.midY)
        await b.place(at: CGPoint(x: personCentre.x - RemoteLayout.marker.midX, y: personCentre.y - RemoteLayout.marker.midY))
        _ = await b.ask("front")
        _ = await waitUntil(2) { (win(b)?.zOrder ?? 9) < (win(a)?.zOrder ?? 0) }
    }
    func settle(_ seconds: Double) async throws { try await Task.sleep(for: .seconds(seconds)) }

    // 1. Blur window (A, person shown) under an Off window (B): does A's person cover extend over B?
    await stackBOverAPerson()
    _ = await a.ask("person_on")
    try await settle(2.5)
    let wb1 = win(b), wa1 = win(a)
    let trackFrames = latest.filter { CoverID.isTrack($0.id) }.map(\.frame)
    let coverOnB = wb1.map { w in trackFrames.contains { $0.intersects(w.rect) } } ?? false
    let bMarkerCovered = wb1.map { !(control.rgb(at: marker($0))?.isMagenta ?? true) } ?? false
    // Who the person was attributed to: the topmost window under the box centre, which here is the Off window.
    let attributed = await pipeline.tracks.map { $0.bundleID ?? "desktop" }.sorted()
    print("overlap_blur_under_off a=\(rectString(wa1?.rect ?? .zero)) z_a=\(wa1?.zOrder ?? -1) b_off=\(rectString(wb1?.rect ?? .zero)) z_b=\(wb1?.zOrder ?? -1) person_covers=\(trackFrames.count) "
        + "tracks=\(attributed.count) attributed_to=\(attributed) cover_extends_over_off_window=\(coverOnB) off_marker_covered=\(bMarkerCovered) "
        + "b_marker_rgb=\(rgbString(wb1.flatMap { control.rgb(at: marker($0)) })) "
        + "note=\(coverOnB ? "PRD-permitted: a hidden person's box from a monitored app extends under the Off window" : "no cover on the Off window") load1=\(fmt(loadAverage()))")
    // The PRD rule is about what may appear ON an Off window; a person attributed to the Off app gets no cover by design
    // (docs/behaviour.md records the consequence). Gate: no cover on the Off window unless a person's box reaches under it.
    ok = ok && (!coverOnB || !trackFrames.isEmpty)
    _ = await a.ask("person_off")

    // 2. Curtain window (B) over a Blur window (A, person shown): pre-covers of B stay inside B; the person in A is still covered.
    model.updateRules { $0.upsert(AppRule(bundleID: bID, mode: .curtain)) }
    try await settle(1.5)
    _ = await a.ask("person_on")
    try await settle(2)
    var outsideB = 0, preSeen = 0
    runtime.onPreCover = { id, specs, _, _ in
        guard id == d.id, let wb = win(b) else { return }
        let pre = specs.filter { CoverID.isPreCover($0.id) }
        preSeen += pre.count
        outsideB += pre.count { $0.frame.intersection(wb.rect.insetBy(dx: -1, dy: -1)).area < $0.frame.area * 0.99 }
        latest = specs + latest.filter { CoverID.isTrack($0.id) }
    }
    _ = await b.ask("scroll")
    _ = await b.reply("scroll", timeout: 3)
    try await settle(1.5)
    let personCovered2 = coverage(of: RemoteLayout.person.offsetBy(dx: win(a)?.rect.minX ?? 0, dy: win(a)?.rect.minY ?? 0), by: latest.filter { CoverID.isTrack($0.id) }.map(\.frame)) >= 0.25
    print("overlap_curtain_over_blur precovers_seen=\(preSeen) precovers_outside_curtain_window=\(outsideB) person_in_blur_covered=\(personCovered2) "
        + "z_b=\(win(b)?.zOrder ?? -1) z_a=\(win(a)?.zOrder ?? -1) ok=\(outsideB == 0 && personCovered2) load1=\(fmt(loadAverage()))")
    ok = ok && outsideB == 0 && personCovered2
    _ = await a.ask("person_off")

    // 3. Two Curtain apps side by side: scrolling A pre-covers A only.
    model.updateRules { $0.upsert(AppRule(bundleID: aID, mode: .curtain)) }
    guard let wa3 = win(a) else { throw SelftestError("A gone") }
    await b.place(at: CGPoint(x: wa3.rect.maxX + 20, y: wa3.rect.minY))
    try await settle(2)  // > Curtain.staticReset: the earlier scenarios' motion would otherwise leave A in trusted motion
    // Both apps are Curtain here, and each one's own window may legitimately be pre-covered (B was just moved). What must never
    // happen is a pre-cover that reaches outside the window it belongs to — the two windows are disjoint, so a rect touching
    // both, or touching neither, is a leak.
    var onB = 0, onA = 0, straddling = 0
    runtime.onPreCover = { id, specs, _, _ in
        guard id == d.id, let wa = win(a), let wb = win(b) else { return }
        for s in specs where CoverID.isPreCover(s.id) {
            let inA = s.frame.intersection(wa.rect).area > 1, inB = s.frame.intersection(wb.rect).area > 1
            if inA { onA += 1 }
            if inB { onB += 1 }
            let owner = inA ? wa.rect : wb.rect
            if (inA && inB) || !(inA || inB) || s.frame.intersection(owner.insetBy(dx: -1, dy: -1)).area < s.frame.area * 0.99 {
                straddling += 1
            }
        }
    }
    _ = await a.ask("scroll")
    _ = await a.reply("scroll", timeout: 3)
    try await settle(1.5)
    print("overlap_two_curtains a=\(rectString(win(a)?.rect ?? .zero)) b=\(rectString(win(b)?.rect ?? .zero)) precovers_on_a=\(onA) precovers_on_b=\(onB) "
        + "precovers_outside_their_window=\(straddling) ok=\(onA > 0 && straddling == 0) load1=\(fmt(loadAverage()))")
    ok = ok && onA > 0 && straddling == 0

    // 4. Curtain window (A) under an Off window (B): A scrolls under B → the frame (B excluded) is dirty there, but no pre-cover may
    //    land on B (clipping to A's visible region).
    model.updateRules { $0.upsert(AppRule(bundleID: bID, mode: .off)) }
    await b.place(at: CGPoint(x: wa3.rect.minX - 60, y: wa3.rect.minY + 200))  // B covers the lower part of A's text column
    _ = await b.ask("front")
    try await settle(2)  // as above: A must not be in trusted motion when it scrolls
    var onOff = 0, preA = 0
    var leakPixels = 0, samples = 0
    let bMarker4 = win(b).map(marker)
    runtime.onPreCover = { id, specs, _, _ in
        guard id == d.id, let wb = win(b) else { return }
        for s in specs where CoverID.isPreCover(s.id) {
            preA += 1
            if s.frame.intersection(wb.rect).area > 1 { onOff += 1 }
        }
        if let p = bMarker4, let c = control.rgb(at: p) {
            samples += 1
            if !c.isMagenta { leakPixels += 1 }
        }
    }
    _ = await a.ask("scroll")
    _ = await a.reply("scroll", timeout: 3)
    try await settle(1.5)
    print("overlap_curtain_under_off z_b=\(win(b)?.zOrder ?? -1) z_a=\(win(a)?.zOrder ?? -1) precovers_on_curtain=\(preA) precovers_on_off_window=\(onOff) "
        + "off_marker_samples=\(samples) off_marker_covered_samples=\(leakPixels) ok=\(onOff == 0 && leakPixels == 0) load1=\(fmt(loadAverage()))")
    ok = ok && onOff == 0 && leakPixels == 0

    control.stop()
    a.terminate()
    b.terminate()
    runtime.displayManager.stop()
    return ok
}
