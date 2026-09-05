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

    /// One cover. `rect` = body box in display-local points (origin top-left); `strength` 0…1 (FR3 default 0.7); `padding` 0…0.5.
    /// Solid returns a color only; Gaussian / Pixelate return pixels at capture resolution. Never throws: a failed render
    /// (or a cover thinner than one pixel) falls back to Solid so the person is covered either way.
    func render(id: Int, style: CoverStyle, strength: Double, padding: Double = 0.15, rect: CGRect, frame: Frame) -> CoverLayerSpec {
        let cover = CoverGeometry.padded(rect, padding: padding, display: frame.displaySize)
        let solid = CoverLayerSpec(id: id, frame: cover, contents: nil, color: solidColor)
        guard style != .solid else { return solid }
        let bufferRect = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        let px = frame.displayPointsToPixels(cover).integral.intersection(bufferRect)
        guard px.width >= 1, px.height >= 1 else { return solid }
        // Core Image's origin is bottom-left; row 0 of the buffer is the top of the screen.
        let ci = CGRect(x: px.minX, y: bufferRect.height - px.maxY, width: px.width, height: px.height)
        let source = CIImage(cvPixelBuffer: frame.pixelBuffer).cropped(to: ci).clampedToExtent()  // clamped: no transparent fade at the edges
        let face = CoverGeometry.faceEstimate(cover: px.size)
        let filtered: CIImage
        switch style {
        case .gaussian:
            filtered = source.applyingGaussianBlur(sigma: CoverGeometry.gaussianRadius(strength: strength, face: face))
        case .pixelate:
            filtered = source.applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: CoverGeometry.pixelBlock(strength: strength, face: face),
                kCIInputCenterKey: CIVector(x: ci.minX, y: ci.minY),
            ])
        case .solid:
            return solid
        }
        do {
            let buffer = try pixelBuffer(width: Int(px.width), height: Int(px.height))
            // startTask + wait: the GPU work is included in the cost and the surface is complete before the panel shows it.
            try context.startTask(toRender: filtered.cropped(to: ci), from: ci, to: CIRenderDestination(pixelBuffer: buffer), at: .zero)
                .waitUntilCompleted()
            return CoverLayerSpec(id: id, frame: cover, contents: buffer, color: nil)
        } catch {
            return solid
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
