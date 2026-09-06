// M2-T11: Gaussian / Pixelate / Solid covers. Blur styles crop the padded region from the captured frame, clamp the edges,
// filter, and render through one Metal CIContext into an IOSurface-backed CVPixelBuffer the panel shows zero-copy
// (docs/spike/blur.md: 1–4 ms; `createCGImage` would be 3–16 ms). One renderer per display.
import AppKit
import CoreImage
import CoreVideo
import Metal

enum CoverStyle: String, CaseIterable, Sendable {
    case gaussian, pixelate, solid
}

/// Pure cover geometry and the spike's strength curves. Unit-tested.
nonisolated enum CoverGeometry {
    /// Body Padding: grows the box by `padding` × its size (0…0.5, default 0.15; half on each side), clamped to the display.
    static func padded(_ rect: CGRect, padding: Double, display: CGSize) -> CGRect {
        let p = min(0.5, max(0, padding))
        return rect.insetBy(dx: -rect.width * p / 2, dy: -rect.height * p / 2)
            .intersection(CGRect(origin: .zero, size: display))
    }

    /// Gaussian sigma in source pixels for strength `s` (0…1) and face size `face` px: f × (0.17 + 0.33 s).
    static func gaussianRadius(strength s: Double, face: Double) -> Double { face * (0.17 + 0.33 * min(1, max(0, s))) }

    /// Pixel block in source pixels: f × (0.20 + 0.30 s).
    static func pixelBlock(strength s: Double, face: Double) -> Double { face * (0.20 + 0.30 * min(1, max(0, s))) }

    /// M4-T09: how much smaller than capture resolution a Gaussian cover is rendered. A Gaussian of σ carries no detail finer
    /// than about σ, so blurring a crop reduced by `k` with σ/k and letting the layer scale it back (`contentsGravity .resize`)
    /// is the same picture for 1/k² of the pixels and a k× narrower kernel — the spike says so outright ("cap the radius or blur
    /// a 2–4× downsampled crop (visually identical)", docs/spike/blur.md §1). `k` keeps at least 4 samples per σ and never
    /// exceeds 4, so the reduction can only ever *remove* detail the blur was going to remove anyway.
    static func blurDownscale(sigma: Double) -> Int {
        sigma >= 16 ? 4 : sigma >= 8 ? 2 : 1
    }

    /// Face-size estimate for a body cover in pixels.
    // ponytail: a body box carries no face size, so estimate it as min(width, height) ÷ 3: shoulders span ≈ 3 face widths for
    // full-body and upper-body boxes alike (docs/spike/blur.md §2), and min() keeps wide merged boxes from tripling the radius;
    // height ÷ 3 would over-blur a full-body box 2.5×. Upgrade = pass the tracked face height when a face was assigned.
    static func faceEstimate(cover: CGSize) -> Double { max(8, min(cover.width, cover.height) / 3) }
}

nonisolated final class CoverRenderer: @unchecked Sendable {
    private let context: CIContext
    // ponytail: one renderer per display, driven by that display's pipeline serially, so plain vars and no lock. Upgrade = Mutex.
    nonisolated(unsafe) private var pools: [Int: CVPixelBufferPool] = [:]
    nonisolated(unsafe) private var poolOrder: [Int] = []
    nonisolated(unsafe) private(set) var solidColor: CGColor

    @MainActor init() {
        context = MTLCreateSystemDefaultDevice().map { CIContext(mtlDevice: $0, options: [.cacheIntermediates: false]) } ?? CIContext()
        solidColor = Self.systemSolidColor()
    }

    /// Re-resolves the Solid color after a light/dark switch (callers observe `NSApplication.effectiveAppearance`).
    @MainActor func refreshSolidColor() { solidColor = Self.systemSolidColor() }

    /// `NSColor.windowBackgroundColor` under the app's effective appearance: neutral, opaque, follows light/dark.
    @MainActor private static func systemSolidColor() -> CGColor {
        var color = CGColor(gray: 0.5, alpha: 1)
        NSApplication.shared.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.windowBackgroundColor.cgColor
        }
        return color
    }

    /// One cover submitted to the GPU: the spec to show if the task succeeds, the Solid spec to show if it does not, and the
    /// task itself (nil when nothing was submitted — Solid style, or a cover thinner than one pixel).
    // M4-T09: a cover's GPU work is *started* here and waited for in `finish`, so a frame's covers queue on the GPU together
    // instead of one `waitUntilCompleted` stall each (the stall was 1.0 s of the 30 s browsing profile, 7 covers × one round trip).
    struct Prepared {
        let spec: CoverLayerSpec
        let solid: CoverLayerSpec
        let task: CIRenderTask?
    }

    /// One cover. `rect` = body box in display-local points (origin top-left); `strength` 0…1 (FR3 default 0.7); `padding` 0…0.5.
    /// Solid returns a color only; Gaussian / Pixelate return pixels at capture resolution. Never throws: a failed render
    /// (or a cover thinner than one pixel) falls back to Solid so the person is covered either way.
    func render(id: Int, style: CoverStyle, strength: Double, padding: Double = 0.15, rect: CGRect, frame: Frame) -> CoverLayerSpec {
        finish([prepare(id: id, style: style, strength: strength, padding: padding, rect: rect, frame: frame)])[0]
    }

    /// Every cover of one frame: all GPU tasks are submitted, then waited for once. Index-aligned with `covers`.
    func render(_ covers: [(id: Int, style: CoverStyle, rect: CGRect)], strength: Double, padding: Double, frame: Frame) -> [CoverLayerSpec] {
        finish(covers.map { prepare(id: $0.id, style: $0.style, strength: strength, padding: padding, rect: $0.rect, frame: frame) })
    }

    /// Builds the filter graph and submits it; the surface is not complete until `finish` waits for the task.
    func prepare(id: Int, style: CoverStyle, strength: Double, padding: Double = 0.15, rect: CGRect, frame: Frame) -> Prepared {
        let cover = CoverGeometry.padded(rect, padding: padding, display: frame.displaySize)
        let solid = CoverLayerSpec(id: id, frame: cover, contents: nil, color: solidColor)
        guard style != .solid else { return Prepared(spec: solid, solid: solid, task: nil) }
        let bufferRect = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        let px = frame.displayPointsToPixels(cover).integral.intersection(bufferRect)
        guard px.width >= 1, px.height >= 1 else { return Prepared(spec: solid, solid: solid, task: nil) }
        // Core Image's origin is bottom-left; row 0 of the buffer is the top of the screen.
        let ci = CGRect(x: px.minX, y: bufferRect.height - px.maxY, width: px.width, height: px.height)
        let source = CIImage(cvPixelBuffer: frame.pixelBuffer).cropped(to: ci).clampedToExtent()  // clamped: no transparent fade at the edges
        let face = CoverGeometry.faceEstimate(cover: px.size)
        let filtered: CIImage
        // Region the task renders, and the buffer size behind it: capture resolution, except for a big Gaussian, which is
        // rendered reduced by `k` and stretched back by the layer (`CoverGeometry.blurDownscale`).
        var out = ci
        switch style {
        case .gaussian:
            let sigma = CoverGeometry.gaussianRadius(strength: strength, face: face)
            let k = Double(CoverGeometry.blurDownscale(sigma: sigma))
            if k > 1 {
                out = CGRect(x: ci.minX / k, y: ci.minY / k, width: max(1, (ci.width / k).rounded()), height: max(1, (ci.height / k).rounded()))
                filtered = source.transformed(by: CGAffineTransform(scaleX: 1 / k, y: 1 / k)).applyingGaussianBlur(sigma: sigma / k)
            } else {
                filtered = source.applyingGaussianBlur(sigma: sigma)
            }
        case .pixelate:
            filtered = source.applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: CoverGeometry.pixelBlock(strength: strength, face: face),
                kCIInputCenterKey: CIVector(x: ci.minX, y: ci.minY),
            ])
        case .solid:
            return Prepared(spec: solid, solid: solid, task: nil)
        }
        do {
            let buffer = try pixelBuffer(width: Int(out.width), height: Int(out.height))
            let task = try context.startTask(toRender: filtered.cropped(to: out), from: out, to: CIRenderDestination(pixelBuffer: buffer), at: .zero)
            return Prepared(spec: CoverLayerSpec(id: id, frame: cover, contents: buffer, color: nil), solid: solid, task: task)
        } catch {
            return Prepared(spec: solid, solid: solid, task: nil)
        }
    }

    /// Waits for every submitted task, then hands back the specs (Solid wherever the GPU failed) — the surfaces are complete
    /// before the panel shows them.
    func finish(_ prepared: [Prepared]) -> [CoverLayerSpec] {
        prepared.map { p in
            guard let task = p.task else { return p.spec }
            do {
                try task.waitUntilCompleted()
                return p.spec
            } catch {
                return p.solid
            }
        }
    }

    /// IOSurface-backed BGRA buffer from a per-size pool (a cover's size is stable for many frames once tracking settles).
    private func pixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        let key = width << 16 | height
        let pool: CVPixelBufferPool
        if let existing = pools[key] {
            pool = existing
        } else {
            var created: CVPixelBufferPool?
            let attributes: [CFString: Any] = [
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created) == kCVReturnSuccess, let created else {
                throw RenderError.pool
            }
            if poolOrder.count >= 16 { pools[poolOrder.removeFirst()] = nil }  // bounded: moving covers change size every frame
            pools[key] = created
            poolOrder.append(key)
            pool = created
        }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { throw RenderError.buffer }
        return buffer
    }
}

nonisolated enum RenderError: Error {
    case pool, buffer
}
