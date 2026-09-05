import CoreGraphics
import CoreVideo
import SitrCore
import Vision

/// Vision `DetectHumanRectanglesRequest`. Full body by default; `upperBodyOnly` trades box extent for recall on
/// partially visible people (spike M1-T06 measures both).
public struct PersonDetector: Sendable {
    var request: DetectHumanRectanglesRequest

    public init(upperBodyOnly: Bool = false) {
        request = DetectHumanRectanglesRequest()
        request.upperBodyOnly = upperBodyOnly
    }

    public var upperBodyOnly: Bool {
        get { request.upperBodyOnly }
        set { request.upperBodyOnly = newValue }
    }

    /// Boxes in pixels of `image`, top-left origin.
    public func detect(in image: CGImage) async throws -> [Detection] {
        try await request.perform(on: image).map { Detection($0.boundingBox, confidence: $0.confidence, in: image.sitrSize) }
    }

    /// Boxes in pixels of `pixelBuffer` (an SCStream BGRA frame), top-left origin.
    public func detect(in pixelBuffer: CVPixelBuffer) async throws -> [Detection] {
        let size = Size(width: Double(CVPixelBufferGetWidth(pixelBuffer)), height: Double(CVPixelBufferGetHeight(pixelBuffer)))
        return try await request.perform(on: pixelBuffer).map { Detection($0.boundingBox, confidence: $0.confidence, in: size) }
    }

    /// Compute device Vision reports for the main stage; for spike notes and debug logs.
    public var computeDeviceNote: String { computeNote(request) }
}
