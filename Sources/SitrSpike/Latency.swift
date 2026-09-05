// M1-T04: capture / Blur-path / Curtain-path latency. A rig window paints a frame counter as a row of black/white blocks
// (plus a person photo for the Blur and Curtain paths); the capture side decodes the counter, so every frame says which paint it shows.
import AppKit
import ScreenCaptureKit
import Vision

@MainActor
func runLatency(_ args: [String]) {
    if args.contains("--help") {
        print("usage: sitr-spike latency [--trials N=50] [--long-side PX=1280] [--fps N=15] [--only capture|blur|curtain]")
        exit(0)
    }
    let trials = option(args, "--trials", default: 50)
    let longSide = option(args, "--long-side", default: 1280)
    let fps = option(args, "--fps", default: 15)
    let only = option(args, "--only")
    let paths: [String] = ["capture", "blur", "curtain"].filter { only == nil || only == $0 }
    precondition(trials <= 255, "--trials must be ≤ 255")  // ponytail: 8 data blocks in the counter row; upgrade = more blocks
    Rig.boot()
    Rig.deadline(Double(trials * paths.count) * 2.6 + 30, "latency")
    Rig.run {
        let d = mainDisplayBounds()
        let stim = try Stimulus(origin: CGPoint(x: (d.width - 400) / 2, y: (d.height - 600) / 2))
        let geo = stim.geometry
        let content = try await RigStream.shareable()
        let stream = RigStream()
        try await stream.start(filter: SCContentFilter(display: RigStream.mainDisplay(content), excludingWindows: []), longSide: longSide, fps: fps)
        var it = stream.frames.makeAsyncIterator()

        // Warm-up: the row must decode as counter 0, or the geometry is off and every trial would miss. Also warms Vision (first call is cold).
        var warm = false
        let warmDeadline = CACurrentMediaTime() + 4
        while !warm, CACurrentMediaTime() < warmDeadline, let f = await it.next() {
            guard f.info.status == .complete, let pb = f.pixels else { continue }
            warm = geo.decode(pb) == 0
            if warm { _ = try await detectHuman(pb, within: geo.photoScreenRect) }
        }
        guard warm else { throw RigError("stimulus window not decodable from the capture (is it visible?)") }

        for path in paths {
            var lat: [Double] = []
            var missed = 0, detectCalls = 0
            for i in 1...trials {
                // Settle: wait for an idle frame (or 600 ms), then a random extra delay so paints are not phase-locked to the 15 Hz cadence.
                let settleDeadline = CACurrentMediaTime() + 0.6
                while CACurrentMediaTime() < settleDeadline, let f = await it.next() { if f.info.status == .idle { break } }
                try await Task.sleep(for: .milliseconds(100 + Int.random(in: 0..<70)))

                let tPaint = stim.paint(counter: i, photo: path != "capture")
                var hit: Double?
                let deadline = CACurrentMediaTime() + 2
                while hit == nil, CACurrentMediaTime() < deadline, let f = await it.next() {
                    guard f.info.status == .complete, let pb = f.pixels, geo.decode(pb) == i else { continue }
                    switch path {
                    case "capture":
                        hit = f.tCallback - tPaint
                    case "curtain":
                        guard !f.info.dirtyRects.isEmpty else { continue }
                        hit = stim.commitCover(geo.photoFrame) - tPaint  // dirty rect present → cover, no detection
                    default:
                        detectCalls += 1
                        guard let box = try await detectHuman(pb, within: geo.photoScreenRect) else { continue }
                        hit = stim.commitCover(geo.windowRect(fromScreen: box)) - tPaint
                    }
                }
                if let hit { lat.append(hit) } else { missed += 1 }
                stim.clear()
            }
            let extra = path == "blur" ? " detect_calls=\(detectCalls)" : ""
            print("\(path)_latency_ms p50=\(ms(percentile(lat, 0.5))) p95=\(ms(percentile(lat, 0.95))) n=\(lat.count) missed=\(missed)\(extra)")
        }
        await stream.stop()
        print("latency_config long_side=\(longSide) fps=\(fps) trials=\(trials) display_pt=\(Int(d.width))x\(Int(d.height))")
        Rig.finish(0)
    }
}

/// Largest full-body human rectangle intersecting `region` (screen points), or nil.
func detectHuman(_ pb: CVPixelBuffer, within region: CGRect) async throws -> CGRect? {
    var request = DetectHumanRectanglesRequest()
    request.upperBodyOnly = false
    let d = mainDisplayBounds()
    let boxes = try await request.perform(on: pb).map { o -> CGRect in
        let b = o.boundingBox  // normalized, lower-left origin == AppKit screen convention for a full-display frame
        return CGRect(x: b.origin.x * d.width, y: b.origin.y * d.height, width: b.width * d.width, height: b.height * d.height)
    }
    return boxes.filter { $0.intersects(region) }.max { $0.width * $0.height < $1.width * $1.height }
}

/// Window geometry shared with the (nonisolated) decode side. Screen coords are AppKit points, origin bottom-left.
struct StimulusGeometry: Sendable {
    let windowFrame: CGRect
    let block: CGFloat
    let blocks: Int
    /// Photo region in window coordinates (below the counter row).
    let photoFrame: CGRect
    var photoScreenRect: CGRect { photoFrame.offsetBy(dx: windowFrame.minX, dy: windowFrame.minY) }

    /// Block 0 always white, last block always black, the rest = counter bits MSB first.
    func bit(_ i: Int, of counter: Int) -> Bool {
        if i == 0 { return true }
        if i == blocks - 1 { return false }
        return (counter >> (blocks - 2 - i)) & 1 == 1
    }

    /// Reads the counter row back from a full-display frame; nil when the marker blocks do not match.
    func decode(_ pb: CVPixelBuffer) -> Int? {
        var value = 0
        for i in 0..<blocks {
            let pt = CGPoint(x: windowFrame.minX + (CGFloat(i) + 0.5) * block, y: windowFrame.minY + photoFrame.height + block / 2)
            let (x, y) = capturePixel(pt, in: pb)
            guard let c = sampleRGB(pb, x: x, y: y) else { return nil }
            let white = (c.r + c.g + c.b) / 3 > 128
            if i == 0 || i == blocks - 1 { if white != bit(i, of: 0) { return nil } } else if white { value |= 1 << (blocks - 2 - i) }
        }
        return value
    }

    func windowRect(fromScreen r: CGRect) -> CGRect {
        r.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY).intersection(CGRect(origin: .zero, size: windowFrame.size))
    }
}

/// The stimulus window: counter row on top, photo region below, one cover layer.
@MainActor
final class Stimulus {
    let geometry: StimulusGeometry
    private let bits: [CALayer]
    private let photo = CALayer()
    private let cover = CALayer()

    init(origin: CGPoint) throws {
        let block: CGFloat = 40, blocks = 10
        let photoFrame = CGRect(x: 0, y: 0, width: block * CGFloat(blocks), height: 560)
        let frame = NSRect(x: origin.x, y: origin.y, width: photoFrame.width, height: photoFrame.height + block)
        geometry = StimulusGeometry(windowFrame: frame, block: block, blocks: blocks, photoFrame: photoFrame)
        let panel = Rig.panel(frame, level: .screenSaver, color: .white)
        panel.ignoresMouseEvents = true
        let root = panel.contentView!.layer!
        bits = (0..<blocks).map { i in
            let l = CALayer()
            l.frame = CGRect(x: CGFloat(i) * block, y: photoFrame.height, width: block, height: block)
            root.addSublayer(l)
            return l
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/person.jpg")
        guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw RigError("fixture missing: \(url.path)")
        }
        photo.contents = image
        photo.contentsGravity = .resizeAspect
        photo.frame = photoFrame
        photo.isHidden = true
        root.addSublayer(photo)
        cover.backgroundColor = NSColor.systemGray.cgColor
        cover.isHidden = true
        root.addSublayer(cover)
        panel.orderFrontRegardless()
        _ = paint(counter: 0, photo: false)
    }

    /// Writes `counter` into the row, shows/hides the photo, hides the cover; one transaction, flushed. Returns the commit time.
    func paint(counter: Int, photo show: Bool) -> Double {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, l) in bits.enumerated() { l.backgroundColor = geometry.bit(i, of: counter) ? NSColor.white.cgColor : NSColor.black.cgColor }
        photo.isHidden = !show
        cover.isHidden = true
        CATransaction.commit()
        CATransaction.flush()
        return CACurrentMediaTime()
    }

    /// Cover commit in one flushed CATransaction (window coords). Returns the commit time.
    func commitCover(_ r: CGRect) -> Double {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cover.frame = r
        cover.isHidden = false
        CATransaction.commit()
        CATransaction.flush()
        return CACurrentMediaTime()
    }

    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        photo.isHidden = true
        cover.isHidden = true
        CATransaction.commit()
        CATransaction.flush()
    }
}
