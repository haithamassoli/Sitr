// Shared plumbing for the sitr-spike rigs: args, NSApplication bootstrap + hard deadline,
// one SCStream wrapper (frames land in an AsyncStream), pixel sampling, percentiles.
import AppKit
import ScreenCaptureKit
import Synchronization

// MARK: - args

func option(_ args: [String], _ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func option(_ args: [String], _ name: String, default d: Double) -> Double { option(args, name).flatMap(Double.init) ?? d }
func option(_ args: [String], _ name: String, default d: Int) -> Int { option(args, name).flatMap(Int.init) ?? d }

// MARK: - app lifetime

@MainActor
enum Rig {
    private static var windows: [NSWindow] = []

    /// Accessory app: no Dock icon, no menu bar takeover; windows still show. Call once before creating windows.
    static func boot() { NSApplication.shared.setActivationPolicy(.accessory) }

    static func track(_ w: NSWindow) {
        w.isReleasedWhenClosed = false
        windows.append(w)
    }

    /// Removes every window the rig created and exits. Idempotent; process exit also tears down any SCStream.
    static func finish(_ code: Int32 = 0) -> Never {
        for w in windows { w.orderOut(nil); w.close() }
        windows.removeAll()
        exit(code)
    }

    /// Hard deadline: cleanup + exit even if the rig logic hangs; a second backstop fires even if the main thread is stuck.
    static func deadline(_ seconds: Double, _ rig: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated { print("\(rig): hard deadline of \(seconds)s hit, cleaning up"); finish(1) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds + 5) { exit(1) }
    }

    /// Runs `body` on the main actor under NSApplication.run(). `body` ends the process via finish().
    static func run(_ body: @escaping @MainActor () async throws -> Void) -> Never {
        Task { @MainActor in
            do { try await body() } catch { print("error: \(error)"); finish(1) }
        }
        NSApplication.shared.run()
        fatalError("NSApplication.run returned")
    }

    /// Borderless non-activating panel that joins all Spaces. `color` nil = fully transparent content.
    static func panel(_ frame: NSRect, level: NSWindow.Level, color: NSColor?) -> NSPanel {
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = level
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let v = NSView(frame: NSRect(origin: .zero, size: frame.size))
        v.wantsLayer = true
        v.layer?.backgroundColor = color?.cgColor
        p.contentView = v
        track(p)
        return p
    }
}

/// Main display bounds in points (origin top-left, CoreGraphics convention). Safe off the main actor.
func mainDisplayBounds() -> CGRect { CGDisplayBounds(CGMainDisplayID()) }

// MARK: - frames

struct FrameInfo: Sendable {
    var status: SCFrameStatus
    var dirtyRects: [CGRect]
    var contentRect: CGRect
    var scaleFactor: Double
    var contentScale: Double

    init?(_ sb: CMSampleBuffer) {
        guard let a = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = a[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return nil }
        self.status = status
        dirtyRects = ((a[.dirtyRects] as? [Any]) ?? []).compactMap { ($0 as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } }
        contentRect = (a[.contentRect] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
        scaleFactor = a[.scaleFactor] as? Double ?? 0
        contentScale = a[.contentScale] as? Double ?? 0
    }
}

/// One frame as delivered (idle ones included: they keep consumers ticking on a static screen; check `info.status`).
// ponytail: CMSampleBuffer is not marked Sendable by the SDK but is immutable once delivered; upgrade = wrap pixels in our own Frame value (M2-T05).
struct Frame: @unchecked Sendable {
    let buffer: CMSampleBuffer
    let info: FrameInfo
    /// CACurrentMediaTime() at callback entry.
    let tCallback: Double
    var pixels: CVPixelBuffer? { buffer.imageBuffer }
}

struct StreamStats: Sendable {
    var complete = 0, idle = 0, other = 0, dirty = 0
    var size = CGSize.zero
    var contentRect = CGRect.zero
    var scaleFactor = 0.0, contentScale = 0.0
}

/// SCStream on one display with the PRD configuration. Counts every frame in `stats`; yields every frame into `frames`.
final class RigStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let frames: AsyncStream<Frame>
    private let sink: AsyncStream<Frame>.Continuation
    let stats = Mutex(StreamStats())
    private let queue = DispatchQueue(label: "sitr.spike.stream")
    private var stream: SCStream?

    /// `.bufferingNewest(n)` = drop-oldest backpressure like the product pipeline; `.unbounded` to see every frame.
    init(buffering: AsyncStream<Frame>.Continuation.BufferingPolicy = .bufferingNewest(2)) {
        (frames, sink) = AsyncStream.makeStream(of: Frame.self, bufferingPolicy: buffering)
        super.init()
    }

    static func shareable() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    }
    static func mainDisplay(_ content: SCShareableContent) -> SCDisplay {
        content.displays.first { $0.displayID == CGMainDisplayID() } ?? content.displays[0]
    }

    /// BGRA, minimumFrameInterval 1/`fps` s, queueDepth 3, no cursor; output scaled so the long side is `longSide` px (0 = native).
    @MainActor  // callers hand over a non-Sendable SCContentFilter; keep the call on the caller's actor
    func start(filter: SCContentFilter, longSide: Int = 1280, fps: Int = 15) async throws {
        let cfg = SCStreamConfiguration()
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.queueDepth = 3
        cfg.showsCursor = false
        let native = CGSize(width: filter.contentRect.width * Double(filter.pointPixelScale),
                            height: filter.contentRect.height * Double(filter.pointPixelScale))
        let k = longSide == 0 ? 1 : min(1, Double(longSide) / max(native.width, native.height))
        cfg.width = Int(native.width * k)
        cfg.height = Int(native.height * k)
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    @MainActor
    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        let t = CACurrentMediaTime()
        guard type == .screen, let info = FrameInfo(sb) else { return }
        stats.withLock { s in
            switch info.status {
            case .complete: s.complete += 1
            case .idle: s.idle += 1
            default: s.other += 1
            }
            s.dirty += info.dirtyRects.count
            if let pb = sb.imageBuffer { s.size = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb)) }
            s.contentRect = info.contentRect
            s.scaleFactor = info.scaleFactor
            s.contentScale = info.contentScale
        }
        sink.yield(Frame(buffer: sb, info: info, tCallback: t))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("stream stopped with error: \(error.localizedDescription)")
    }
}

// MARK: - pixels

/// Screen point (AppKit, origin bottom-left of the main display) → pixel in a full-main-display frame (origin top-left).
func capturePixel(_ pt: CGPoint, in pb: CVPixelBuffer) -> (x: Int, y: Int) {
    let d = mainDisplayBounds()
    let sx = Double(CVPixelBufferGetWidth(pb)) / d.width, sy = Double(CVPixelBufferGetHeight(pb)) / d.height
    return (Int(pt.x * sx), Int((d.height - pt.y) * sy))
}

/// Mean RGB (0–255) over the (2r+1)² block centred on (x, y) of a BGRA buffer; nil when out of bounds. Never stores or logs pixels.
func sampleRGB(_ pb: CVPixelBuffer, x: Int, y: Int, r: Int = 2) -> (r: Int, g: Int, b: Int)? {
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
            sb += Int(p[o]); sg += Int(p[o + 1]); sr += Int(p[o + 2])
        }
    }
    let n = (2 * r + 1) * (2 * r + 1)
    return (sr / n, sg / n, sb / n)
}

func isRed(_ c: (r: Int, g: Int, b: Int)) -> Bool { c.r > 180 && c.g < 80 && c.b < 80 }
func isBlue(_ c: (r: Int, g: Int, b: Int)) -> Bool { c.b > 180 && c.r < 80 && c.g < 80 }
func rgbString(_ c: (r: Int, g: Int, b: Int)?) -> String { c.map { "(\($0.r),\($0.g),\($0.b))" } ?? "n/a" }

struct RigError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - numbers

func percentile(_ v: [Double], _ p: Double) -> Double {
    let s = v.sorted()
    guard !s.isEmpty else { return .nan }
    return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
}
func ms(_ seconds: Double) -> String { String(format: "%.1f", seconds * 1000) }
func rectString(_ r: CGRect) -> String { "(\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height)))" }
