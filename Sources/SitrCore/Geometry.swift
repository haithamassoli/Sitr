// Pure-Swift geometry. No CoreGraphics/Vision types in the API so Policy, Tracker and tests stay platform-free.
//
// Coordinate spaces used across Sitr:
//   normalized  Vision output: unit square, origin bottom-left, y up.
//   pixels      capture buffer pixels, origin top-left, y down (what SCStream delivers and what detectors return).
//   points      display points, origin top-left of the captured content, y down (what NSPanel layers want).

public struct Size: Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct Rect: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var area: Double { max(0, width) * max(0, height) }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= minX && px <= maxX && py >= minY && py <= maxY
    }

    /// Overlap with `other`; zero-sized rect at the origin when they do not overlap.
    public func intersection(_ other: Rect) -> Rect {
        let x0 = max(minX, other.minX), y0 = max(minY, other.minY)
        let x1 = min(maxX, other.maxX), y1 = min(maxY, other.maxY)
        guard x1 > x0, y1 > y0 else { return Rect(x: 0, y: 0, width: 0, height: 0) }
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Intersection over union in [0, 1]; 0 when either rect is empty.
    public func iou(_ other: Rect) -> Double {
        let inter = intersection(other).area
        let union = area + other.area - inter
        return union > 0 ? inter / union : 0
    }

    /// Vision normalized rect (bottom-left origin) → capture pixels (top-left origin) for a buffer of `size`.
    public func visionNormalizedToPixels(in size: Size) -> Rect {
        Rect(
            x: x * size.width,
            y: (1 - y - height) * size.height,
            width: width * size.width,
            height: height * size.height)
    }

    /// Capture pixels → display points. `scaleFactor` is pixels per point of the capture buffer
    /// (SCStreamFrameInfo `scaleFactor` × `contentScale`: 2 on Retina at native size, 1 at 1× or when the
    /// stream is scaled to point size). `contentRect` is the frame's content rect in points; its origin is added.
    public func pixelsToDisplayPoints(scaleFactor: Double, contentRect: Rect) -> Rect {
        Rect(
            x: contentRect.x + x / scaleFactor,
            y: contentRect.y + y / scaleFactor,
            width: width / scaleFactor,
            height: height / scaleFactor)
    }
}
