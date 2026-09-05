// M2-T05: one captured frame as a value. Pixels stay in memory; nothing here writes or logs them.
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import SitrCore

/// One `.complete` SCStream frame of one display. Coordinate helpers map buffer pixels ↔ display-local points (both origin
/// top-left) with buffer size ÷ display size in points, the mapping the spike verified (never `contentScale`; docs/spike/capture.md).
// ponytail: CVPixelBuffer is not Sendable. SCK hands over an immutable IOSurface-backed buffer and recycles it only when
// every reference is gone, so passing the value between the pipeline actor and the main actor is safe. Upgrade = actor-owned pool.
nonisolated struct Frame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let displayID: CGDirectDisplayID
    /// Monotonic per display for the life of its `CaptureSession` (survives stream restarts).
    let sequence: Int
    /// `CACurrentMediaTime()` at entry of the `SCStreamOutput` callback.
    let timestamp: Double
    /// Changed regions since the previous frame, in **capture buffer pixels** (origin top-left) — SCK reports dirty rects in
    /// pixels while `contentRect` is in points (verified against the SDK header and live: a full-frame dirty rect is the whole
    /// 1280×832 buffer, not the 640×416 content rect). Use `dirtyRectsInDisplayPoints` for the Curtain/window space.
    let dirtyRects: [CGRect]
    /// Location and size of the captured content in points (SCK `contentRect`); its origin is 0 for a full-display capture.
    let contentRect: CGRect
    let scaleFactor: Double
    let contentScale: Double
    /// The captured display in points (`SCDisplay.width/height`, equals `CGDisplayBounds` size).
    let displaySize: CGSize

    var width: Int { CVPixelBufferGetWidth(pixelBuffer) }
    var height: Int { CVPixelBufferGetHeight(pixelBuffer) }
    var pixelSize: Size { Size(width: Double(width), height: Double(height)) }

    /// Display points per buffer pixel (1470 pt ÷ 1280 px = 1.148 on the spike machine).
    var pointsPerPixel: Double { displaySize.width / Double(width) }
    /// Buffer pixels per display point: the `scaleFactor` argument `Geometry` expects.
    var pixelsPerPoint: Double { Double(width) / displaySize.width }

    /// Capture pixels → display-local points.
    func pixelsToDisplayPoints(_ r: Rect) -> Rect {
        r.pixelsToDisplayPoints(scaleFactor: pixelsPerPoint, contentRect: Rect(x: 0, y: 0, width: displaySize.width, height: displaySize.height))
    }

    /// Display-local points → capture pixels.
    func displayPointsToPixels(_ r: Rect) -> Rect {
        let k = pixelsPerPoint
        return Rect(x: r.x * k, y: r.y * k, width: r.width * k, height: r.height * k)
    }

    func pixelsToDisplayPoints(_ r: CGRect) -> CGRect { CGRect(pixelsToDisplayPoints(Rect(r))) }
    func displayPointsToPixels(_ r: CGRect) -> CGRect { CGRect(displayPointsToPixels(Rect(r))) }

    /// `dirtyRects` mapped from buffer pixels to display-local points (what Curtain window tiling and the overlay want).
    var dirtyRectsInDisplayPoints: [CGRect] { dirtyRects.map { pixelsToDisplayPoints($0) } }
}

nonisolated extension Rect {
    init(_ r: CGRect) { self.init(x: r.minX, y: r.minY, width: r.width, height: r.height) }
}

nonisolated extension CGRect {
    init(_ r: Rect) { self.init(x: r.x, y: r.y, width: r.width, height: r.height) }
}

/// The per-frame attachments SCK puts on the sample buffer (lifted from the spike's `FrameInfo`).
nonisolated struct FrameAttachments {
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
        scaleFactor = a[.scaleFactor] as? Double ?? 1
        contentScale = a[.contentScale] as? Double ?? 1
    }
}
