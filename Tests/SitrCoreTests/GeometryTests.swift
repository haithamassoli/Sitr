import Testing
@testable import SitrCore

private func close(_ a: Rect, _ b: Rect, tolerance: Double = 1e-9) -> Bool {
    abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
}

@Test func retinaTwoXConversion() {
    // Built-in display: 1280x832 pt, captured at native 2560x1664 px (scaleFactor 2, contentScale 1).
    // Vision reports a person in the lower-left quarter, normalized with a bottom-left origin.
    let normalized = Rect(x: 0.25, y: 0.5, width: 0.5, height: 0.25)
    let pixels = normalized.visionNormalizedToPixels(in: Size(width: 2560, height: 1664))
    #expect(close(pixels, Rect(x: 640, y: 416, width: 1280, height: 416)))  // y flips: top edge at (1 - 0.75) * 1664
    let points = pixels.pixelsToDisplayPoints(scaleFactor: 2, contentRect: Rect(x: 0, y: 0, width: 1280, height: 832))
    #expect(close(points, Rect(x: 320, y: 208, width: 640, height: 208)))
}

@Test func retinaScaledStreamConversion() {
    // Same display, stream scaled to 1280x832 (contentScale 0.5): effective pixels per point = 2 * 0.5 = 1.
    let pixels = Rect(x: 0.25, y: 0.5, width: 0.5, height: 0.25).visionNormalizedToPixels(in: Size(width: 1280, height: 832))
    let points = pixels.pixelsToDisplayPoints(scaleFactor: 2 * 0.5, contentRect: Rect(x: 0, y: 0, width: 1280, height: 832))
    #expect(close(points, Rect(x: 320, y: 208, width: 640, height: 208)))
}

@Test func oneXSecondaryDisplayConversion() {
    // 1920x1080 external display at 1x whose content rect starts at (1280, 0) in display points.
    let normalized = Rect(x: 0, y: 0, width: 0.5, height: 1)  // left half, full height
    let pixels = normalized.visionNormalizedToPixels(in: Size(width: 1920, height: 1080))
    #expect(close(pixels, Rect(x: 0, y: 0, width: 960, height: 1080)))
    let points = pixels.pixelsToDisplayPoints(scaleFactor: 1, contentRect: Rect(x: 1280, y: 0, width: 1920, height: 1080))
    #expect(close(points, Rect(x: 1280, y: 0, width: 960, height: 1080)))
}

@Test func fullFrameRoundTrip() {
    let full = Rect(x: 0, y: 0, width: 1, height: 1).visionNormalizedToPixels(in: Size(width: 2560, height: 1664))
    #expect(close(full, Rect(x: 0, y: 0, width: 2560, height: 1664)))
}

@Test func iou() {
    let a = Rect(x: 0, y: 0, width: 2, height: 2)
    #expect(a.iou(a) == 1)
    #expect(a.iou(Rect(x: 5, y: 5, width: 1, height: 1)) == 0)
    #expect(abs(a.iou(Rect(x: 1, y: 0, width: 2, height: 2)) - 1.0 / 3.0) < 1e-9)  // overlap 2, union 6
    #expect(a.iou(Rect(x: 2, y: 0, width: 2, height: 2)) == 0)  // touching edges do not overlap
    #expect(Rect(x: 0, y: 0, width: 0, height: 0).iou(a) == 0)
}

@Test func rectHelpers() {
    let r = Rect(x: 10, y: 20, width: 30, height: 40)
    #expect(r.maxX == 40 && r.maxY == 60 && r.midX == 25 && r.midY == 40 && r.area == 1200)
    #expect(r.contains(x: 25, y: 40) && r.contains(x: 10, y: 20) && !r.contains(x: 41, y: 40))
    #expect(close(r.intersection(Rect(x: 30, y: 50, width: 100, height: 100)), Rect(x: 30, y: 50, width: 10, height: 10)))
}
