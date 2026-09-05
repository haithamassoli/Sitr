// M2 track A unit tests: permission transitions, display diff, coordinate flip, cover geometry and strength curves.
import CoreGraphics
import ScreenCaptureKit
import Testing
@testable import Sitr

// MARK: - M2-T03 PermissionLogic

@Test func permissionPreflightTransitions() {
    typealias S = PermissionMonitor.State
    #expect(PermissionLogic.transition(from: .unknown, preflight: true) == S.granted)
    #expect(PermissionLogic.transition(from: .unknown, preflight: false) == S.denied)
    #expect(PermissionLogic.transition(from: .denied, preflight: false) == S.denied)
    #expect(PermissionLogic.transition(from: .denied, preflight: true) == S.granted)
    #expect(PermissionLogic.transition(from: .granted, preflight: true) == S.granted)
    #expect(PermissionLogic.transition(from: .granted, preflight: false) == S.revoked)  // revoke
    #expect(PermissionLogic.transition(from: .revoked, preflight: false) == S.revoked)
    #expect(PermissionLogic.transition(from: .revoked, preflight: true) == S.granted)  // re-grant
}

@Test func permissionStreamErrorTransitions() {
    typealias S = PermissionMonitor.State
    // Revocation-class error and TCC agrees → revoked.
    #expect(PermissionLogic.transition(from: .granted, streamErrorIsRevocation: true, preflight: false) == S.revoked)
    // Revocation-class error but TCC still says yes (stopped from the recording indicator) → stays granted, session restarts.
    #expect(PermissionLogic.transition(from: .granted, streamErrorIsRevocation: true, preflight: true) == S.granted)
    // Transient errors never touch the state.
    #expect(PermissionLogic.transition(from: .granted, streamErrorIsRevocation: false, preflight: false) == S.granted)
    #expect(PermissionLogic.transition(from: .revoked, streamErrorIsRevocation: false, preflight: true) == S.revoked)
}

@Test func streamErrorClassification() {
    func error(_ code: SCStreamError.Code) -> Error { NSError(domain: SCStreamErrorDomain, code: code.rawValue) }
    #expect(PermissionLogic.isRevocation(error(.userStopped)))
    #expect(PermissionLogic.isRevocation(error(.userDeclined)))
    #expect(PermissionLogic.isRevocation(error(.systemStoppedStream)))
    #expect(PermissionLogic.isRevocation(error(.noCaptureSource)))
    #expect(!PermissionLogic.isRevocation(error(.attemptToStopStreamState)))
    #expect(!PermissionLogic.isRevocation(error(.failedApplicationConnectionInterrupted)))
    #expect(!PermissionLogic.isRevocation(NSError(domain: "other", code: -3817)))
}

// MARK: - M2-T04 DisplayDiff

@Test func displayDiffAddRemoveKeep() {
    let r = DisplayDiff.compute(current: [1, 2, 3], desired: [2, 3, 4])
    #expect(r == DisplayDiff.Result(add: [4], remove: [1], keep: [2, 3]))
    #expect(DisplayDiff.compute(current: [], desired: [7]) == DisplayDiff.Result(add: [7], remove: [], keep: []))
    #expect(DisplayDiff.compute(current: [7], desired: []) == DisplayDiff.Result(add: [], remove: [7], keep: []))
    #expect(DisplayDiff.compute(current: [1, 2], desired: [2, 1]) == DisplayDiff.Result(add: [], remove: [], keep: [2, 1]))
    #expect(DisplayDiff.compute(current: [], desired: []) == DisplayDiff.Result())
}

// MARK: - M2-T10 coordinate flip

@Test func appKitFlip() {
    // 1470×956 pt display: a 400×300 cover whose top-left is (535, 328) sits 328 pt below the top edge → AppKit y = 956 - 628.
    let cover = CGRect(x: 535, y: 328, width: 400, height: 300)
    #expect(appKitRect(cover, displayHeight: 956) == CGRect(x: 535, y: 328, width: 400, height: 300))  // symmetric here: centred vertically
    let top = CGRect(x: 0, y: 0, width: 100, height: 50)
    #expect(appKitRect(top, displayHeight: 956) == CGRect(x: 0, y: 906, width: 100, height: 50))
    let bottom = CGRect(x: 10, y: 906, width: 100, height: 50)
    #expect(appKitRect(bottom, displayHeight: 956) == CGRect(x: 10, y: 0, width: 100, height: 50))
    // Flipping twice is the identity.
    #expect(appKitRect(appKitRect(top, displayHeight: 956), displayHeight: 956) == top)
}

// MARK: - M2-T11 CoverGeometry

@Test func paddingExpandsAndClamps() {
    let display = CGSize(width: 1470, height: 956)
    let base = CGRect(x: 100, y: 100, width: 200, height: 400)
    #expect(CoverGeometry.padded(base, padding: 0, display: display) == base)
    #expect(CoverGeometry.padded(base, padding: 0.15, display: display) == CGRect(x: 85, y: 70, width: 230, height: 460))
    #expect(CoverGeometry.padded(base, padding: 0.5, display: display) == CGRect(x: 50, y: 0, width: 300, height: 600))
    // Out-of-range padding is clamped to 0…0.5.
    #expect(CoverGeometry.padded(base, padding: 2, display: display) == CGRect(x: 50, y: 0, width: 300, height: 600))
    #expect(CoverGeometry.padded(base, padding: -1, display: display) == base)
    // Clamp to the display at the right edge and the top.
    let edge = CGRect(x: 1370, y: 0, width: 200, height: 400)
    #expect(CoverGeometry.padded(edge, padding: 0.5, display: display) == CGRect(x: 1320, y: 0, width: 150, height: 500))
}

@Test func strengthCurvesMatchTheSpike() {
    // docs/spike/blur.md: 60 px face → radius 10.2 / 24.1 / 30 px and block 12 / 24.6 / 30 px at 0 / 70 / 100 %.
    #expect(abs(CoverGeometry.gaussianRadius(strength: 0, face: 60) - 10.2) < 0.01)
    #expect(abs(CoverGeometry.gaussianRadius(strength: 0.7, face: 60) - 24.06) < 0.01)
    #expect(abs(CoverGeometry.gaussianRadius(strength: 1, face: 60) - 30) < 0.01)
    #expect(abs(CoverGeometry.pixelBlock(strength: 0, face: 60) - 12) < 0.01)
    #expect(abs(CoverGeometry.pixelBlock(strength: 0.7, face: 60) - 24.6) < 0.01)
    #expect(abs(CoverGeometry.pixelBlock(strength: 1, face: 60) - 30) < 0.01)
    // Strength outside 0…1 is clamped.
    #expect(CoverGeometry.gaussianRadius(strength: 5, face: 60) == CoverGeometry.gaussianRadius(strength: 1, face: 60))
    // Face estimate: a 180×444 body box (60 px face, 3 f wide) → 60; a wide merged box does not triple it; never below 8.
    #expect(CoverGeometry.faceEstimate(cover: CGSize(width: 180, height: 444)) == 60)
    #expect(CoverGeometry.faceEstimate(cover: CGSize(width: 900, height: 180)) == 60)
    #expect(CoverGeometry.faceEstimate(cover: CGSize(width: 3, height: 3)) == 8)
}

// MARK: - M2-T05 Frame coordinate helpers (pure parts)

@Test func frameCoordinateHelpers() throws {
    // 1280×832 buffer for a 1470×956 pt display: pixel (640, 416) is the display centre (735, 478).
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, 1280, 832, kCVPixelFormatType_32BGRA, nil, &pb)
    let buffer = try #require(pb)
    // A full-frame dirty rect arrives in buffer pixels (1280×832), not in content points (640×416).
    let f = Frame(pixelBuffer: buffer, displayID: 1, sequence: 1, timestamp: 0, dirtyRects: [CGRect(x: 0, y: 0, width: 1280, height: 832)],
                  contentRect: CGRect(x: 0, y: 0, width: 640, height: 416), scaleFactor: 2, contentScale: 0.4351, displaySize: CGSize(width: 1470, height: 956))
    #expect(abs(f.pointsPerPixel - 1470.0 / 1280.0) < 1e-9)
    let centre = f.pixelsToDisplayPoints(CGRect(x: 640, y: 416, width: 0, height: 0))
    #expect(abs(centre.minX - 735) < 1e-9 && abs(centre.minY - 477.75) < 1e-9)
    let back = f.displayPointsToPixels(centre)
    #expect(abs(back.minX - 640) < 1e-9 && abs(back.minY - 416) < 1e-9)
    // Pixels → display points via the isotropic points-per-pixel (1470/1280); the buffer height (832, rounded from the
    // long-side scale) maps to 955.55, close enough to the 956 pt display height that the 0.5 px rounding never shows.
    let dp = try #require(f.dirtyRectsInDisplayPoints.first)
    #expect(abs(dp.width - 1470) < 1e-6 && abs(dp.height - 832 * 1470.0 / 1280.0) < 1e-6)
}
