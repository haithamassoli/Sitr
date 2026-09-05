// sitr-spike classifier — M1-T05 rig: face crops, Neural Engine timing, and manifest evaluation for CoreML
// face-gender classifiers. A model is any CoreML file whose image input is a face crop and whose output is
// either `probs` = [P(woman), P(man)] (Models/convert_hf.py) or a Create ML label dictionary with "woman".
//
//   --crop <in> <out>                  largest Vision face + 20 % margin, square, written as JPEG
//   --crop-dir <in-dir> <out-dir>      same for every image in a tree; images with != 1 face are skipped
//   --bench <model> [--units all|ane|cpu]   ms per crop, batch 1, 20 warm + 200 timed, p50/p95
//   --eval <manifest-dir> --model <m> [--model <m2> ...] [--images <dir>] [--threshold 0.8] [--min-face 32]
//          [--dump-crops <dir>] [--verbose]      images with != 1 Vision face, or a face under --min-face px, are skipped
import CoreML
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

private let classifierUsage = """
usage: sitr-spike classifier --crop <in> <out>
                             --crop-dir <in-dir> <out-dir>
                             --bench <model.mlpackage|mlmodelc> [--units all|ane|cpu]
                             --eval <manifest-dir> --model <m> [--model <m2>] [--images <dir>] [--threshold 0.8]
                                    [--min-face 32] [--dump-crops <dir>] [--verbose]
"""

@MainActor
func runClassifier(_ args: [String]) {
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do { try await classifierMain(args) } catch {
            print("error: \(error)")
            exit(1)
        }
        done.signal()
    }
    done.wait()  // ponytail: main.swift is synchronous; nothing in this rig needs the main actor, so block it
    exit(0)
}

private struct RigError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

private func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

private func options(_ name: String, in args: [String]) -> [String] {
    args.indices.filter { args[$0] == name && $0 + 1 < args.count }.map { args[$0 + 1] }
}

private func classifierMain(_ args: [String]) async throws {
    switch args.first {
    case "--crop" where args.count >= 3:
        let image = try loadImage(URL(fileURLWithPath: args[1]))
        guard let face = try FaceCrop.faces(in: image).max(by: { $0.width < $1.width }) else { throw RigError("no face") }
        try writeJPEG(FaceCrop.crop(image, face: face), to: URL(fileURLWithPath: args[2]))
    case "--crop-dir" where args.count >= 3:
        try cropTree(from: URL(fileURLWithPath: args[1]), to: URL(fileURLWithPath: args[2]))
    case "--bench" where args.count >= 2:
        let units: [(String, MLComputeUnits)]
        switch option("--units", in: args) {
        case "ane": units = [("cpuAndNeuralEngine", .cpuAndNeuralEngine)]
        case "cpu": units = [("cpuOnly", .cpuOnly)]
        default: units = [("all", .all), ("cpuAndNeuralEngine", .cpuAndNeuralEngine)]
        }
        for (label, u) in units { try await bench(modelPath: args[1], unitsLabel: label, units: u) }
    case "--eval" where args.count >= 2:
        let models = options("--model", in: args)
        guard !models.isEmpty else { throw RigError("--eval needs at least one --model") }
        try await evaluate(manifestDir: URL(fileURLWithPath: args[1]), modelPaths: models,
                           imagesDir: option("--images", in: args).map { URL(fileURLWithPath: $0) },
                           threshold: Double(option("--threshold", in: args) ?? "") ?? 0.80,
                           minFace: CGFloat(Double(option("--min-face", in: args) ?? "") ?? 32),
                           dumpDir: option("--dump-crops", in: args).map { URL(fileURLWithPath: $0) },
                           verbose: args.contains("--verbose"))
    default:
        print(classifierUsage)
        exit(2)
    }
}

// MARK: - Images and face crops

private func loadImage(_ url: URL) throws -> CGImage {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { throw RigError("cannot read \(url.path)") }
    return image  // EXIF orientation is ignored: the fetch scripts save upright JPEGs
}

private func writeJPEG(_ image: CGImage, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else { throw RigError("cannot create \(url.path)") }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw RigError("cannot write \(url.path)") }
}

enum FaceCrop {
    /// Face boxes in image pixels, top-left origin.
    static func faces(in image: CGImage) throws -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let w = CGFloat(image.width), h = CGFloat(image.height)
        return (request.results ?? []).map { o in
            let b = o.boundingBox
            return CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h)
        }
    }

    /// Square crop around the face with a 20 % margin on every side (1.4x the longer side), clamped to the image.
    /// M2-T07 must use the same rule so the shipped model sees the framing it was evaluated on.
    static func cropRect(face: CGRect, width: Int, height: Int) -> CGRect {
        let side = max(face.width, face.height) * 1.4
        let r = CGRect(x: face.midX - side / 2, y: face.midY - side / 2, width: side, height: side)
        return r.intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
    }

    static func crop(_ image: CGImage, face: CGRect) -> CGImage {
        image.cropping(to: cropRect(face: face, width: image.width, height: image.height)) ?? image
    }
}

private func cropTree(from input: URL, to output: URL) throws {
    let fm = FileManager.default
    guard let files = fm.enumerator(at: input, includingPropertiesForKeys: [.isRegularFileKey]) else { throw RigError("cannot list \(input.path)") }
    var written = 0, skipped = 0
    for case let url as URL in files where ["jpg", "jpeg", "png"].contains(url.pathExtension.lowercased()) {
        let image = try loadImage(url)
        let faces = try FaceCrop.faces(in: image)
        guard faces.count == 1 else { skipped += 1; continue }
        let rel = url.path.dropFirst(input.path.count + 1)
        try writeJPEG(FaceCrop.crop(image, face: faces[0]), to: output.appendingPathComponent(String(rel)))
        written += 1
    }
    print("crop-dir written=\(written) skipped_not_one_face=\(skipped)")
}

// MARK: - Model wrapper

private final class GenderModel {
    let name: String
    let model: MLModel
    let inputName: String
    let constraint: MLImageConstraint
    let outputName: String
    let outputIsDictionary: Bool
    let sizeMB: Double

    init(path: String, units: MLComputeUnits) async throws {
        var url = URL(fileURLWithPath: path)
        name = url.deletingPathExtension().lastPathComponent
        sizeMB = Double(directorySize(url)) / 1e6
        if url.pathExtension != "mlmodelc" { url = try await MLModel.compileModel(at: url) }
        let config = MLModelConfiguration()
        config.computeUnits = units
        model = try MLModel(contentsOf: url, configuration: config)
        let desc = model.modelDescription
        guard let input = desc.inputDescriptionsByName.first(where: { $0.value.type == .image }), let c = input.value.imageConstraint
        else { throw RigError("\(path): no image input") }
        inputName = input.key
        constraint = c
        if let dict = desc.outputDescriptionsByName.first(where: { $0.value.type == .dictionary }) {
            outputName = dict.key
            outputIsDictionary = true
        } else if let arr = desc.outputDescriptionsByName.first(where: { $0.value.type == .multiArray }) {
            outputName = arr.key
            outputIsDictionary = false
        } else {
            throw RigError("\(path): no probs or label dictionary output")
        }
    }

    func predict(_ input: MLFeatureProvider) throws -> Double {
        let out = try model.prediction(from: input)
        guard let value = out.featureValue(for: outputName) else { throw RigError("missing output \(outputName)") }
        if outputIsDictionary {
            let d = value.dictionaryValue
            guard let p = d["woman"] ?? d["Female"] ?? d["female"] else { throw RigError("no woman label in \(d.keys)") }
            return p.doubleValue
        }
        guard let arr = value.multiArrayValue else { throw RigError("output \(outputName) is not an array") }
        return arr[0].doubleValue
    }

    /// P(woman) for a face crop; the crop is resized to the model's input size (scale-fill, no letterboxing).
    func womanProbability(_ crop: CGImage) throws -> Double {
        let value = try MLFeatureValue(cgImage: crop, constraint: constraint,
                                       options: [.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue])
        return try predict(MLDictionaryFeatureProvider(dictionary: [inputName: value]))
    }
}

private func directorySize(_ url: URL) -> Int64 {
    guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
    var total: Int64 = 0
    for case let f as URL in e {
        total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    return total
}

// MARK: - Bench

private func bench(modelPath: String, unitsLabel: String, units: MLComputeUnits) async throws {
    let m = try await GenderModel(path: modelPath, units: units)
    let w = m.constraint.pixelsWide, h = m.constraint.pixelsHigh
    var pb: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, nil, &pb) == kCVReturnSuccess, let buffer = pb
    else { throw RigError("pixel buffer") }
    CVPixelBufferLockBaseAddress(buffer, [])
    if let base = CVPixelBufferGetBaseAddress(buffer) {
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for i in 0..<(CVPixelBufferGetBytesPerRow(buffer) * h) { bytes[i] = UInt8.random(in: 0...255) }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    let input = try MLDictionaryFeatureProvider(dictionary: [m.inputName: MLFeatureValue(pixelBuffer: buffer)])
    for _ in 0..<20 { _ = try m.predict(input) }
    let clock = ContinuousClock()
    var ms: [Double] = []
    for _ in 0..<200 {
        let d = try clock.measure { _ = try m.predict(input) }
        ms.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
    }
    ms.sort()
    print("classifier_ms model=\(m.name) units=\(unitsLabel) p50=\(fmt(ms[100])) p95=\(fmt(ms[190])) n=200 input=\(w)x\(h) size_mb=\(fmt(m.sizeMB))")
}

private func fmt(_ x: Double) -> String { String(format: "%.2f", x) }

// MARK: - Manifest evaluation

private struct Manifest: Decodable {
    struct Entry: Decodable {
        let id: String
        let file: String
        let label: String
        let tags: [String]
    }
    let images_dir: String?
    let entries: [Entry]
}

private struct Tally {
    var n = 0, correct = 0, unknown = 0, wrongKnown = 0
    mutating func add(pWoman: Double, label: String, threshold: Double) {
        n += 1
        let isCorrect = (pWoman >= 0.5) == (label == "woman")
        if isCorrect { correct += 1 }
        if max(pWoman, 1 - pWoman) < threshold { unknown += 1 } else if !isCorrect { wrongKnown += 1 }
    }
    var accuracy: String { n == 0 ? "-" : pct(correct, n) }
    var unknownRate: String { n == 0 ? "-" : pct(unknown, n) }
    var misclassified: String { n - unknown == 0 ? "-" : pct(wrongKnown, n - unknown) }
}

private func pct(_ a: Int, _ b: Int) -> String { String(format: "%.1f%%", 100 * Double(a) / Double(max(b, 1))) }

private func evaluate(manifestDir: URL, modelPaths: [String], imagesDir: URL?, threshold: Double, minFace: CGFloat, dumpDir: URL?, verbose: Bool) async throws {
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestDir.appendingPathComponent("manifest.json")))
    let images = imagesDir ?? manifestDir.appendingPathComponent(manifest.images_dir ?? ".").standardizedFileURL
    let models = try await modelPaths.asyncMap { try await GenderModel(path: $0, units: .all) }
    let tagOrder = ["general", "hijab", "child", "low-light", "profile"]
    var faceStats: [String: (found: Int, total: Int)] = [:]
    var tallies: [[String: Tally]] = Array(repeating: [:], count: models.count)
    var elapsedMS: [Double] = Array(repeating: 0, count: models.count)
    let clock = ContinuousClock()

    for entry in manifest.entries {
        let tags = entry.tags.isEmpty ? ["general"] : entry.tags
        let image = try loadImage(images.appendingPathComponent(entry.file))
        let faces = try FaceCrop.faces(in: image)
        for t in tags + ["all"] { faceStats[t, default: (0, 0)].total += 1 }
        guard faces.count == 1, faces[0].width >= minFace else {
            if verbose { print("\(entry.id) \(entry.label) faces=\(faces.count) skipped\(faces.count == 1 ? " small" : "")") }
            continue
        }
        for t in tags + ["all"] { faceStats[t, default: (0, 0)].found += 1 }
        let crop = FaceCrop.crop(image, face: faces[0])
        if let dumpDir { try writeJPEG(crop, to: dumpDir.appendingPathComponent(entry.id + ".jpg")) }
        var line = "\(entry.id) \(entry.label) face=\(Int(faces[0].width))px"
        for (i, m) in models.enumerated() {
            var p = 0.0
            let d = try clock.measure { p = try m.womanProbability(crop) }
            elapsedMS[i] += Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
            for t in tags + ["all"] { tallies[i][t, default: Tally()].add(pWoman: p, label: entry.label, threshold: threshold) }
            line += " \(m.name)=\(fmt(p))"
        }
        if verbose { print(line) }
    }

    print("\nFaces found (exactly one Vision face, at least \(Int(minFace)) px wide) per tag:")
    print("| tag | found / total |\n|---|---|")
    for t in tagOrder + ["all"] where faceStats[t] != nil {
        let s = faceStats[t]!
        print("| \(t) | \(s.found) / \(s.total) |")
    }
    print("\nThreshold \(threshold): Unknown = max class probability below threshold. Accuracy = argmax vs label over faces found.")
    print("| model | size MB | ms/crop (all units, incl. resize) | n | accuracy | Unknown rate | misclassified among non-Unknown | " + tagOrder.map { "\($0) acc (n)" }.joined(separator: " | ") + " |")
    print("|---|---|---|---|---|---|---|" + tagOrder.map { _ in "---|" }.joined())
    for (i, m) in models.enumerated() {
        let all = tallies[i]["all"] ?? Tally()
        let perTag = tagOrder.map { t -> String in
            let s = tallies[i][t] ?? Tally()
            return s.n == 0 ? "-" : "\(s.accuracy) (\(s.n))"
        }.joined(separator: " | ")
        print("| \(m.name) | \(fmt(m.sizeMB)) | \(fmt(elapsedMS[i] / Double(max(all.n, 1)))) | \(all.n) | \(all.accuracy) | \(all.unknownRate) | \(all.misclassified) | \(perTag) |")
    }
    print("\nUnknown rate per tag:")
    print("| model | " + tagOrder.joined(separator: " | ") + " |\n|---|" + tagOrder.map { _ in "---|" }.joined())
    for (i, m) in models.enumerated() {
        print("| \(m.name) | " + tagOrder.map { (tallies[i][$0] ?? Tally()).unknownRate }.joined(separator: " | ") + " |")
    }
}

private extension Array {
    func asyncMap<T>(_ f: (Element) async throws -> T) async throws -> [T] {
        var out: [T] = []
        for x in self { out.append(try await f(x)) }
        return out
    }
}
