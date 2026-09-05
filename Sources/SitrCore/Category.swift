// PRD FR2 category rule as a pure function. Sizes are in capture pixels (what the detectors return); the classifier's
// P(woman) comes from SitrDetect (M2-T07). Pure so every branch is unit-tested without a model.

/// Who a detected person is, per the PRD Definitions table.
public enum Category: Hashable, Sendable, Codable {
    case woman, man, unknown
}

extension Category {
    /// A face whose short side is below this (capture pixels) is too small to classify.
    public static let minFaceSide: Double = 32
    /// A body shorter than this (capture pixels) is too small to classify.
    public static let minBodyHeight: Double = 40
    /// P(woman) at or above this is a woman.
    public static let minWomanProbability: Double = 0.80
    /// P(woman) at or below this is a man. Kept as its own literal (not `1 - minWomanProbability`) so the 0.20
    /// boundary compares exactly in floating point. Between the two, max(p, 1 − p) < 0.80 → unknown.
    public static let maxManProbability: Double = 0.20
}

/// No assigned face, face short side < 32 px, body height < 40 px, no classifier output, or
/// max(p, 1 − p) < 0.80 → `.unknown`; otherwise `.woman` (p ≥ 0.80) or `.man` (p ≤ 0.20).
public func categorize(face: Size?, body: Size, pWoman: Double?) -> Category {
    guard let face, min(face.width, face.height) >= Category.minFaceSide,
        body.height >= Category.minBodyHeight, let p = pWoman
    else { return .unknown }
    if p >= Category.minWomanProbability { return .woman }
    if p <= Category.maxManProbability { return .man }
    return .unknown
}
