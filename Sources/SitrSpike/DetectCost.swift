// M1-T03: Vision detection cost. A synthetic 2560x1664 "web page" frame is composed from the CC0 photos in
// Bench/data/photos (python3 Bench/download.py --photos), downscaled to 1280 / 1920 / native, and each detector
// configuration runs N times warm on a BGRA CVPixelBuffer (what SCStream delivers). Prints one summary line per metric.
// M1-T06b: --detector coreml:<model> times CoreMLPersonDetector instead, once per --units entry (default all,ane).
import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import ImageIO
import SitrCore
import SitrDetect

private let detectUsage = """
usage: sitr-spike detect [--photos <dir>] [--n 100] [--sides 1280,1920,2560] [--dump frame.png]
                         [--detector coreml:<path.mlmodelc|mlpackage>] [--units all,ane] [--threshold 0.3]
  --dump writes the composite frame (public photos, never screen pixels) and prints every box per configuration.
  --detector coreml:<path> times the CoreML detector under each of --units (all | ane | gpu | cpu) instead of Vision.
  Numbers taken while other agents build are noisy; the official run is the quiet phase.
"""

@MainActor
func runDetectCost(_ args: [String]) {
    if args.contains("--help") { print(detectUsage); exit(0) }
    let photosDir = URL(fileURLWithPath: Rig.value(for: "--photos", in: args) ?? Rig.benchDir.appendingPathComponent("data/photos").path)
    let n = Int(Rig.value(for: "--n", in: args) ?? "") ?? 100
    let sides = (Rig.value(for: "--sides", in: args) ?? "1280,1920,2560").split(separator: ",").compactMap { Int($0) }
    let dump = Rig.value(for: "--dump", in: args).map { URL(fileURLWithPath: $0) }
    let coreml = Rig.coreMLModel(in: args)
    Task.detached {
        do {
            try await detectCost(photosDir: photosDir, iterations: n, sides: sides, dump: dump, coreml: coreml)
            exit(0)
        } catch {
            print("detect: \(error)")
            exit(1)
        }
    }
    dispatchMain()
}

private func detectCost(photosDir: URL, iterations: Int, sides: [Int], dump: URL?, coreml: CoreMLOptions?) async throws {
    let photos = try Rig.images(in: photosDir)
    guard !photos.isEmpty else { throw RigError("no photos in \(photosDir.path); run: python3 Bench/download.py --photos") }
    let frame = Rig.compose(photos, width: 2560, height: 1664)
    if let dump { try Rig.writePNG(frame, to: dump) }
    let full = PersonDetector(upperBodyOnly: false)
    let upper = PersonDetector(upperBodyOnly: true)
    let faces = FaceDetector()
    print("detect_rig chip=\(Rig.chip) frame=2560x1664 photos=\(photos.count) n=\(iterations) detector=\(coreml?.label ?? "vision") thermal=\(ProcessInfo.processInfo.thermalState.rawValue) note=preliminary/noisy-unless-quiet-phase")

    var configs: [(String, (CVPixelBuffer) async throws -> [Detection])] = []
    if let coreml {
        for units in coreml.units {
            let detector = try await Rig.loadCoreML(coreml, units: units, rig: "detect")
            configs.append(("coreml/\(units.label)", { try await detector.detect(in: $0) }))
        }
    } else {
        print("compute persons: \(full.computeDeviceNote)  (Vision picks; setComputeDevice not called)")
        print("compute faces:   \(faces.computeDeviceNote)")
        configs = [
            ("full", { try await full.detect(in: $0) }),
            ("upper", { try await upper.detect(in: $0) }),
            ("faces", { try await faces.detect(in: $0) }),
            ("full+faces", { let r = try await detectPersonsAndFaces(in: $0, persons: full, faces: faces); return r.persons + r.faces }),
        ]
    }
    var table = ["config      side   p50 ms   p95 ms  found"]
    for side in sides {
        let buffer = Rig.pixelBuffer(Rig.resized(frame, longSide: side))
        for (name, run) in configs {
            for _ in 0..<5 { _ = try await run(buffer) }
            var samples: [Double] = []
            var found: [Detection] = []
            for _ in 0..<iterations {
                let start = ContinuousClock.now
                found = try await run(buffer)
                samples.append(Rig.ms(start.duration(to: .now)))
            }
            let p50 = Rig.percentile(samples, 0.5), p95 = Rig.percentile(samples, 0.95)
            // min approximates the uncontended cost when other agents load the machine; p50/p95 are the real numbers.
            print("detect_ms config=\(name) side=\(side) p50=\(Rig.f1(p50)) p95=\(Rig.f1(p95)) min=\(Rig.f1(samples.min() ?? 0)) n=\(iterations) found=\(found.count)")
            table.append("\(name.padding(toLength: 11, withPad: " ", startingAt: 0)) \(String(side).padding(toLength: 5, withPad: " ", startingAt: 0)) \(Rig.f1(p50).leftPad(8)) \(Rig.f1(p95).leftPad(8))  \(found.count)")
            if dump != nil {
                for d in found {
                    print("  box config=\(name) side=\(side) x=\(Int(d.box.x)) y=\(Int(d.box.y)) w=\(Int(d.box.width)) h=\(Int(d.box.height)) conf=\(String(format: "%.2f", d.confidence))")
                }
            }
        }
    }
    print(table.joined(separator: "\n"))
}

/// Shared helpers for the detect and recall rigs (ImageIO + CoreGraphics). The window/stream half lives in RigSupport.swift.
nonisolated extension Rig {
    // ponytail: source-tree only (#filePath), fine for a dev rig; pass --photos / --images to override.
    static let benchDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Bench")

    static var chip: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var chars = [UInt8](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &chars, &size, nil, 0)
        return String(decoding: chars.prefix { $0 != 0 }, as: UTF8.self).replacingOccurrences(of: " ", with: "_")
    }

    static func value(for flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// `--detector coreml:<path>` [`--units all,ane`] [`--threshold 0.3`]; nil when no --detector (Vision baseline).
    static func coreMLModel(in args: [String]) -> CoreMLOptions? {
        guard let spec = value(for: "--detector", in: args) else { return nil }
        guard spec.hasPrefix("coreml:") else { print("unknown --detector \(spec); use coreml:<path.mlmodelc|mlpackage>"); exit(2) }
        let units = (value(for: "--units", in: args) ?? "all,ane").split(separator: ",").map { name -> (label: String, value: MLComputeUnits) in
            switch name {
            case "all": return ("all", .all)
            case "ane": return ("ane", .cpuAndNeuralEngine)
            case "gpu": return ("gpu", .cpuAndGPU)
            case "cpu": return ("cpu", .cpuOnly)
            default: print("unknown --units \(name); use all|ane|gpu|cpu"); exit(2)
            }
        }
        return CoreMLOptions(url: URL(fileURLWithPath: String(spec.dropFirst("coreml:".count))), units: units,
                             threshold: Float(value(for: "--threshold", in: args) ?? "") ?? 0.3)
    }

    /// Loads the detector for `units` (the first --units entry by default) and prints the load time (compile + load).
    static func loadCoreML(_ options: CoreMLOptions, units: (label: String, value: MLComputeUnits)? = nil, rig: String) async throws -> CoreMLPersonDetector {
        let units = units ?? options.units[0]
        let start = ContinuousClock.now
        let detector = try await CoreMLPersonDetector(contentsOf: options.url, computeUnits: units.value, threshold: options.threshold)
        print("\(rig)_load_ms detector=\(options.label) units=\(units.label) input=\(Int(detector.inputSize.width))x\(Int(detector.inputSize.height)) threshold=\(options.threshold) ms=\(f1(ms(start.duration(to: .now))))")
        return detector
    }

    static func loadImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw RigError("cannot decode \(url.path)") }
        return image
    }

    static func images(in dir: URL) throws -> [CGImage] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return try names.sorted().filter { ["jpg", "jpeg", "png"].contains(($0 as NSString).pathExtension.lowercased()) }
            .map { try loadImage(dir.appendingPathComponent($0)) }
    }

    /// BGRA8 bitmap context, the pixel layout SCStream delivers.
    static func bgraContext(width: Int, height: Int, data: UnsafeMutableRawPointer? = nil, bytesPerRow: Int = 0) -> CGContext {
        CGContext(
            data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    }

    static func resized(_ image: CGImage, longSide: Int) -> CGImage {
        let scale = Double(longSide) / Double(max(image.width, image.height))
        let w = max(1, Int((Double(image.width) * scale).rounded())), h = max(1, Int((Double(image.height) * scale).rounded()))
        let ctx = bgraContext(width: w, height: h)
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// Light page background, header band, then a 3-column grid of photos scaled to fit their cells.
    static func compose(_ photos: [CGImage], width: Int, height: Int) -> CGImage {
        let ctx = bgraContext(width: width, height: height)
        ctx.setFillColor(CGColor(gray: 0.96, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(gray: 0.20, alpha: 1))
        ctx.fill(CGRect(x: 0, y: height - 80, width: width, height: 80))
        let cols = 3, rows = (photos.count + cols - 1) / cols, gutter = 40
        let cellW = (width - (cols + 1) * gutter) / cols
        let cellH = (height - 80 - (rows + 1) * gutter) / rows
        for (i, photo) in photos.enumerated() {
            let cx = gutter + (i % cols) * (cellW + gutter)
            let cy = gutter + (rows - 1 - i / cols) * (cellH + gutter)
            let s = min(Double(cellW) / Double(photo.width), Double(cellH) / Double(photo.height))
            let w = Double(photo.width) * s, h = Double(photo.height) * s
            ctx.draw(photo, in: CGRect(x: Double(cx) + (Double(cellW) - w) / 2, y: Double(cy) + (Double(cellH) - h) / 2, width: w, height: h))
        }
        return ctx.makeImage()!
    }

    /// IOSurface-backed 32BGRA buffer, like an SCStream frame.
    static func pixelBuffer(_ image: CGImage) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, attrs, &buffer)
        let pb = buffer!
        CVPixelBufferLockBaseAddress(pb, [])
        let ctx = bgraContext(width: image.width, height: image.height, data: CVPixelBufferGetBaseAddress(pb), bytesPerRow: CVPixelBufferGetBytesPerRow(pb))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    /// Debug aid for public benchmark images only; never call with captured screen pixels.
    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw RigError("cannot create \(url.path)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw RigError("cannot write \(url.path)") }
    }

    static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    /// Nearest-rank percentile; `p` in [0, 1].
    static func percentile(_ samples: [Double], _ p: Double) -> Double {
        let sorted = samples.sorted()
        return sorted[min(sorted.count - 1, Int(p * Double(sorted.count - 1)))]
    }

    static func f1(_ x: Double) -> String { String(format: "%.1f", x) }
    static func pct(_ hit: Int, _ total: Int) -> String { total == 0 ? "n/a" : String(format: "%.1f", 100 * Double(hit) / Double(total)) }
}

extension String {
    func leftPad(_ n: Int) -> String { String(repeating: " ", count: max(0, n - count)) + self }
}

/// `--detector coreml:<path>` for the detect and recall rigs.
struct CoreMLOptions {
    var url: URL
    var units: [(label: String, value: MLComputeUnits)]
    var threshold: Float
    var label: String { "coreml:\(url.lastPathComponent)" }
}
