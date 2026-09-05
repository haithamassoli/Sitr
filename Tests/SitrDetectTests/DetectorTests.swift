import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import SitrCore
import Testing
@testable import SitrDetect

// Fixtures/person.jpg: 640x426, one woman standing in a field (CC0, see Fixtures/ATTRIBUTION.md).
// Hand-checked body box in pixels, top-left origin: hair top to the bottom edge (feet are cut off), hand to hand.
private let handCheckedBody = Rect(x: 262, y: 112, width: 123, height: 314)
private let fixtureSize = Size(width: 640, height: 426)

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

@Test func fullBodyDetectorFindsThePerson() async throws {
    let image = try fixture()
    #expect(image.width == 640 && image.height == 426)
    let detections = try await PersonDetector().detect(in: image)
    let best = try #require(detections.max { $0.box.area < $1.box.area })
    #expect(within5Percent(best.box, handCheckedBody), "got \(best.box)")
    #expect(best.confidence > 0.5)
}

@Test func upperBodyDetectorBoxSitsInsideTheBody() async throws {
    let detections = try await PersonDetector(upperBodyOnly: true).detect(in: try fixture())
    let best = try #require(detections.max { $0.box.area < $1.box.area })
    #expect(handCheckedBody.contains(x: best.box.midX, y: best.box.midY))
    #expect(best.box.midY < handCheckedBody.midY, "upper body center should be in the top half, got \(best.box)")
}

@Test func faceDetectorFindsTheFaceInTheUpperBody() async throws {
    let faces = try await FaceDetector().detect(in: try fixture())
    let face = try #require(faces.first)
    #expect(handCheckedBody.contains(x: face.box.midX, y: face.box.midY))
    #expect(face.box.midY < handCheckedBody.minY + handCheckedBody.height / 3, "face should be in the top third, got \(face.box)")
    #expect(face.box.height > 25 && face.box.height < 90, "face height \(face.box.height)")
}

@Test func pixelBufferPathMatchesCGImagePath() async throws {
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
    let fromBuffer = try await PersonDetector().detect(in: pb)
    let fromImage = try await PersonDetector().detect(in: image)
    let a = try #require(fromBuffer.max { $0.box.area < $1.box.area })
    let b = try #require(fromImage.max { $0.box.area < $1.box.area })
    let message = "buffer \(a.box) vs image \(b.box)"
    #expect(a.box.iou(b.box) > 0.9, Comment(rawValue: message))
}

@Test func computeDeviceNoteIsInformative() {
    let note = PersonDetector().computeDeviceNote
    #expect(note.contains("main=") && note.contains("supported="))
}
