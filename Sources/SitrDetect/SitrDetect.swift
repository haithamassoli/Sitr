/// Vision / CoreML / CoreImage wrappers. No AppKit so `sitr-bench` can link it.
import CoreGraphics
import CoreVideo
import SitrCore
import Vision

/// One detected region in capture pixels (top-left origin) with Vision's confidence.
public struct Detection: Hashable, Sendable {
    public var box: Rect
    public var confidence: Float

    public init(box: Rect, confidence: Float) {
        self.box = box
        self.confidence = confidence
    }

    init(_ normalized: NormalizedRect, confidence: Float, in size: Size) {
        let norm = Rect(x: normalized.origin.x, y: normalized.origin.y, width: normalized.width, height: normalized.height)
        self.init(box: norm.visionNormalizedToPixels(in: size), confidence: confidence)
    }
}

/// Persons and faces from one frame through a single `ImageRequestHandler`, so Vision prepares the image once.
public func detectPersonsAndFaces(
    in pixelBuffer: CVPixelBuffer, persons: PersonDetector, faces: FaceDetector
) async throws -> (persons: [Detection], faces: [Detection]) {
    let size = Size(width: Double(CVPixelBufferGetWidth(pixelBuffer)), height: Double(CVPixelBufferGetHeight(pixelBuffer)))
    let (humans, faceObs) = try await ImageRequestHandler(pixelBuffer).perform(persons.request, faces.request)
    return (
        humans.map { Detection($0.boundingBox, confidence: $0.confidence, in: size) },
        faceObs.map { Detection($0.boundingBox, confidence: $0.confidence, in: size) })
}

/// Which compute device Vision will use for a request. Sitr never calls `setComputeDevice`; Vision picks.
func computeNote(_ request: some VisionRequest) -> String {
    let main = request.computeDevice(for: .main).map { "\($0)" } ?? "nil (Vision picks)"
    let supported = request.supportedComputeStageDevices[.main]?.map { "\($0)" }.joined(separator: ",") ?? "?"
    return "main=\(main) supported=[\(supported)]"
}

extension CGImage {
    var sitrSize: Size { Size(width: Double(width), height: Double(height)) }
}

/// Pool of IOSurface-backed, Metal-compatible 32BGRA buffers of one size: CoreML image inputs that CoreImage renders into.
func bgraPool(width: Int, height: Int) throws -> CVPixelBufferPool {
    var pool: CVPixelBufferPool?
    let attributes: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true,
    ]
    guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess, let pool else {
        throw CoreMLDetectorError("cannot create the input pixel buffer pool")
    }
    return pool
}
