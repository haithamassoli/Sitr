import CoreGraphics
import CoreVideo
import SitrCore
import Vision

/// Vision `DetectFaceRectanglesRequest`. Faces feed the gender classifier (M2-T07) and are assigned to person boxes.
public struct FaceDetector: Sendable {
    var request = DetectFaceRectanglesRequest()

    public init() {}

    /// Boxes in pixels of `image`, top-left origin.
    public func detect(in image: CGImage) async throws -> [Detection] {
        try await request.perform(on: image).map { Detection($0.boundingBox, confidence: $0.confidence, in: image.sitrSize) }
    }

    /// Boxes in pixels of `pixelBuffer` (an SCStream BGRA frame), top-left origin.
    public func detect(in pixelBuffer: CVPixelBuffer) async throws -> [Detection] {
        let size = Size(width: Double(CVPixelBufferGetWidth(pixelBuffer)), height: Double(CVPixelBufferGetHeight(pixelBuffer)))
        return try await request.perform(on: pixelBuffer).map { Detection($0.boundingBox, confidence: $0.confidence, in: size) }
    }

    public var computeDeviceNote: String { computeNote(request) }
}
