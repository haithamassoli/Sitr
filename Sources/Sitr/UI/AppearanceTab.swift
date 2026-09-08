import AppKit
import CoreVideo
import QuartzCore
import SwiftUI

/// Settings › Appearance (M4-T02, PRD FR3): style, Blur Strength, Body Padding, bound to `Preferences` (the `Runtime`
/// observes those keys and pushes a new `CoverAppearance` to every pipeline, so the overlays follow at once), plus a
/// preview that runs the real `CoverRenderer` over a synthetic scene.
struct AppearanceTab: View {
    let model: AppModel

    private var preferences: Preferences { model.preferences }

    var body: some View {
        Form {
            Section {
                Picker("Style", selection: Binding(get: { preferences.coverStyle }, set: { preferences.coverStyle = $0 })) {
                    Text("Gaussian").tag(CoverStyle.gaussian)
                    Text("Pixelate").tag(CoverStyle.pixelate)
                    Text("Solid").tag(CoverStyle.solid)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Cover style")
                .accessibilityHint("Gaussian blurs, Pixelate blocks, Solid paints an opaque color")
                LabeledContent("Blur Strength") {
                    Slider(value: Binding(get: { preferences.blurStrength }, set: { preferences.blurStrength = $0 }), in: 0...1)
                        .accessibilityLabel("Blur Strength")
                        .accessibilityValue(percent(preferences.blurStrength))
                    Text(percent(preferences.blurStrength)).monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                .disabled(preferences.coverStyle == .solid)
                LabeledContent("Body Padding") {
                    Slider(value: Binding(get: { preferences.bodyPadding }, set: { preferences.bodyPadding = $0 }), in: 0...0.5)
                        .accessibilityLabel("Body Padding")
                        .accessibilityValue(percent(preferences.bodyPadding))
                    Text(percent(preferences.bodyPadding)).monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                Button("Reset Appearance") { model.resetAppearance() }
            } footer: {
                Text("Changes apply to the covers on screen immediately. Defaults: Gaussian, 70%, 15%. Solid ignores Blur Strength.")
            }
            Section {
                CoverPreview(style: preferences.coverStyle, strength: preferences.blurStrength, padding: preferences.bodyPadding)
                    .frame(width: 400, height: 250)  // the 480×300 pt scene scaled down; still 2 buffer px per screen px
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Preview of a cover over a sample scene")
            } header: {
                Text("Preview")
            } footer: {
                Text("A drawn sample scene, covered by the same renderer the overlay uses.")
            }
        }
        .formStyle(.grouped)
    }

    /// Locale-aware ("70%" in English, Arabic-Indic digits and ٪ under `ar`), PRD FR12.
    private func percent(_ value: Double) -> String { value.formatted(.percent.precision(.fractionLength(0))) }
}

/// The real `CoverRenderer` over `SampleScene`, shown the way `OverlayPanel` shows covers (the layer's contents is the
/// returned `CoverLayerSpec`'s IOSurface, or its solid color), so the preview is the true overlay output.
struct CoverPreview: NSViewRepresentable {
    let style: CoverStyle
    let strength: Double
    let padding: Double

    func makeNSView(context: Context) -> PreviewView { PreviewView() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PreviewView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? SampleScene.size.width, height: proposal.height ?? SampleScene.size.height)
    }

    func updateNSView(_ view: PreviewView, context: Context) {
        view.render(style: style, strength: strength, padding: padding)
    }
}

final class PreviewView: NSView {
    private let scene = SampleScene()
    private let renderer = CoverRenderer()
    private let cover = CALayer()
    private var lastAppearance: CoverAppearance?
    private(set) var renderCount = 0
    private var spec: CoverLayerSpec?  // last render; also keeps its surface out of the renderer's pool while on screen

    init() {
        super.init(frame: NSRect(origin: .zero, size: SampleScene.size))
        wantsLayer = true
        layer?.contents = CVPixelBufferGetIOSurface(scene.frame.pixelBuffer)?.takeUnretainedValue()
        layer?.contentsGravity = .resize
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        cover.contentsGravity = .resize
        layer?.addSublayer(cover)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { SampleScene.size }

    override func layout() {
        super.layout()
        place()
    }

    func render(style: CoverStyle, strength: Double, padding: Double) {
        let appearance = CoverAppearance(style: style, strength: strength, padding: padding)
        guard lastAppearance != appearance else { return }
        lastAppearance = appearance
        renderCount += 1
        spec = renderer.render(id: 1, style: style, strength: strength, padding: padding, rect: SampleScene.personRect, frame: scene.frame)
        place()
    }

    /// The cover layer where `OverlayPanel` would put it, scaled from scene points to the view's size.
    private func place() {
        guard let spec else { return }
        let k = bounds.width / SampleScene.size.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cover.frame = appKitRect(spec.frame, displayHeight: SampleScene.size.height).applying(CGAffineTransform(scaleX: k, y: k))
        if let buffer = spec.contents {
            cover.contents = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue()
            cover.backgroundColor = nil
        } else {
            cover.contents = nil
            cover.backgroundColor = spec.color
        }
        CATransaction.commit()
    }
}

/// A drawn room with one standing figure, as a `Frame` (480×300 pt at 2 px/pt, like a Retina capture). The face is 30 pt =
/// 60 px in the buffer, FR3's "60 px face" criterion for the minimum strength. No photograph, nothing third-party.
nonisolated struct SampleScene {
    static let size = CGSize(width: 480, height: 300)
    static let scale = 2.0
    /// The figure's body box in display points, what the detector would report.
    static let personRect = CGRect(x: 262, y: 66, width: 84, height: 224)

    let frame: Frame

    init() {
        let width = Int(Self.size.width * Self.scale), height = Int(Self.size.height * Self.scale)
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        // ponytail: a BGRA buffer of this size does not fail to allocate on a machine that runs the app; no error path.
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &created)
        let buffer = created!
        CVPixelBufferLockBaseAddress(buffer, [])
        if let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        {
            // Points with the origin top-left, y down (row 0 of the buffer is the top, like a captured frame).
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: Self.scale, y: -Self.scale)
            Self.draw(in: context)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        frame = Frame(pixelBuffer: buffer, displayID: 0, sequence: 1, timestamp: 0, dirtyRects: [],
                      contentRect: CGRect(origin: .zero, size: Self.size), scaleFactor: Self.scale, contentScale: 1, displaySize: Self.size)
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }

    private static func fill(_ c: CGContext, _ rect: CGRect, _ color: CGColor, radius: CGFloat = 0) {
        c.setFillColor(color)
        c.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        c.fillPath()
    }

    private static func ellipse(_ c: CGContext, _ rect: CGRect, _ color: CGColor) {
        c.setFillColor(color)
        c.fillEllipse(in: rect)
    }

    /// Wall, floor, window with a view, a framed picture, a plant, a sideboard, and the figure inside `personRect`.
    private static func draw(in c: CGContext) {
        let w = size.width, h = size.height
        fill(c, CGRect(x: 0, y: 0, width: w, height: h), rgb(0.86, 0.82, 0.76))  // wall
        fill(c, CGRect(x: 0, y: 214, width: w, height: h - 214), rgb(0.55, 0.40, 0.28))  // floor
        for i in 0..<8 {  // floorboards
            fill(c, CGRect(x: 0, y: 214 + Double(i) * 11, width: w, height: 1), rgb(0.47, 0.33, 0.22))
        }
        fill(c, CGRect(x: 0, y: 208, width: w, height: 6), rgb(0.93, 0.92, 0.90))  // skirting board
        // Window: frame, sky, hills, cross bars
        fill(c, CGRect(x: 36, y: 34, width: 150, height: 118), rgb(0.96, 0.96, 0.95), radius: 2)
        let pane = CGRect(x: 44, y: 42, width: 134, height: 102)
        fill(c, pane, rgb(0.62, 0.79, 0.94))
        c.saveGState()
        c.clip(to: pane)  // hills and sun stay inside the pane
        ellipse(c, CGRect(x: 60, y: 96, width: 120, height: 70), rgb(0.42, 0.62, 0.38))
        ellipse(c, CGRect(x: 30, y: 108, width: 100, height: 60), rgb(0.36, 0.56, 0.34))
        ellipse(c, CGRect(x: 140, y: 52, width: 22, height: 22), rgb(1, 0.95, 0.70))
        c.restoreGState()
        fill(c, CGRect(x: 109, y: 42, width: 4, height: 102), rgb(0.96, 0.96, 0.95))
        fill(c, CGRect(x: 44, y: 91, width: 134, height: 4), rgb(0.96, 0.96, 0.95))
        // Framed picture with a tiny landscape
        fill(c, CGRect(x: 400, y: 48, width: 56, height: 44), rgb(0.30, 0.22, 0.16))
        fill(c, CGRect(x: 405, y: 53, width: 46, height: 34), rgb(0.85, 0.72, 0.50))
        ellipse(c, CGRect(x: 408, y: 70, width: 40, height: 24), rgb(0.55, 0.45, 0.30))
        // Sideboard with a plant
        fill(c, CGRect(x: 380, y: 160, width: 90, height: 54), rgb(0.72, 0.60, 0.45), radius: 3)
        fill(c, CGRect(x: 380, y: 186, width: 90, height: 1), rgb(0.55, 0.45, 0.33))
        fill(c, CGRect(x: 412, y: 136, width: 26, height: 26), rgb(0.78, 0.45, 0.32), radius: 3)  // pot
        ellipse(c, CGRect(x: 404, y: 108, width: 20, height: 30), rgb(0.30, 0.55, 0.30))
        ellipse(c, CGRect(x: 418, y: 100, width: 16, height: 40), rgb(0.35, 0.62, 0.34))
        ellipse(c, CGRect(x: 428, y: 110, width: 20, height: 30), rgb(0.28, 0.50, 0.28))
        // Rug
        ellipse(c, CGRect(x: 40, y: 250, width: 190, height: 40), rgb(0.62, 0.30, 0.28))
        ellipse(c, CGRect(x: 60, y: 256, width: 150, height: 28), rgb(0.72, 0.38, 0.34))

        // The figure. Face 30 pt in diameter (60 px in the buffer), centred at x 304.
        let skin = rgb(0.87, 0.68, 0.55), hair = rgb(0.22, 0.14, 0.10), shirt = rgb(0.20, 0.42, 0.70), trousers = rgb(0.18, 0.18, 0.24)
        fill(c, CGRect(x: 268, y: 214, width: 30, height: 74), trousers, radius: 6)  // legs
        fill(c, CGRect(x: 310, y: 214, width: 30, height: 74), trousers, radius: 6)
        fill(c, CGRect(x: 262, y: 280, width: 38, height: 10), hair, radius: 4)  // shoes
        fill(c, CGRect(x: 308, y: 280, width: 38, height: 10), hair, radius: 4)
        fill(c, CGRect(x: 266, y: 122, width: 76, height: 98), shirt, radius: 12)  // torso
        fill(c, CGRect(x: 252, y: 128, width: 18, height: 80), shirt, radius: 8)  // arms
        fill(c, CGRect(x: 338, y: 128, width: 18, height: 80), shirt, radius: 8)
        ellipse(c, CGRect(x: 252, y: 200, width: 18, height: 18), skin)  // hands
        ellipse(c, CGRect(x: 338, y: 200, width: 18, height: 18), skin)
        fill(c, CGRect(x: 296, y: 108, width: 16, height: 18), skin)  // neck
        ellipse(c, CGRect(x: 289, y: 82, width: 30, height: 30), skin)  // face
        c.setFillColor(hair)  // hair cap
        c.addArc(center: CGPoint(x: 304, y: 97), radius: 15.5, startAngle: .pi, endAngle: 0, clockwise: false)
        c.fillPath()
        fill(c, CGRect(x: 288, y: 94, width: 5, height: 12), hair, radius: 2)
        fill(c, CGRect(x: 315, y: 94, width: 5, height: 12), hair, radius: 2)
        ellipse(c, CGRect(x: 296, y: 96, width: 4, height: 4), hair)  // eyes
        ellipse(c, CGRect(x: 308, y: 96, width: 4, height: 4), hair)
        c.setStrokeColor(rgb(0.60, 0.30, 0.28))  // mouth
        c.setLineWidth(1.5)
        c.addArc(center: CGPoint(x: 304, y: 102), radius: 4, startAngle: 0.2 * .pi, endAngle: 0.8 * .pi, clockwise: false)
        c.strokePath()
    }
}
