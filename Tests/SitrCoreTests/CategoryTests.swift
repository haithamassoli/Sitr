import Testing
@testable import SitrCore

@Suite struct CategoryTests {
    let face = Size(width: 64, height: 64)
    let body = Size(width: 100, height: 200)

    @Test func noFaceIsUnknownEvenWithConfidentClassifier() {
        #expect(categorize(face: nil, body: body, pWoman: 0.99) == .unknown)
        #expect(categorize(face: nil, body: body, pWoman: 0.01) == .unknown)
    }

    @Test func faceShortSideBelow32IsUnknown() {
        #expect(categorize(face: Size(width: 31, height: 64), body: body, pWoman: 0.99) == .unknown)  // width is the short side
        #expect(categorize(face: Size(width: 64, height: 31), body: body, pWoman: 0.99) == .unknown)  // height is the short side
        #expect(categorize(face: Size(width: 32, height: 32), body: body, pWoman: 0.99) == .woman)  // boundary is inclusive
    }

    @Test func bodyHeightBelow40IsUnknown() {
        #expect(categorize(face: face, body: Size(width: 20, height: 39), pWoman: 0.99) == .unknown)
        #expect(categorize(face: face, body: Size(width: 20, height: 40), pWoman: 0.99) == .woman)
        #expect(categorize(face: face, body: Size(width: 1, height: 40), pWoman: 0.99) == .woman)  // width does not matter
    }

    @Test func missingProbabilityIsUnknown() {
        #expect(categorize(face: face, body: body, pWoman: nil) == .unknown)
    }

    @Test(arguments: [
        (1.0, Category.woman), (0.80, .woman),  // p ≥ 0.80
        (0.79, .unknown), (0.5, .unknown), (0.21, .unknown),  // max(p, 1 − p) < 0.80
        (0.20, .man), (0.0, .man),  // p ≤ 0.20
    ])
    func probabilityThresholds(pWoman: Double, expected: Category) {
        #expect(categorize(face: face, body: body, pWoman: pWoman) == expected)
    }

    @Test func thresholdsMatchPRD() {
        #expect(Category.minFaceSide == 32)
        #expect(Category.minBodyHeight == 40)
        #expect(Category.minWomanProbability == 0.80)
        #expect(Category.maxManProbability == 0.20)
    }
}
