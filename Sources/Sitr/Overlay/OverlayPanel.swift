// M2-T10: one transparent, click-through NSPanel per display. Cover CALayers keyed by track id, diffed per frame inside one
// CATransaction with implicit animations off. Capture never sees it because the SCContentFilter excludes our process
// (`sharingType` stays default; see docs/spike/overlay.md).
import AppKit
import CoreVideo

/// Scroll displacement of one display over time: running sum of wheel deltas (display points, the direction content moves on
/// screen) with the time of each step. Keeps `window` seconds of steps (older ones fold into `base`), so it cannot grow.
nonisolated struct Odometer: Sendable {
    static let window = 3.0
    private var base = CGVector.zero
    private var steps: [(t: Double, total: CGVector)] = []

    mutating func add(dx: Double, dy: Double, at t: Double) {
        let last = steps.last?.total ?? base
        steps.append((t, CGVector(dx: last.dx + dx, dy: last.dy + dy)))
        if let cut = steps.firstIndex(where: { t - $0.t <= Self.window }), cut > 0 {
            base = steps[cut - 1].total
            steps.removeFirst(cut)
        }
    }

    func offset(at t: Double) -> CGVector { steps.last(where: { $0.t <= t })?.total ?? base }

    /// Every displacement reached after `t`, relative to the reading at `t`, as a box (dx from minX to maxX, dy likewise;
    /// always contains 0). A scroll that went down and came back keeps the whole way it went: the page may not have painted
    /// the way back yet.
    func reach(since t: Double) -> CGRect {
        let o = offset(at: t)
        var lo = CGPoint.zero, hi = CGPoint.zero
        for step in steps where step.t > t {
            lo = CGPoint(x: min(lo.x, step.total.dx - o.dx), y: min(lo.y, step.total.dy - o.dy))
            hi = CGPoint(x: max(hi.x, step.total.dx - o.dx), y: max(hi.y, step.total.dy - o.dy))
        }
        return CGRect(x: lo.x, y: lo.y, width: hi.x - lo.x, height: hi.y - lo.y)
    }
}

/// `rect` stretched over every scroll displacement in `reach` (`Odometer.reach`): the union of where its content was and
/// everywhere the scroll has carried it since, so a person in a scrolled page stays under their cover between detections and
/// one that does not scroll (a fixed header, a video in another window) stays covered too. `cap` bounds the stretch per side.
/// Pure; unit-tested.
// ponytail: stretch, never move — a moved cover would bare everything that does not scroll with the wheel. The cost is a cover
// up to `cap` longer than the person for the duration of one detection while scrolling.
nonisolated func scrollStretched(_ rect: CGRect, reach: CGRect, cap: Double = 600) -> CGRect {
    guard reach.width > 0 || reach.height > 0 else { return rect }
    let left = min(cap, max(0, -reach.minX)), right = min(cap, max(0, reach.maxX))
    let up = min(cap, max(0, -reach.minY)), down = min(cap, max(0, reach.maxY))
    return CGRect(x: rect.minX - left, y: rect.minY - up, width: rect.width + left + right, height: rect.height + up + down)
}

/// What the panel draws for one cover: `frame` in display-local points (origin top-left, y down), plus either blurred pixels as
/// an IOSurface-backed buffer at capture resolution or a solid color. Produced by `CoverRenderer`.
// ponytail: CVPixelBuffer is not Sendable; the renderer writes the buffer once and only readers touch it afterwards. Upgrade = actor-owned handle.
nonisolated struct CoverLayerSpec: @unchecked Sendable {
    let id: Int
    let frame: CGRect
    let contents: CVPixelBuffer?
    let color: CGColor?

    /// Same layer, same place, same pixels — nothing for `OverlayPanel.apply` to do. `contents` is compared by identity: the
    /// renderer hands out a fresh buffer per render, so the same object means the same surface, already on screen.
    func matches(_ other: CoverLayerSpec) -> Bool {
        id == other.id && frame == other.frame && contents === other.contents && color == other.color
    }
}

/// Display-local rect (origin top-left, y down) → CALayer rect inside a panel `displayHeight` points tall (origin bottom-left, y up).
nonisolated func appKitRect(_ r: CGRect, displayHeight: CGFloat) -> CGRect {
    CGRect(x: r.minX, y: displayHeight - r.maxY, width: r.width, height: r.height)
}

final class OverlayPanel: NSPanel {
    /// M4-T10: the panels that are open right now. Exactly one per managed display, through sleep/wake, lock, fast user
    /// switching and hot-plug, is the invariant; the unit tests and `--selftest robustness` read the count. `close()`
    /// unregisters, and `DisplayManager` never reuses a closed panel — a display that comes back gets a new one.
    private(set) static var open: Set<ObjectIdentifier> = []
    static var openCount: Int { open.count }

    private var covers: [Int: (layer: CALayer, buffer: CVPixelBuffer?)] = [:]
    /// Person covers as the pipeline placed them (display points), before the scroll stretch.
    private var placed: [Int: CGRect] = [:]
    /// This display's scroll history (`scrolled(dx:dy:at:)`), and per person cover the time its person was last seen in a
    /// captured frame: the cover is stretched over everything scrolled since.
    private var odometer = Odometer()
    private var seenAt: [Int: Double] = [:]
    private(set) var isRevealed = false
    var layerCount: Int { covers.count }
    /// Current cover frames by id in display-local points (the flip is its own inverse). Selftests read this; M3-T06 checks
    /// fail-closed covers follow a moving window with it.
    var coverFrames: [Int: CGRect] { covers.mapValues { appKitRect($0.layer.frame, displayHeight: frame.height) } }

    /// `screenFrame` = `NSScreen.frame` (global AppKit points).
    init(screenFrame: CGRect) {
        super.init(contentRect: screenFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        let view = NSView(frame: NSRect(origin: .zero, size: screenFrame.size))
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        view.setAccessibilityElement(false)
        contentView = view
        setAccessibilityElement(false)
        Self.open.insert(ObjectIdentifier(self))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func isAccessibilityElement() -> Bool { false }

    /// `isReleasedWhenClosed` is false, so a closed panel is still alive; this is what takes it out of `open`.
    override func close() {
        Self.open.remove(ObjectIdentifier(self))
        super.close()
    }

    /// Add / move / resize / recolor / remove so the layer set equals `specs`, in one transaction. Keeps each shown buffer
    /// alive (the layer only holds the IOSurface) so the renderer's pool cannot recycle a surface that is on screen.
    // M4-T09: every write here is guarded by a comparison, and a pass that changes nothing commits nothing. Re-assigning an
    // identical `contents` still marks the layer dirty, which damages the display — and the display is what we are capturing,
    // so an unconditional commit per frame made SCK deliver a `.complete` frame per commit and the pipeline ran on its own
    // output. `Pipeline.applyAll` skips the call entirely in that case; this is the second line of defence and covers the
    // partial case (one cover of five moved).
    /// `seen`: for the person covers whose person was detected in the frame behind this apply, that frame's capture time
    /// (`CACurrentMediaTime()` clock). Their scroll stretch restarts there; every other cover keeps the stretch it has, so an
    /// apply that only changes pre-covers, or a person missed for a frame, never pulls a stretched cover back.
    func apply(_ specs: [CoverLayerSpec], seen: [Int: Double] = [:]) {
        let displayHeight = frame.height
        let now = CACurrentMediaTime()
        for (id, t) in seen { seenAt[id] = t - Self.paintLag }
        guard let root = contentView?.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var seen = Set<Int>()
        var changed = false
        for spec in specs {
            seen.insert(spec.id)
            let layer: CALayer
            if let existing = covers[spec.id] {
                layer = existing.layer
            } else {
                layer = CALayer()
                layer.contentsGravity = .resize
                layer.isHidden = isRevealed
                root.addSublayer(layer)
                changed = true
            }
            var rect = spec.frame
            if CoverID.isTrack(spec.id) {
                placed[spec.id] = spec.frame
                if seenAt[spec.id] == nil { seenAt[spec.id] = now }
                rect = scrollStretched(rect, reach: odometer.reach(since: seenAt[spec.id] ?? now))
            }
            let target = appKitRect(rect, displayHeight: displayHeight)
            if layer.frame != target {
                layer.frame = target
                changed = true
            }
            if let buffer = spec.contents {
                if covers[spec.id]?.buffer !== buffer {
                    layer.contents = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue()
                    layer.backgroundColor = nil
                    changed = true
                }
            } else if layer.contents != nil || layer.backgroundColor != spec.color {
                layer.contents = nil
                layer.backgroundColor = spec.color
                changed = true
            }
            covers[spec.id] = (layer, spec.contents)
        }
        for (id, cover) in covers where !seen.contains(id) {
            cover.layer.removeFromSuperlayer()
            covers[id] = nil
            placed[id] = nil
            seenAt[id] = nil
            changed = true
        }
        CATransaction.commit()
        if changed { CATransaction.flush() }  // hand the frame to the render server now rather than at the end of the run-loop turn
    }

    /// The page under the pointer on this display scrolled by (dx, dy) points (main thread, per wheel and momentum step):
    /// stretch every person cover over the distance scrolled since its person was last seen, so covers keep up with the page
    /// between detections instead of trailing it by a frame of motion (the flicker of covers chasing a scrolled page).
    func scrolled(dx: Double, dy: Double, at t: Double = CACurrentMediaTime()) {
        odometer.add(dx: dx, dy: dy, at: t)
        restretch()
    }

    /// The pipeline saw these covers' people again in a newer frame, with nothing else to change: restart their stretch there.
    func rebase(seen: [Int: Double]) {
        for (id, t) in seen where placed[id] != nil { seenAt[id] = t - Self.paintLag }
        restretch()
    }

    private func restretch() {
        guard !placed.isEmpty else { return }
        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, rect) in placed {
            guard let layer = covers[id]?.layer else { continue }
            let target = appKitRect(scrollStretched(rect, reach: odometer.reach(since: seenAt[id] ?? now)), displayHeight: frame.height)
            if layer.frame != target { layer.frame = target }
        }
        CATransaction.commit()
        CATransaction.flush()
    }

    /// A frame's capture time is read this much earlier: the browser paints a wheel step a frame or two after the event and
    /// the frame callback lands after the capture, so the frame shows less scroll than the odometer had at callback time.
    /// Reading early only ever counts more scroll, which stretches more.
    // ponytail: fixed 50 ms; the upgrade is calibrating it against the measured motion of tracked boxes while scrolling.
    static let paintLag = 0.05

    /// Reveal Hold: hides every cover layer (new ones are added hidden) until `setRevealed(false)`.
    func setRevealed(_ revealed: Bool) {
        guard revealed != isRevealed else { return }
        isRevealed = revealed
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for cover in covers.values { cover.layer.isHidden = revealed }
        CATransaction.commit()
        CATransaction.flush()
    }
}
