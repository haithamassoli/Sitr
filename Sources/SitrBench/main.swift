// sitr-bench (M4-T08): the app's detection + classification path over a labeled image set, offline.
//   sitr-bench <labels.json> [--images <dir>] [--models Models/dist] [--threshold 0.80] [--limit N] [--json out.json] [--verbose]
//   sitr-bench --selfcheck
// Per image, exactly what Sources/Sitr/Pipeline/Pipeline.swift does per frame: the image becomes a BGRA frame with the long side
// 1280 (FR1), CoreMLPersonDetector (YOLOX-M 1024x640, threshold 0.25, NMS 0.5) and Vision FaceDetector run on it, faces go to the
// person they overlap most, GenderClassifier crops with the shipped rule, and the category rule decides. Metrics in Metrics.swift.
// No screen pixels are involved (public benchmark photos); output is numbers only.
import AVFoundation
import CoreImage
import CryptoKit
import CoreImage.CIFilterBuiltins
import CoreML
import CoreVideo
import Foundation
import SitrCore
import enum SitrCore.Category
import SitrDetect

let usage = """
usage: sitr-bench <labels.json> [--images <dir>] [--models <dir>] [--threshold 0.80] [--limit N] [--lanczos-below X]
                  [--person-threshold 0.25] [--split all|tuning|validation] [--json out.json] [--verbose]
       sitr-bench --selfcheck
  labels     Bench/labels/recall-coco.json or Bench/labels/faces-commons.json (python3 Bench/convert_labels.py)
  --images   image folder; default: the labels file's images_dir (python3 Bench/download.py --labels <labels.json>)
  --models   folder with PersonDetector and GenderClassifier .mlpackage or .mlmodelc; default Models/dist
  --limit    first N images only; --json writes every number as JSON; --verbose prints one line per image (counts only)
  --lanczos-below  M4-T09: resample into the network canvas with Lanczos only below this scale factor (default 0.75;
                   0 = never, 2 = always, which is what every number before M4-T09 was measured with)
"""

struct BenchError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// FR2, as in Pipeline.swift `assignFaces`: each face goes to the person box it overlaps most; a person with several faces keeps
/// the largest. Copied because the app target is not a library.
func assignFaces(_ faces: [Detection], to persons: [Detection]) -> [Detection?] {
    var assigned = [Detection?](repeating: nil, count: persons.count)
    for face in faces {
        let overlaps = persons.map { $0.box.intersection(face.box).area }
        guard let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }), overlaps[best] > 0 else { continue }
        if assigned[best].map({ $0.box.area < face.box.area }) ?? true { assigned[best] = face }
    }
    return assigned
}

/// Pipeline.swift `classifiable`: the rule can only say something for a face >= 32 px on a body >= 40 px, so the model runs only then.
func classifiable(face: Detection?, body: Detection) -> Bool {
    guard let face else { return false }
    return min(face.box.width, face.box.height) >= Category.minFaceSide && body.box.height >= Category.minBodyHeight
}

/// `<dir>/<name>.mlmodelc` if present, else `<dir>/<name>.mlpackage` compiled once into the temp dir (keyed by the manifest mtime).
func compiledModel(_ dir: URL, _ name: String) async throws -> URL {
    let fm = FileManager.default
    let compiled = dir.appendingPathComponent("\(name).mlmodelc")
    if fm.fileExists(atPath: compiled.path) { return compiled }
    let package = dir.appendingPathComponent("\(name).mlpackage")
    guard fm.fileExists(atPath: package.path) else { throw BenchError("\(package.path) not found (see --models)") }
    let manifest = package.appendingPathComponent("Manifest.json").path
    let stamp = ((try? fm.attributesOfItem(atPath: manifest))?[.modificationDate] as? Date).map { Int($0.timeIntervalSince1970) } ?? 0
    let cached = fm.temporaryDirectory.appendingPathComponent("sitr-bench-\(name)-\(stamp).mlmodelc")
    if !fm.fileExists(atPath: cached.path) {
        try fm.moveItem(at: try await MLModel.compileModel(at: package), to: cached)
    }
    return cached
}

/// An IOSurface-backed BGRA buffer like an SCStream frame.
func blankFrame(width: Int, height: Int) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
          let pb = buffer
    else { throw BenchError("cannot allocate a \(width)x\(height) frame") }
    return pb
}

/// The image as an SCStream-like BGRA frame with the long side `longSide` (Lanczos, EXIF orientation applied), optionally darkened
/// like the spike's synthetic low-light set (per channel: pow(v, gamma) * gain on 0…1 values).
func frame(_ url: URL, longSide: Double, darken: Labels.Darken?, context: CIContext) throws -> CVPixelBuffer {
    guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { throw BenchError("cannot read \(url.path)") }
    let s = longSide / max(image.extent.width, image.extent.height)
    let scale = CIFilter.lanczosScaleTransform()
    scale.inputImage = image
    scale.scale = Float(s)
    scale.aspectRatio = 1
    guard let scaled = scale.outputImage else { throw BenchError("scale failed for \(url.lastPathComponent)") }
    let w = max(1, Int((image.extent.width * s).rounded())), h = max(1, Int((image.extent.height * s).rounded()))
    let pb = try blankFrame(width: w, height: h)
    context.render(scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.minX, y: -scaled.extent.minY)), to: pb,
                   bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: nil)
    if let darken {
        let lut = (0...255).map { UInt8(min(255, (pow(Double($0) / 255, darken.gamma) * darken.gain * 255).rounded())) }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { throw BenchError("frame has no base address") }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<h {
            for x in 0..<w {
                let o = y * stride + x * 4  // B, G, R, A
                base[o] = lut[Int(base[o])]
                base[o + 1] = lut[Int(base[o + 1])]
                base[o + 2] = lut[Int(base[o + 2])]
            }
        }
    }
    return pb
}

func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

func run(_ args: [String], labelsPath: String) async throws {
    let labelsURL = URL(fileURLWithPath: labelsPath)
    var labels = try JSONDecoder().decode(Labels.self, from: Data(contentsOf: labelsURL))
    let imagesDir = option("--images", in: args).map { URL(fileURLWithPath: $0) }
        ?? labelsURL.deletingLastPathComponent().appendingPathComponent(labels.imagesDir ?? ".").standardizedFileURL
    // ponytail: cwd-relative Models/dist, else the checkout's via #filePath (a developer's shell); a shipped bench would take --models only.
    var modelsDir = URL(fileURLWithPath: option("--models", in: args) ?? "Models/dist")
    if option("--models", in: args) == nil, !FileManager.default.fileExists(atPath: modelsDir.path) {
        modelsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Models/dist")
    }
    guard let threshold = Double(option("--threshold", in: args) ?? "0.80"), threshold > 0.5, threshold <= 1 else { throw BenchError("--threshold must be in (0.5, 1]") }
    guard let personThreshold = Float(option("--person-threshold", in: args) ?? "0.25"),
          personThreshold > 0, personThreshold <= 1 else { throw BenchError("--person-threshold must be in (0, 1]") }
    let split = option("--split", in: args) ?? "all"
    guard ["all", "tuning", "validation"].contains(split) else { throw BenchError("--split must be all, tuning, or validation") }
    if split != "all" {
        labels.images = labels.images.filter { isTuningImage($0.file) == (split == "tuning") }
        labels.set += "-" + split
    }
    let limit = Int(option("--limit", in: args) ?? "") ?? Int.max
    let verbose = args.contains("--verbose")
    let longSide = 1280.0

    // Models as the app loads them: both on .cpuAndNeuralEngine (docs/m2/detect.md), detector threshold 0.30 / NMS 0.5.
    var t0 = ContinuousClock.now
    var detector = try await CoreMLPersonDetector(contentsOf: try await compiledModel(modelsDir, "PersonDetector"), computeUnits: .cpuAndNeuralEngine, threshold: personThreshold)
    if let l = Double(option("--lanczos-below", in: args) ?? "") { detector.lanczosBelow = l }
    let classifier = try await GenderClassifier(contentsOf: try await compiledModel(modelsDir, "GenderClassifier"), computeUnits: .cpuAndNeuralEngine)
    let faces = FaceDetector()
    print("sitr-bench set=\(labels.set) labels=\(labelsURL.lastPathComponent) images_dir=\(imagesDir.path) models=\(modelsDir.path) "
        + "detector_input=\(Int(detector.inputSize.width))x\(Int(detector.inputSize.height)) detector_threshold=\(detector.threshold) nms=\(detector.nmsIoU) lanczos_below=\(detector.lanczosBelow) "
        + "classifier_input=\(Int(classifier.inputSize.width))x\(Int(classifier.inputSize.height)) load_ms=\(f1(ms(t0.duration(to: .now))))")
    let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])

    // Warm-up on a blank frame, like Pipeline.warmUp: the first prediction of each model pays for loading it.
    let blank = try blankFrame(width: 64, height: 64)
    _ = try? await detector.detect(in: blank)
    _ = try? await faces.detect(in: blank)
    _ = try? classifier.pWoman(faces: [Rect(x: 0, y: 0, width: 40, height: 40)], in: blank)

    var matches: [Matched] = []
    var detectMs: [Double] = [], facesMs: [Double] = [], classifyMs: [Double] = [], perCropMs: [Double] = []
    var processed = 0, missing = 0, unreadable = 0, classifierErrors = 0
    for image in labels.images.prefix(limit) {
        let url = imagesDir.appendingPathComponent(image.file)
        guard FileManager.default.fileExists(atPath: url.path) else { missing += 1; continue }
        let pb: CVPixelBuffer
        do { pb = try frame(url, longSide: longSide, darken: image.darken, context: context) } catch {
            unreadable += 1
            print("unreadable \(image.file): \(error)")
            continue
        }
        let size = Size(width: Double(CVPixelBufferGetWidth(pb)), height: Double(CVPixelBufferGetHeight(pb)))

        // ponytail: detector and faces run one after the other for clean per-stage timing (the app runs them concurrently, so its
        // detect_ms is roughly the max of the two, not the sum); upgrade: `async let` both and report the pair as well.
        t0 = .now
        let persons = try await detector.detect(in: pb)
        detectMs.append(ms(t0.duration(to: .now)))
        t0 = .now
        let faceBoxes = try await faces.detect(in: pb)
        facesMs.append(ms(t0.duration(to: .now)))
        let assigned = assignFaces(faceBoxes, to: persons)
        // ponytail: every classifiable face is classified (the app caps at 3 per frame and catches up on later frames; a still image
        // has no later frame); upgrade: feed a labeled video through the Tracker for the per-frame cap and stickiness.
        let order = persons.indices.filter { classifiable(face: assigned[$0], body: persons[$0]) }
        var probabilities: [Double?] = order.map { _ in nil }
        if !order.isEmpty {
            t0 = .now
            do { probabilities = try classifier.pWoman(faces: order.map { assigned[$0]!.box }, in: pb) } catch { classifierErrors += 1 }
            let elapsed = ms(t0.duration(to: .now))
            classifyMs.append(elapsed)
            perCropMs.append(elapsed / Double(order.count))
        }

        // Labeled boxes → frame pixels. Independent x/y factors, so a whole-image box stays the whole frame even when EXIF
        // orientation swapped the sides; a real aspect mismatch is reported.
        let sx = size.width / Double(image.width), sy = size.height / Double(image.height)
        if abs(sx / sy - 1) > 0.01 { print("aspect_mismatch \(image.file) labeled=\(image.width)x\(image.height) frame=\(Int(size.width))x\(Int(size.height))") }
        let gt = image.persons.map { p in
            Observed.GT(box: Rect(x: p.box[0] * sx, y: p.box[1] * sy, width: p.box[2] * sx, height: p.box[3] * sy),
                        category: p.category == "woman" ? .woman : p.category == "man" ? .man : nil, tags: p.tags)
        }
        let dets = persons.indices.map { i in
            Observed.Det(box: persons[i].box, confidence: persons[i].confidence, face: assigned[i].map { Size(width: $0.box.width, height: $0.box.height) },
                         pWoman: order.firstIndex(of: i).flatMap { probabilities[$0] })
        }
        let observed = Observed(frame: size, gt: gt, dets: dets)
        let m = match(observed)
        matches += m
        processed += 1
        if verbose {
            let categories = dets.map { category(face: $0.face, body: Size(width: $0.box.width, height: $0.box.height), pWoman: $0.pWoman, threshold: threshold) }
            print("image file=\(image.file) frame=\(Int(size.width))x\(Int(size.height)) gt=\(gt.count) eligible=\(m.count) matched=\(m.count { $0.det != nil }) "
                + "persons=\(persons.count) faces=\(faceBoxes.count) crops=\(order.count) categories=w\(categories.count { $0 == .woman })/m\(categories.count { $0 == .man })/u\(categories.count { $0 == .unknown })"
                + (image.darken == nil ? "" : " darkened=true"))
        }
    }

    var report = Report(set: labels.set, matches: matches, threshold: threshold,
                        ms: [("detect", detectMs), ("faces", facesMs), ("classify", classifyMs), ("classify/crop", perCropMs)])
    report.processed = processed
    report.missing = missing
    report.unreadable = unreadable
    report.classifierErrors = classifierErrors
    report.print()
    if let out = option("--json", in: args) {
        try JSONSerialization.data(withJSONObject: report.json.merging(["person_threshold": Double(personThreshold), "split": split]) { _, value in value }, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: out))
        print("wrote \(out)")
    }
    if missing > 0 { print("missing_images=\(missing) (python3 Bench/download.py --labels \(labelsPath))") }
    guard processed > 0 else { throw BenchError("no images processed (\(missing) missing, \(unreadable) unreadable in \(imagesDir.path))") }
}

// MARK: - observer: people still visible in a screen recording of the app at work

/// `sitr-bench --observe <recording.mov> [--min-height 60] [--threshold 0.5]`: the detector over every frame of a screen recording
/// taken with Solid covers on, so a covered person is a flat rectangle and anything still found is a person the user saw. One
/// line per frame (`t n h1,h2…`) then a summary: share of frames with an exposed person, and exposure episodes.
// ponytail: the observer is the app's own detector, so it cannot see the people the detector misses — it measures the pipeline
// (lag, dropouts, flicker), not recall. Recall is the labeled bench above.
func observe(_ path: String, args: [String]) async throws {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw BenchError("no video track in \(path)") }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                                                         kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
    reader.add(output)
    reader.startReading()
    let minHeight = Double(option("--min-height", in: args) ?? "60") ?? 60
    let threshold = Float(option("--threshold", in: args) ?? "0.5") ?? 0.5
    var modelsDir = URL(fileURLWithPath: option("--models", in: args) ?? "Models/dist")
    if !FileManager.default.fileExists(atPath: modelsDir.path) {
        modelsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Models/dist")
    }
    let detector = try await CoreMLPersonDetector(contentsOf: try await compiledModel(modelsDir, "PersonDetector"), computeUnits: .cpuAndNeuralEngine, threshold: threshold)
    var frames = 0, exposed = 0, episodes = 0, last = false
    var runStart = 0.0, runs: [Double] = []
    while let sample = output.copyNextSampleBuffer() {
        guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
        let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        let found = try await detector.detect(in: pb).filter { $0.box.height >= minHeight }
        let hs = found.map { Int($0.box.height) }
        frames += 1
        let now = !hs.isEmpty
        if now { exposed += 1 }
        if now && !last { episodes += 1; runStart = t }
        if !now && last { runs.append(t - runStart) }
        last = now
        print("frame t=\(String(format: "%.3f", t)) n=\(hs.count) h=\(hs.map(String.init).joined(separator: ",")) boxes=\(found.map { "\(Int($0.box.x)),\(Int($0.box.y)),\(Int($0.box.width))x\(Int($0.box.height))@\(String(format: "%.2f", $0.confidence))" }.joined(separator: " "))")
    }
    if last { runs.append((try await asset.load(.duration)).seconds - runStart) }  // an exposure still open at the end counts too
    guard reader.status == .completed else { throw BenchError("reading \(path) stopped: \(reader.error.map { "\($0)" } ?? "status \(reader.status.rawValue)")") }
    runs.sort()
    let p = { (q: Double) in runs.isEmpty ? 0 : runs[min(runs.count - 1, Int(Double(runs.count) * q))] * 1000 }
    print("observe file=\((path as NSString).lastPathComponent) frames=\(frames) exposed_frames=\(exposed) exposed_share=\(String(format: "%.3f", Double(exposed) / Double(max(frames, 1)))) "
        + "episodes=\(episodes) episode_ms_p50=\(Int(p(0.5))) episode_ms_p90=\(Int(p(0.9))) min_height=\(Int(minHeight)) threshold=\(threshold)")
}

// MARK: - entry

let args = Array(CommandLine.arguments.dropFirst())
if let i = args.firstIndex(of: "--observe"), i + 1 < args.count {
    do { try await observe(args[i + 1], args: args) } catch { print("sitr-bench: \(error)"); exit(1) }
    exit(0)
}
if args.contains("--selfcheck") {
    selfcheck()
    exit(0)
}
let valueFlags: Set<String> = ["--images", "--models", "--threshold", "--limit", "--json", "--lanczos-below", "--person-threshold", "--split"]
var positional: [String] = []
var i = 0
while i < args.count {
    if valueFlags.contains(args[i]) { i += 2; continue }
    if !args[i].hasPrefix("--") { positional.append(args[i]) }
    i += 1
}
guard positional.count == 1, !args.contains("--help") else {
    print(usage)
    exit(2)
}
let labelsPath = positional[0]
do {
    try await run(args, labelsPath: labelsPath)
} catch {
    print("sitr-bench: \(error)")
    exit(1)
}
