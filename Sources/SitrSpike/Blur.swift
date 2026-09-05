// M1-T07: CIGaussianBlur / CIPixellate cost per cover (one Metal CIContext, reused) and the strength → radius / block curves,
// anchored by an objective "unrecognizable" proxy (Vision finds neither a face rectangle nor landmarks) over 5 CC0 faces.
import AppKit
import CoreImage
import UniformTypeIdentifiers
import Vision

/// Strength 0–100 % → Gaussian radius / pixel block in source pixels, relative to the face height.
/// 0 % sits well above the proxy minimum measured for a 60 px face (radius 5 px → 10 px, block 4 px → 12 px = 5 blocks across
/// the face; see docs/spike/blur.md), because Vision stops detecting long before a human stops recognizing.
/// The 3-reviewer human check is pending.
func gaussianRadius(strength: Double, face: Double) -> Double { face * (0.17 + 0.33 * strength / 100) }
func pixelBlock(strength: Double, face: Double) -> Double { face * (0.20 + 0.30 * strength / 100) }

/// CC0 portraits on Wikimedia Commons (Unsplash imports). Downloaded into Bench/data/faces (gitignored) on first run.
let faceFiles = [
    "Face portrait (Unsplash).jpg",                 // William Stitt
    "Into the Deep (Unsplash).jpg",                 // JD Mason
    "Confident Eye Contact (Unsplash).jpg",         // Tanja Heffner
    "Karen Elder (Unsplash).jpg",                   // zjtcpts
    "Experience brings character. (Unsplash).jpg",  // Alex Harvey
]

@MainActor
func runBlur(_ args: [String]) {
    if args.contains("--help") {
        print("usage: sitr-spike blur [--iterations N=200] [--faces DIR=Bench/data/faces] [--dump DIR] [--skip-cost] [--skip-curve]")
        print("  --dump DIR writes the blurred face crops (photo fixtures, never screen pixels) for the human reviewers")
        exit(0)
    }
    let iterations = option(args, "--iterations", default: 200)
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let facesDir = URL(fileURLWithPath: option(args, "--faces") ?? repo.appendingPathComponent("Bench/data/faces").path)
    let dump = option(args, "--dump").map { URL(fileURLWithPath: $0) }
    Rig.boot()
    Rig.deadline(600, "blur")
    Rig.run {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RigError("no Metal device") }
        let context = CIContext(mtlDevice: device)
        let fixture = try loadCGImage(URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/person.jpg"))

        if !args.contains("--skip-cost") {
            guard let face = try await largestFace(in: fixture) else { throw RigError("no face in fixture") }
            // Host layer on screen so the commit really ships the contents to the render server (CGImage = copy, IOSurface = zero-copy).
            let d = mainDisplayBounds()
            let host = Rig.panel(NSRect(x: d.width - 380, y: 40, width: 360, height: 420), level: .screenSaver, color: .darkGray)
            host.ignoresMouseEvents = true
            let layer = CALayer()
            layer.frame = CGRect(x: 10, y: 10, width: 340, height: 400)
            layer.contentsGravity = .resizeAspect
            host.contentView!.layer!.addSublayer(layer)
            host.orderFrontRegardless()
            let frameSize = CGSize(width: 1280, height: 832)  // capture space at the PRD long side
            for f in [60.0, 120.0, 240.0] {
                let (frame, faceInFrame) = try renderFrame(fixture, face: face, targetFace: f, size: frameSize, context: context)
                let cover = CGRect(x: faceInFrame.midX - 1.5 * f, y: faceInFrame.maxY + 0.4 * f - 7.4 * f, width: 3 * f, height: 7.4 * f)
                    .intersection(CGRect(origin: .zero, size: frameSize)).integral
                let surface = try makePixelBuffer(Int(cover.width), Int(cover.height))
                for style in ["gaussian", "pixellate"] {
                    let param = style == "gaussian" ? gaussianRadius(strength: 70, face: f) : pixelBlock(strength: 70, face: f)
                    for output in ["cgimage", "iosurface"] {
                        let t = try measure(iterations) {
                            let img = coverImage(CIImage(cvPixelBuffer: frame), in: cover, style: style, param: param)
                            CATransaction.begin()
                            CATransaction.setDisableActions(true)
                            if output == "cgimage" {
                                guard let cg = context.createCGImage(img, from: cover) else { throw RigError("render failed") }
                                layer.contents = cg
                            } else {
                                // startTask + wait = GPU work included; plain render(to:) returns before the GPU is done.
                                try context.startTask(toRender: img, from: cover, to: CIRenderDestination(pixelBuffer: surface), at: .zero).waitUntilCompleted()
                                layer.contents = CVPixelBufferGetIOSurface(surface)?.takeUnretainedValue()
                            }
                            CATransaction.commit()
                            CATransaction.flush()
                        }
                        print("blur_cost style=\(style) output=\(output) face_px=\(Int(f)) cover=\(Int(cover.width))x\(Int(cover.height)) "
                            + "param=\(String(format: "%.1f", param)) p50_ms=\(ms(t.p50)) p95_ms=\(ms(t.p95)) n=\(iterations)")
                    }
                }
            }
            host.orderOut(nil)
        }

        if !args.contains("--skip-curve") {
            try FileManager.default.createDirectory(at: facesDir, withIntermediateDirectories: true)
            if let dump { try FileManager.default.createDirectory(at: dump, withIntermediateDirectories: true) }
            var faces: [(Int, CGImage, CGRect)] = []
            for (i, name) in faceFiles.enumerated() {
                let file = facesDir.appendingPathComponent("face\(i).jpg")
                if !FileManager.default.fileExists(atPath: file.path) { try await download(name, to: file) }
                let img = try loadCGImage(file)
                guard let face = try await largestFace(in: img) else { print("blur_face i=\(i) skipped: no face found in \(name)"); continue }
                print("blur_face i=\(i) file=\"\(name)\" image=\(img.width)x\(img.height) face_px=\(Int(face.height))")
                faces.append((i, img, face))
            }
            let radii: [Double] = [1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 20, 25, 30]
            let blocks: [Double] = [2, 3, 4, 5, 6, 8, 10, 12, 15, 20, 30]
            // 60 px is the PRD case; 120 px (values scaled ×2) separates "blur destroyed the face" from "Vision is at its size floor".
            for h in [60.0, 120.0] {
                var crops: [(Int, CGImage)] = []
                for (i, img, face) in faces {
                    let crop = try faceCrop(img, face: face, faceHeight: h, context: context)
                    let base = try await faceProxy(crop)
                    if let dump { try writePNG(crop, to: dump.appendingPathComponent("face\(i)_\(Int(h))px_original.png")) }
                    print("blur_baseline face_px=\(Int(h)) face=\(i) crop=\(crop.width)x\(crop.height) face_found=\(base.face) landmarks=\(base.landmarks)"
                        + (base.face ? "" : " EXCLUDED"))
                    if base.face { crops.append((i, crop)) }
                }
                for (style, values) in [("gaussian", radii), ("pixellate", blocks)] {
                    var minimum = 0.0
                    for (i, crop) in crops {
                        var failFrom: Double?  // smallest value from which the proxy holds for every larger value
                        var detectedAt: [Int] = []
                        let src = CIImage(cgImage: crop)
                        for v in values {
                            let param = v * h / 60
                            let img = coverImage(src, in: src.extent, style: style, param: param)
                            guard let cg = context.createCGImage(img, from: src.extent) else { throw RigError("render failed") }
                            if let dump { try writePNG(cg, to: dump.appendingPathComponent("face\(i)_\(Int(h))px_\(style)_\(Int(param)).png")) }
                            let p = try await faceProxy(cg)
                            if p.face || p.landmarks { detectedAt.append(Int(param)); failFrom = nil } else if failFrom == nil { failFrom = param }
                        }
                        print("blur_proxy_\(style) face_px=\(Int(h)) face=\(i) unrecognizable_from=\(failFrom.map { String(Int($0)) } ?? ">\(Int(values.last! * h / 60))") "
                            + "still_detected_at=\(detectedAt)")
                        minimum = max(minimum, failFrom ?? .infinity)
                    }
                    let key = style == "gaussian" ? "radius" : "block"
                    print("blur_min_\(key)_px face_px=\(Int(h)) value=\(minimum) equiv_60px=\(minimum * 60 / h) faces=\(crops.count) proxy=no_face_rect_and_no_landmarks")
                }
            }
            let at60 = { (s: Double) in String(format: "%.1f/%.1f", gaussianRadius(strength: s, face: 60), pixelBlock(strength: s, face: 60)) }
            print("blur_curve gaussian_radius=face*(0.17+0.33*s) pixel_block=face*(0.20+0.30*s) s=strength/100 "
                + "radius/block_at_60px: 0%=\(at60(0)) 70%=\(at60(70)) 100%=\(at60(100))")
            print("blur_human_check 3-reviewer unrecognizability check PENDING (proxy only so far; use --dump DIR for the review set)")
        }
        Rig.finish(0)
    }
}

/// Blur or pixellate `rect` of `src`; edges clamped so the cover has no transparent border.
func coverImage(_ src: CIImage, in rect: CGRect, style: String, param: Double) -> CIImage {
    let base = src.cropped(to: rect).clampedToExtent()
    let out = style == "gaussian"
        ? base.applyingGaussianBlur(sigma: param)
        : base.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: param, kCIInputCenterKey: CIVector(x: rect.minX, y: rect.minY)])
    return out.cropped(to: rect)
}

/// `body` runs `n` timed iterations after 10 untimed warm-up iterations.
func measure(_ n: Int, _ body: () throws -> Void) throws -> (p50: Double, p95: Double) {
    var t: [Double] = []
    for i in 0..<(n + 10) {
        let a = CACurrentMediaTime()
        try body()
        if i >= 10 { t.append(CACurrentMediaTime() - a) }
    }
    return (percentile(t, 0.5), percentile(t, 0.95))
}

func loadCGImage(_ url: URL) throws -> CGImage {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        throw RigError("cannot load image \(url.path)")
    }
    return img
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw RigError("cannot write \(url.path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw RigError("cannot write \(url.path)") }
}

func makePixelBuffer(_ w: Int, _ h: Int) throws -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
    guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess, let pb else { throw RigError("CVPixelBufferCreate failed") }
    return pb
}

/// The fixture scaled so its face is `targetFace` px tall, head near the top, on a grey 1280×832 "captured frame". Returns the face rect in frame pixels.
func renderFrame(_ image: CGImage, face: CGRect, targetFace: Double, size: CGSize, context: CIContext) throws -> (CVPixelBuffer, CGRect) {
    let s = targetFace / face.height
    let tx = size.width / 2 - face.midX * s, ty = size.height - 0.5 * targetFace - face.maxY * s
    let t = CGAffineTransform(scaleX: s, y: s).concatenating(CGAffineTransform(translationX: tx, y: ty))
    let frameRect = CGRect(origin: .zero, size: size)
    let composed = CIImage(cgImage: image).transformed(by: t).composited(over: CIImage(color: .gray).cropped(to: frameRect))
    let pb = try makePixelBuffer(Int(size.width), Int(size.height))
    context.render(composed, to: pb, bounds: frameRect, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    return (pb, face.applying(t))
}

/// Face box plus one face-height of margin on every side (grey where the photo ends), scaled so the face is `faceHeight` px tall.
func faceCrop(_ image: CGImage, face: CGRect, faceHeight: Double, context: CIContext) throws -> CGImage {
    let region = face.insetBy(dx: -face.height, dy: -face.height)
    let s = faceHeight / face.height
    let t = CGAffineTransform(translationX: -region.minX, y: -region.minY).concatenating(CGAffineTransform(scaleX: s, y: s))
    let canvas = CGRect(origin: .zero, size: CGSize(width: region.width * s, height: region.height * s)).integral
    let ci = CIImage(cgImage: image).transformed(by: t).composited(over: CIImage(color: .gray).cropped(to: canvas))
    guard let out = context.createCGImage(ci, from: canvas) else { throw RigError("crop render failed") }
    return out
}

/// Largest face rectangle in image pixels (lower-left origin, matching Core Image), or nil.
func largestFace(in image: CGImage) async throws -> CGRect? {
    let size = CGSize(width: image.width, height: image.height)
    return try await DetectFaceRectanglesRequest().perform(on: image)
        .map { $0.boundingBox.toImageCoordinates(size, origin: .lowerLeft) }
        .max { $0.height < $1.height }
}

/// The unrecognizability proxy: does Vision still find a face rectangle, and does the landmarks request still produce landmarks?
func faceProxy(_ image: CGImage) async throws -> (face: Bool, landmarks: Bool) {
    let faces = try await DetectFaceRectanglesRequest().perform(on: image)
    let landmarks = try await DetectFaceLandmarksRequest().perform(on: image)
    return (!faces.isEmpty, landmarks.contains { $0.landmarks != nil })
}

/// Commons thumbnail (1200 px wide) of a file, via Special:FilePath.
func download(_ file: String, to url: URL) async throws {
    let name = file.replacingOccurrences(of: " ", with: "_")
    guard let remote = URL(string: "https://commons.wikimedia.org/w/index.php?title=Special:FilePath/\(name)&width=1200") else {
        throw RigError("bad file name \(file)")
    }
    var request = URLRequest(url: remote)
    request.setValue("SitrSpike/0.1 (dev fixture fetch)", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw RigError("download failed for \(file)") }
    try data.write(to: url)
    print("blur_download \(file) -> \(url.path) (\(data.count) bytes)")
}
