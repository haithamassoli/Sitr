// M2-T07: the shipped face-gender model on two CC0 portraits with known labels (Fixtures/ATTRIBUTION.md), through the exact crop
// rule and both input paths (CGImage, BGRA pixel buffer like an SCStream frame). The model (Models/dist/GenderClassifier.mlpackage,
// 86 MB int8 ViT) is compiled once per machine into the temp dir; without it the model tests skip, not fail.
import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import ImageIO
import SitrCore
import Testing

@testable import SitrDetect

private let packageURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Models/dist/GenderClassifier.mlpackage")
private let modelPresent = FileManager.default.fileExists(atPath: packageURL.path)
private let missing: Comment = "Models/dist/GenderClassifier.mlpackage missing; see Models/README.md"

/// `MLModel.compileModel` (~0.6 s) once per package version: the output is moved to a temp path keyed by the manifest's mtime.
private func compiledModel() async throws -> URL {
    let manifest = packageURL.appendingPathComponent("Manifest.json").path
    let stamp = ((try? FileManager.default.attributesOfItem(atPath: manifest))?[.modificationDate] as? Date).map { Int($0.timeIntervalSince1970) } ?? 0
    let cached = FileManager.default.temporaryDirectory.appendingPathComponent("SitrTests-GenderClassifier-\(stamp).mlmodelc")
    if !FileManager.default.fileExists(atPath: cached.path) {
        try FileManager.default.moveItem(at: try await MLModel.compileModel(at: packageURL), to: cached)
    }
    return cached
}

/// One loaded classifier for the suite (the tests run serialized).
private actor Shared {
    static let shared = Shared()
    private var classifier: GenderClassifier?

    func classifier() async throws -> GenderClassifier {
        if let classifier { return classifier }
        let c = try await GenderClassifier(contentsOf: compiledModel())
        classifier = c
        return c
    }
}

private func fixture(_ name: String) throws -> CGImage {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).jpg")
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
}

/// The fixture and its single Vision face (capture pixels, top-left origin).
private func fixtureFace(_ name: String) async throws -> (image: CGImage, face: Rect) {
    let image = try fixture(name)
    let faces = try await FaceDetector().detect(in: image)
    try #require(faces.count == 1, "expected one face in \(name).jpg, got \(faces.count)")
    return (image, faces[0].box)
}

/// Draws `images` side by side into one BGRA buffer (an SCStream-like frame); returns the buffer and each image's x offset.
private func frame(_ images: [CGImage]) throws -> (buffer: CVPixelBuffer, offsets: [Double]) {
    let width = images.reduce(0) { $0 + $1.width }, height = images.map(\.height).max() ?? 1
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
    let pb = try #require(buffer)
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    let ctx = try #require(CGContext(
        data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
    var x = 0, offsets: [Double] = []
    for image in images {  // CGContext's origin is bottom-left: top-align each image
        ctx.draw(image, in: CGRect(x: x, y: height - image.height, width: image.width, height: image.height))
        offsets.append(Double(x))
        x += image.width
    }
    return (pb, offsets)
}

@Test func cropRectIsTheSpikeRule() {
    // 1.4x the longer side, centred on the face: 50x40 at (100,100) → side 70 around (125,120)
    #expect(GenderClassifier.cropRect(face: Rect(x: 100, y: 100, width: 50, height: 40), in: Size(width: 640, height: 480))
        == Rect(x: 90, y: 85, width: 70, height: 70))
    // clamped to the frame
    #expect(GenderClassifier.cropRect(face: Rect(x: 0, y: 0, width: 50, height: 50), in: Size(width: 640, height: 480))
        == Rect(x: 0, y: 0, width: 60, height: 60))
    #expect(GenderClassifier.cropRect(face: Rect(x: 600, y: 440, width: 40, height: 40), in: Size(width: 640, height: 480))
        == Rect(x: 592, y: 432, width: 48, height: 48))
    // rounded outwards to whole pixels: 10x10 at (10.5,10.5) → (8.5,8.5,14,14) → (8,8,15,15)
    #expect(GenderClassifier.cropRect(face: Rect(x: 10.5, y: 10.5, width: 10, height: 10), in: Size(width: 100, height: 100))
        == Rect(x: 8, y: 8, width: 15, height: 15))
}

@Suite(.serialized, .enabled(if: modelPresent, missing))
struct GenderClassifierModelTests {
    @Test func womanFixtureIsAWoman() async throws {
        let (image, face) = try await fixtureFace("woman")
        let p = try await Shared.shared.classifier().pWoman(faces: [face], in: image)
        #expect(p.count == 1)
        #expect(p[0] >= Category.minWomanProbability, "P(woman)=\(p)")
    }

    @Test func manFixtureIsAMan() async throws {
        let (image, face) = try await fixtureFace("man")
        let p = try await Shared.shared.classifier().pWoman(faces: [face], in: image)
        #expect(p.count == 1)
        #expect(p[0] <= Category.maxManProbability, "P(woman)=\(p)")
    }

    /// Both fixtures in one BGRA frame, classified in one batch: results stay index-aligned, agree with the CGImage path within
    /// 0.05, and the per-crop time is printed against the spike's 8–10 ms p50 (ANE; noisy when other agents build).
    @Test func pixelBufferBatchIsAlignedAndTimed() async throws {
        let woman = try await fixtureFace("woman"), man = try await fixtureFace("man")
        let c = try await Shared.shared.classifier()
        let (buffer, offsets) = try frame([woman.image, man.image])
        var manFace = man.face
        manFace.x += offsets[1]
        let faces = [woman.face, manFace, woman.face]
        var perCrop: [Double] = []
        var p: [Double] = []
        for _ in 0..<20 {
            let t0 = ContinuousClock.now
            p = try c.pWoman(faces: faces, in: buffer)
            perCrop.append(Double((ContinuousClock.now - t0).components.attoseconds) / 1e15 / Double(faces.count))
        }
        #expect(p.count == 3)
        #expect(p[0] >= Category.minWomanProbability && p[2] >= Category.minWomanProbability, "woman → \(p)")
        #expect(p[1] <= Category.maxManProbability, "man → \(p)")
        let single = try c.pWoman(faces: [woman.face], in: woman.image)
        #expect(abs(single[0] - p[0]) < 0.05, "buffer \(p[0]) vs image \(single[0])")
        let sorted = perCrop.sorted()
        var loads = [Double](repeating: 0, count: 3)
        _ = getloadavg(&loads, 3)
        print(String(format: "classifier_ms_per_crop p50=%.2f p95=%.2f n=%d crops_per_call=%d spike_p50_ms=8-10 load1=%.1f noisy=%@",
                     sorted[sorted.count / 2], sorted[Int(Double(sorted.count - 1) * 0.95)], perCrop.count, faces.count, loads[0],
                     loads[0] > 4 ? "true" : "false"))
    }
}
