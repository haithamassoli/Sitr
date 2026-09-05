// M2-T10: one transparent, click-through NSPanel per display. Cover CALayers keyed by track id, diffed per frame inside one
// CATransaction with implicit animations off. Capture never sees it because the SCContentFilter excludes our process
// (`sharingType` stays default; see docs/spike/overlay.md).
import AppKit
import CoreVideo

/// What the panel draws for one cover: `frame` in display-local points (origin top-left, y down), plus either blurred pixels as
/// an IOSurface-backed buffer at capture resolution or a solid color. Produced by `CoverRenderer`.
// ponytail: CVPixelBuffer is not Sendable; the renderer writes the buffer once and only readers touch it afterwards. Upgrade = actor-owned handle.
nonisolated struct CoverLayerSpec: @unchecked Sendable {
    let id: Int
    let frame: CGRect
    let contents: CVPixelBuffer?
    let color: CGColor?
}

/// Display-local rect (origin top-left, y down) → CALayer rect inside a panel `displayHeight` points tall (origin bottom-left, y up).
nonisolated func appKitRect(_ r: CGRect, displayHeight: CGFloat) -> CGRect {
    CGRect(x: r.minX, y: displayHeight - r.maxY, width: r.width, height: r.height)
}

final class OverlayPanel: NSPanel {
    private var covers: [Int: (layer: CALayer, buffer: CVPixelBuffer?)] = [:]
    private(set) var isRevealed = false
    var layerCount: Int { covers.count }

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
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func isAccessibilityElement() -> Bool { false }

    /// Add / move / resize / recolor / remove so the layer set equals `specs`, in one transaction. Keeps each shown buffer
    /// alive (the layer only holds the IOSurface) so the renderer's pool cannot recycle a surface that is on screen.
    func apply(_ specs: [CoverLayerSpec]) {
        let displayHeight = frame.height
        guard let root = contentView?.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var seen = Set<Int>()
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
            }
            let target = appKitRect(spec.frame, displayHeight: displayHeight)
            if layer.frame != target { layer.frame = target }
            if let buffer = spec.contents {
                layer.contents = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue()
                layer.backgroundColor = nil
            } else {
                layer.contents = nil
                layer.backgroundColor = spec.color
            }
            covers[spec.id] = (layer, spec.contents)
        }
        for (id, cover) in covers where !seen.contains(id) {
            cover.layer.removeFromSuperlayer()
            covers[id] = nil
        }
        CATransaction.commit()
        CATransaction.flush()  // hand the frame to the render server now rather than at the end of the run-loop turn
    }

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
