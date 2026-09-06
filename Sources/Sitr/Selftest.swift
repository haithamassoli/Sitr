// `Sitr --selftest [capture|overlay|render|pipeline|category|failstate|lowpower|degraded|stimulus] [options]`: automated checks
// for M2 track A (capture, overlay, renderer), the pipeline / fail-state glue (M2-T12, M2-T16), the category wiring (M2-T07),
// Low Power Mode (M4-T06) and the degraded state (M4-T07). Each subcommand prints one parseable
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
            Harness.run("failstate", deadline: 90) { try await failstateTest() }
        case "lowpower":
            Harness.run("lowpower", deadline: 120) { try await lowPowerTest() }
        case "degraded":
            Harness.run("degraded", deadline: 120) { try await degradedTest() }
        case "stimulus":
            let seconds = option(args, "--seconds", default: 30.0)
            Harness.run("stimulus", deadline: seconds + 15) { try await stimulusOnly(seconds: seconds) }
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

/// The real app wiring (`Runtime`) on a throwaway preferences suite (Everyone + Strict, FR3 defaults). The production filter
/// excludes our whole process, which would hide the selftest's own stimulus window from capture, so once the main display's
/// session runs its filter is swapped for one excluding only the overlay panel(s) — the feedback-loop guard stays.
@MainActor
private func bootRuntime() async throws -> (runtime: Runtime, display: ManagedDisplay, pipeline: Pipeline) {
    let suite = "com.goldentik.Sitr.selftest"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let runtime = Runtime(model: AppModel(preferences: Preferences(defaults: defaults)))
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
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first(where: { $0.displayID == mainID }) else { throw SelftestError("display not in SCShareableContent") }
            let panelIDs = Set(runtime.displayManager.displays.map { CGWindowID($0.panel.windowNumber) })
            let excluded = content.windows.filter { panelIDs.contains($0.windowID) }
            try await d.session.updateFilter(SCContentFilter(display: display, excludingWindows: excluded))
            print("pipeline_boot display=\(mainID) displays=\(runtime.displayManager.displays.count) pipelines=\(runtime.pipelines.count) "
                + "boot_ms=\(Int((CACurrentMediaTime() - t0) * 1000)) excluded_panel_windows=\(excluded.count)/\(panelIDs.count) "
                + "health=\(runtime.model.policy.health) \(runtime.modelsNote)")
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

    /// A repo-relative image, e.g. `Tests/SitrDetectTests/Fixtures/woman.jpg` (dev checkout only).
    static func fixture(_ path: String) throws -> CGImage {
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
    runtime.displayManager.stop()
    // Correctness always gates; the p95 target only on a quiet machine (other agents' GPU/ANE load stalls Vision and Core Image).
    return exposures.count >= trials * 9 / 10 && controlOK && notCleared == 0 && (noisy || p95 <= 0.150)
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
private func failstateTest() async throws -> Bool {
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
    let flipped = await waitUntil(5) { model.policy.health == .needsPermission }
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
    stim.show(false)
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

/// Dev stimulus for a manual run of the real app from another shell: the person photo drifting for `seconds` (frames keep flowing),
/// then exit. No pipeline here — the app under test is the other process, which is why its own-process exclusion does not hide it.
@MainActor
private func stimulusOnly(seconds: Double) async throws -> Bool {
    guard let screen = NSScreen.screens.first else { throw SelftestError("no screen") }
    let stim = try Stimulus(display: screen.frame.size, motion: true)
    stim.show(true)
    print("stimulus panel=\(rectString(stim.rect)) seconds=\(Int(seconds))")
    let start = CACurrentMediaTime()
    while CACurrentMediaTime() - start < seconds {
        stim.move(t: (CACurrentMediaTime() - start) * 0.25)  // slow drift: a few points per frame
        try await Task.sleep(for: .milliseconds(66))
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

    static func track(_ w: NSWindow) {
        w.isReleasedWhenClosed = false
        windows.append(w)
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
