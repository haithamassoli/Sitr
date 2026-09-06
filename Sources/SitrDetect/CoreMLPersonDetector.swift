// CoreML person detector (YOLOX, Apache-2.0; Models/detector/README.md). Spike M1-T06b; the candidate for M2-T06.
// Input contract of the model: raw 0-255 BGR pixels, frame scaled by r = min(W/w, H/h) into the model's WxH canvas
// filled with 114 grey, top-left aligned (YOLOX's own ValTransform). Output `predictions` [1, N, 85] float32 rows:
// cx, cy, w, h in input pixels, objectness, 80 COCO class scores. Person = class 0, score = objectness x class.
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreML
import CoreVideo
import Foundation
import SitrCore

public struct CoreMLPersonDetector: @unchecked Sendable {
    // @unchecked: MLModel prediction and CIContext are thread-safe per Apple; the pool hands out a fresh buffer per call.
    let model: MLModel
    let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
    let pool: CVPixelBufferPool
    /// Network input in pixels (from the model description), e.g. 1280x768.
    public let inputSize: Size
    /// Minimum objectness x person score; PRD default 0.30.
    public var threshold: Float
    /// Greedy NMS: a box is dropped when its IoU with a kept, higher-scoring box exceeds this.
    public var nmsIoU: Double
    /// Resample the frame into the network canvas with Lanczos only below this scale factor; at or above it the affine
    /// transform's bilinear tap is used. Default 0.9: a real reduction (a COCO photo, a 2560 px screenshot) keeps Lanczos,
    /// while the app's own frames — captured at the model's long side, so scaled by ~0.92 — take the cheap path.
    // M4-T09: the Lanczos pass was almost the whole of the detector's per-frame cost. In a 30 s `video` profile
    // `-[CIContext render:toCVPixelBuffer:]` was 4967 of the detector's 4947 samples — the CoreML prediction itself was 835.
    // `sitr-bench --lanczos-below 0` (never Lanczos, far past what the app does) measures the recall cost; see docs/perf.md.
    public var lanczosBelow: Double = 0.9

    /// `url` is a compiled `.mlmodelc` or an `.mlpackage` (compiled into a temp dir first, ~1 s; the app bundle ships it
    /// compiled). `computeUnits` `.all` lets CoreML pick; `.cpuAndNeuralEngine` keeps the GPU free for rendering.
    public init(contentsOf url: URL, computeUnits: MLComputeUnits = .all, threshold: Float = 0.30, nmsIoU: Double = 0.5) async throws {
        let compiled = url.pathExtension == "mlpackage" ? try await MLModel.compileModel(at: url) : url
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try await MLModel.load(contentsOf: compiled, configuration: configuration)
        guard let image = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
              model.modelDescription.outputDescriptionsByName["predictions"] != nil
        else { throw CoreMLDetectorError("model needs an image input `image` and a multiarray output `predictions`") }
        inputSize = Size(width: Double(image.pixelsWide), height: Double(image.pixelsHigh))
        pool = try bgraPool(width: image.pixelsWide, height: image.pixelsHigh)
        self.threshold = threshold
        self.nmsIoU = nmsIoU
    }

    /// Boxes in pixels of `image`, top-left origin.
    public func detect(in image: CGImage) async throws -> [Detection] {
        try await detect(CIImage(cgImage: image), size: image.sitrSize)
    }

    /// Boxes in pixels of `pixelBuffer` (an SCStream BGRA frame), top-left origin.
    public func detect(in pixelBuffer: CVPixelBuffer) async throws -> [Detection] {
        let size = Size(width: Double(CVPixelBufferGetWidth(pixelBuffer)), height: Double(CVPixelBufferGetHeight(pixelBuffer)))
        return try await detect(CIImage(cvPixelBuffer: pixelBuffer), size: size)
    }

    func detect(_ source: CIImage, size: Size) async throws -> [Detection] {
        let r = min(inputSize.width / size.width, inputSize.height / size.height)
        // Lanczos (not the affine transform's bilinear tap) so a 4x downscale of a 2560 frame keeps small people intact —
        // but only where the frame is really being reduced (`lanczosBelow`); see that property for the cost.
        let scaled: CIImage
        if r < lanczosBelow {
            let scale = CIFilter.lanczosScaleTransform()
            scale.inputImage = source
            scale.scale = Float(r)
            scale.aspectRatio = 1
            guard let out = scale.outputImage else { throw CoreMLDetectorError("scale failed") }
            scaled = out
        } else {
            scaled = source.transformed(by: CGAffineTransform(scaleX: r, y: r))
        }
        // CoreImage's origin is bottom-left: lift the scaled image to the top edge so the grey padding lands right/bottom.
        // The grey is cropped to the strip the image does not cover instead of an infinite colour plane, so the composite
        // touches the padding only rather than blending over the whole canvas.
        let grey = CIImage(color: CIColor(red: 114 / 255, green: 114 / 255, blue: 114 / 255))
            .cropped(to: CGRect(x: 0, y: 0, width: inputSize.width, height: inputSize.height))
        let letterboxed = scaled.transformed(by: CGAffineTransform(translationX: 0, y: inputSize.height - scaled.extent.height))
            .composited(over: grey)
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let input = buffer else {
            throw CoreMLDetectorError("cannot allocate an input pixel buffer")
        }
        context.render(letterboxed, to: input, bounds: CGRect(x: 0, y: 0, width: inputSize.width, height: inputSize.height), colorSpace: nil)

        let output = try await model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: input)]))
        guard let rows = output.featureValue(for: "predictions")?.multiArrayValue, rows.dataType == .float32, rows.shape.count == 3,
              rows.shape[2].intValue >= 6
        else { throw CoreMLDetectorError("unexpected `predictions` layout") }
        let n = rows.shape[1].intValue, rowStride = rows.strides[1].intValue, colStride = rows.strides[2].intValue
        var candidates: [Detection] = []
        rows.withUnsafeBufferPointer(ofType: Float.self) { p in
            for i in 0..<n {
                let b = i * rowStride
                let score = p[b + 4 * colStride] * p[b + 5 * colStride]
                guard score >= threshold else { continue }
                let cx = Double(p[b]) / r, cy = Double(p[b + colStride]) / r
                let w = Double(p[b + 2 * colStride]) / r, h = Double(p[b + 3 * colStride]) / r
                let x0 = max(0, cx - w / 2), y0 = max(0, cy - h / 2)
                let x1 = min(size.width, cx + w / 2), y1 = min(size.height, cy + h / 2)
                if x1 > x0, y1 > y0 { candidates.append(Detection(box: Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), confidence: score)) }
            }
        }
        return Self.nms(candidates, iou: nmsIoU)
    }

    /// Greedy NMS: keep by descending score, drop anything overlapping a kept box by more than `iou`.
    static func nms(_ detections: [Detection], iou: Double) -> [Detection] {
        var kept: [Detection] = []
        for d in detections.sorted(by: { $0.confidence > $1.confidence }) where !kept.contains(where: { $0.box.iou(d.box) > iou }) {
            kept.append(d)
        }
        return kept
    }
}

public struct CoreMLDetectorError: Error, CustomStringConvertible {
    public let description: String
    init(_ d: String) { description = d }
}
