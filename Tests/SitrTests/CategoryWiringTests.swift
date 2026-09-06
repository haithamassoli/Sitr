// M2-T07 app-side wiring: the eligibility rule before the classifier runs, the per-frame classification cap (3 faces; new and
// unknown tracks first, the rest round-robin), the no-model fallback, and the metrics fields. The live path (CoreML models on real
// frames, covers per hidden set) runs under `Sitr --selftest category`.
import CoreGraphics
import Foundation
import SitrCore
// Scoped import: the ObjC runtime's `Category` typedef (via Foundation) would otherwise make the bare name ambiguous here.
import enum SitrCore.Category
import SitrDetect
import Testing

@testable import Sitr

private func det(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Detection {
    Detection(box: Rect(x: x, y: y, width: w, height: h), confidence: 0.9)
}

@Test func classifiableNeedsAFaceOfAtLeast32pxOnABodyOfAtLeast40px() {
    let body = det(0, 0, 100, 300)
    #expect(classifiable(face: det(10, 10, 40, 40), body: body))
    #expect(!classifiable(face: nil, body: body))
    #expect(!classifiable(face: det(10, 10, 31, 40), body: body))  // short side 31
    #expect(!classifiable(face: det(10, 10, 40, 40), body: det(0, 0, 20, 39)))
    #expect(classifiable(face: det(10, 10, 32, 32), body: det(0, 0, 20, 40)))  // boundaries inclusive, like categorize
}

@Test func classificationOrderPrefersNewAndUnknownAndCapsAtThree() {
    // persons 0…5: man track, new, woman track, unknown track, new, man track
    let sticky: [Category?] = [.man, nil, .woman, .unknown, nil, .man]
    let all = [Bool](repeating: true, count: 6)
    #expect(classificationOrder(classifiable: all, sticky: sticky, round: 0) == [1, 3, 4])
    #expect(classificationOrder(classifiable: all, sticky: sticky, round: 0, limit: 1) == [1])
    // with room to spare the known tracks follow, rotated by the round so each gets its turn
    let known: [Category?] = [.man, nil, .woman, .man]
    let four = [Bool](repeating: true, count: 4)
    #expect(classificationOrder(classifiable: four, sticky: known, round: 0) == [1, 0, 2])
    #expect(classificationOrder(classifiable: four, sticky: known, round: 1) == [1, 2, 3])
    #expect(classificationOrder(classifiable: four, sticky: known, round: 2) == [1, 3, 0])
    // the urgent group rotates too, so four unknowns are not starved
    #expect(classificationOrder(classifiable: four, sticky: [nil, nil, nil, nil], round: 1) == [1, 2, 3])
    // faces the rule cannot use never reach the model
    #expect(classificationOrder(classifiable: [false, true, false], sticky: [nil, nil, nil], round: 0) == [1])
    #expect(classificationOrder(classifiable: [], sticky: [], round: 7).isEmpty)
}

@Test func noClassifierYieldsUnknownForEveryFace() async throws {
    let f = Frame(pixelBuffer: try makeBuffer(64, 64), displayID: 1, sequence: 1, timestamp: 0, dirtyRects: [], contentRect: .zero,
                  scaleFactor: 1, contentScale: 1, displaySize: CGSize(width: 64, height: 64))
    let p = await NoClassifier().pWoman(faces: [Rect(x: 0, y: 0, width: 32, height: 32), Rect(x: 10, y: 10, width: 40, height: 40)], in: f)
    #expect(p.count == 2 && p.allSatisfy { $0 == nil })
    #expect(categorize(face: Size(width: 40, height: 40), body: Size(width: 100, height: 300), pWoman: p[0]) == .unknown)
}

@Test func metricsLineCarriesClassifyAndCategoryCounts() {
    var m = PipelineMetrics()
    m.classify = [0.008, 0.010]
    m.crops = 5
    m.women = 1
    m.unknown = 2
    let line = m.line(display: 2, elapsed: 3)
    #expect(line.contains("classify_ms=10.00/10.00") && line.contains("crops=5") && line.contains("categories=w1/m0/u2"))
    m.resetWindow()
    #expect(m.classify.isEmpty && m.crops == 5)
}
