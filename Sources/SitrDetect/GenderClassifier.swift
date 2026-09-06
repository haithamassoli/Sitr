// CoreML face-gender classifier (M2-T07): dima806/fairface_gender_image_detection, ViT-B/16 int8, Apache-2.0
// (Models/dist/SOURCE.md). Contract: one colour image input (224x224, normalisation inside the graph), output `probs` =
// [P(woman), P(man)]. Fed exactly as the spike evaluated it (docs/spike/classifier.md, `FaceCrop.cropRect`): a square crop
// of 1.4x the longer face side around the face centre (20 % margin per side), clamped to the frame, scale-filled to the
// input. `.cpuAndNeuralEngine` by default: `.all` let CoreML schedule parts of the ViT on the GPU and doubled the latency.
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreML
import CoreVideo
import Foundation
import SitrCore

public struct GenderClassifier: @unchecked Sendable {
    // @unchecked: MLModel prediction and CIContext are thread-safe per Apple; the pool hands out a fresh buffer per crop.
    let model: MLModel
    let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
    let pool: CVPixelBufferPool
    let inputName: String
    /// Network input in pixels (from the model description); 224x224 for the shipped model.
    public let inputSize: Size

    /// `url` is a compiled `.mlmodelc` or an `.mlpackage` (compiled into a temp dir first, ~0.6 s; the app bundle ships it compiled).
    public init(contentsOf url: URL, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) async throws {
        let compiled = url.pathExtension == "mlpackage" ? try await MLModel.compileModel(at: url) : url
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try await MLModel.load(contentsOf: compiled, configuration: configuration)
        let description = model.modelDescription
        guard let input = description.inputDescriptionsByName.first(where: { $0.value.type == .image }), let image = input.value.imageConstraint,
              description.outputDescriptionsByName["probs"]?.type == .multiArray
        else { throw CoreMLDetectorError("model needs one image input and a multiarray output `probs`") }
        inputName = input.key
        inputSize = Size(width: Double(image.pixelsWide), height: Double(image.pixelsHigh))
        pool = try bgraPool(width: image.pixelsWide, height: image.pixelsHigh)
    }

    /// The spike's crop: a square of 1.4x the longer face side around the face centre (20 % margin per side), clamped to `size`
    /// and rounded outwards to whole pixels. Face and result in capture pixels, top-left origin.
    public static func cropRect(face: Rect, in size: Size) -> Rect {
        let side = max(face.width, face.height) * 1.4
        let r = CGRect(x: face.midX - side / 2, y: face.midY - side / 2, width: side, height: side)
            .intersection(CGRect(x: 0, y: 0, width: size.width, height: size.height)).integral
        return Rect(x: r.minX, y: r.minY, width: r.width, height: r.height)
    }

    /// P(woman) per face, index-aligned. Faces in pixels of `pixelBuffer` (an SCStream BGRA frame), top-left origin.
    public func pWoman(faces: [Rect], in pixelBuffer: CVPixelBuffer) throws -> [Double] {
        let size = Size(width: Double(CVPixelBufferGetWidth(pixelBuffer)), height: Double(CVPixelBufferGetHeight(pixelBuffer)))
        return try pWoman(faces: faces, in: CIImage(cvPixelBuffer: pixelBuffer), size: size)
    }

    /// P(woman) per face, index-aligned. Faces in pixels of `image`, top-left origin.
    public func pWoman(faces: [Rect], in image: CGImage) throws -> [Double] {
        try pWoman(faces: faces, in: CIImage(cgImage: image), size: image.sitrSize)
    }

    func pWoman(faces: [Rect], in source: CIImage, size: Size) throws -> [Double] {
        guard !faces.isEmpty else { return [] }
        let inputs = try faces.map { face -> MLFeatureProvider in
            let crop = Self.cropRect(face: face, in: size)
            guard crop.width > 0, crop.height > 0 else { throw CoreMLDetectorError("face \(face) lies outside the frame") }
            // CoreImage's origin is bottom-left: flip the crop, scale-fill it to the input (Lanczos: faces are up- and
            // downscaled by up to ~4x), move it to the origin and render into a pooled buffer.
            let scale = CIFilter.lanczosScaleTransform()
            scale.inputImage = source.cropped(to: CGRect(x: crop.minX, y: size.height - crop.maxY, width: crop.width, height: crop.height))
            scale.scale = Float(inputSize.height / crop.height)
            scale.aspectRatio = Float(crop.height / crop.width * inputSize.width / inputSize.height)
            guard let scaled = scale.outputImage else { throw CoreMLDetectorError("scale failed") }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let input = buffer else {
                throw CoreMLDetectorError("cannot allocate an input pixel buffer")
            }
            context.render(scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.minX, y: -scaled.extent.minY)), to: input,
                           bounds: CGRect(x: 0, y: 0, width: inputSize.width, height: inputSize.height), colorSpace: nil)
            return try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: input)])
        }
        // One batch call for all faces: 5–9 % less per crop than single predictions in a loop (docs/m2/detect.md); the ANE runs
        // the crops serially either way, so this only saves the per-call overhead.
        let outputs = try model.predictions(fromBatch: MLArrayBatchProvider(array: inputs))
        return try (0..<outputs.count).map { i in
            guard let probs = outputs.features(at: i).featureValue(for: "probs")?.multiArrayValue, probs.count == 2 else {
                throw CoreMLDetectorError("unexpected `probs` layout")
            }
            return probs[0].doubleValue
        }
    }
}
