import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import SitrCore
import Testing
@testable import SitrDetect

// Same fixture and hand-checked body box as DetectorTests.swift (Fixtures/person.jpg, 640x426, CC0).
private let handCheckedBody = Rect(x: 262, y: 112, width: 123, height: 314)
private let fixtureSize = Size(width: 640, height: 426)
// The shipped model is built by Models/detector/convert_yolox.py --dist; without it these tests skip, not fail.
private let modelURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Models/dist/PersonDetector.mlpackage")
private let modelPresent = FileManager.default.fileExists(atPath: modelURL.path)
private let missing: Comment = "Models/dist/PersonDetector.mlpackage missing; run Models/detector/convert_yolox.py --dist"

private func fixture() throws -> CGImage {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/person.jpg")
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
}

/// Every edge within 5 % of the image's corresponding dimension.
private func within5Percent(_ a: Rect, _ b: Rect) -> Bool {
    let dx = 0.05 * fixtureSize.width, dy = 0.05 * fixtureSize.height
    return abs(a.minX - b.minX) <= dx && abs(a.maxX - b.maxX) <= dx && abs(a.minY - b.minY) <= dy && abs(a.maxY - b.maxY) <= dy
}

@Test(.enabled(if: modelPresent, missing))
func shippedModelFindsThePerson() async throws {
    let detector = try await CoreMLPersonDetector(contentsOf: modelURL)
    let detections = try await detector.detect(in: try fixture())
    let best = try #require(detections.max { $0.confidence < $1.confidence })
    #expect(within5Percent(best.box, handCheckedBody), "got \(best.box)")
    #expect(best.confidence > 0.5)
    #expect(!detections.contains { $0 != best && $0.box.iou(best.box) > detector.nmsIoU }, "NMS left a duplicate: \(detections)")
}

@Test(.enabled(if: modelPresent, missing))
func coreMLPixelBufferPathMatchesCGImagePath() async throws {
    let image = try fixture()
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, nil, &buffer)
    let pb = try #require(buffer)
    CVPixelBufferLockBaseAddress(pb, [])
    let ctx = try #require(CGContext(
        data: CVPixelBufferGetBaseAddress(pb), width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    CVPixelBufferUnlockBaseAddress(pb, [])
    let detector = try await CoreMLPersonDetector(contentsOf: modelURL, computeUnits: .cpuAndNeuralEngine)
    let a = try #require(try await detector.detect(in: pb).max { $0.confidence < $1.confidence })
    let b = try #require(try await detector.detect(in: image).max { $0.confidence < $1.confidence })
    #expect(a.box.iou(b.box) > 0.9, "buffer \(a.box) vs image \(b.box)")
}

@Test func nmsKeepsTheBestOfOverlappingBoxesOnly() {
    let a = Detection(box: Rect(x: 0, y: 0, width: 100, height: 200), confidence: 0.9)
    let b = Detection(box: Rect(x: 5, y: 5, width: 100, height: 200), confidence: 0.8)  // IoU ~0.9 with a
    let c = Detection(box: Rect(x: 300, y: 0, width: 100, height: 200), confidence: 0.4)  // disjoint
    #expect(CoreMLPersonDetector.nms([b, c, a], iou: 0.5) == [a, c])
}
