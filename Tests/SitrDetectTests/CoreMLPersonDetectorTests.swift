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

// M4-T09: the frame is resampled into the network canvas with Lanczos only where it is really being reduced
// (`lanczosBelow`); above that the affine transform's bilinear tap is used, which is what the app hits — it captures at the
// model's long side, so the scale factor is ~0.92. The two paths must agree on the same picture, or the shortcut changed
// what the detector sees. `sitr-bench --lanczos-below 0 | 2` measures the same thing over 199 COCO photos (docs/perf.md:
// 84.7 % recall never, 84.5 % always, 84.6 % shipped).
@Test(.enabled(if: modelPresent, missing))
func bothResamplePathsSeeTheSamePerson() async throws {
    var detector = try await CoreMLPersonDetector(contentsOf: modelURL)
    let image = try fixture()
    detector.lanczosBelow = 2  // always Lanczos: the pre-M4-T09 path
    let lanczos = try await detector.detect(in: image)
    detector.lanczosBelow = 0  // never Lanczos: past anything the app asks for
    let affine = try await detector.detect(in: image)
    let a = try #require(lanczos.max { $0.confidence < $1.confidence })
    let b = try #require(affine.max { $0.confidence < $1.confidence })
    #expect(within5Percent(a.box, b.box), "lanczos \(a.box) vs affine \(b.box)")
    #expect(abs(Double(a.confidence - b.confidence)) < 0.1, "confidence \(a.confidence) vs \(b.confidence)")
    #expect(lanczos.count == affine.count, "\(lanczos.count) boxes vs \(affine.count)")
}
