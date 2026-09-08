import AppKit
import CoreVideo
import QuartzCore
import SitrCore
import SitrDetect
import Synchronization
import Testing

@testable import Sitr

@MainActor @Suite(.serialized) struct ImprovementTests {
    private func model(_ directory: URL) -> AppModel {
        AppModel(preferences: Preferences(defaults: UserDefaults(suiteName: directory.lastPathComponent)!),
                 rulesStore: RulesStore(directory: directory))
    }

    @Test func statusReportsReadinessAndScopeWithoutDependingOnDetections() {
        let now = Date()
        var policy = Policy(hiddenSet: .everyone)
        #expect(AppModel.status(for: policy, now: 0, wallClock: now) == .noApps)
        #expect(!policy.rules.hasMonitoredApps)
        policy.rules.defaultMode = .blur
        #expect(policy.rules.hasMonitoredApps)
        let states: [(AppModel.Readiness, AppModel.Status)] = [
            (.preparing, .preparing), (.ready, .protected), (.waitingForApps, .waitingForApps),
            (.recovering, .recovering), (.modelUnavailable, .modelUnavailable),
            (.detectionFailed, .detectionFailed), (.updatingRules, .updatingRules),
        ]
        for (readiness, expected) in states {
            #expect(AppModel.status(for: policy, now: 0, wallClock: now, readiness: readiness) == expected)
        }
        policy.protection = .disabled
        #expect(AppModel.status(for: policy, now: 0, wallClock: now, readiness: .recovering) == .disabled)
        policy.health = .needsPermission
        #expect(AppModel.status(for: policy, now: 0, wallClock: now) == .needsPermission)
        policy.protection = .active
        #expect(policy.processingEnabled(at: 0), "Permission recovery must still consume a fresh frame")
    }

    @Test func failedSaveAndCorruptRulesHaveRecoverableUIState() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SitrImprovements-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults.standard.removePersistentDomain(forName: directory.lastPathComponent)
        }
        let model = model(directory)
        // A file where the directory should be makes atomic persistence fail deterministically.
        try Data().write(to: directory)
        model.updateRules { $0.defaultMode = .curtain }
        #expect(model.rulesProblem != nil && model.policy.rules.defaultMode == .curtain)
        try FileManager.default.removeItem(at: directory)
        model.saveRules()
        #expect(model.rulesProblem == nil)
        #expect(try model.rulesStore.loadChecked().defaultMode == .curtain)

        try Data("broken rules".utf8).write(to: model.rulesStore.fileURL)
        model.reloadRules()
        #expect(model.rulesProblem != nil)
        let restored = self.model(directory)
        #expect(restored.rulesNeedRecovery && restored.rulesProblem != nil)
        restored.updateRules { $0.defaultMode = .blur }
        #expect(try String(contentsOf: restored.rulesStore.fileURL, encoding: .utf8) == "broken rules")
        restored.resetRules()
        #expect(!restored.rulesNeedRecovery && restored.rulesProblem == nil)
        #expect(try restored.rulesStore.loadChecked() == Rules())
        #expect(try String(contentsOf: restored.rulesStore.backupURL, encoding: .utf8) == "broken rules")
    }

    @Test func failedRelaunchAndLoginRegistrationKeepTheAppUsable() {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SitrImprovements-\(UUID())")
        let model = model(directory)
        defer { UserDefaults.standard.removePersistentDomain(forName: directory.lastPathComponent) }
        var terminated = false
        model.finishRelaunch(error: CocoaError(.executableNotLoadable)) { terminated = true }
        #expect(!terminated && model.relaunchProblem != nil)
        model.finishRelaunch(error: nil) { terminated = true }
        #expect(terminated && model.relaunchProblem == nil)
        OnboardingWindow.registerLaunchAtLogin(model: model) { throw CocoaError(.fileWriteNoPermission) }
        #expect(model.loginProblem != nil)
        OnboardingWindow.registerLaunchAtLogin(model: model) {}
        #expect(model.loginProblem == nil)
    }

    @Test func unchangedPreviewsDoNotRenderAndResetPreservesRules() {
        let view = PreviewView()
        view.render(style: .solid, strength: 0.7, padding: 0.15)
        view.render(style: .solid, strength: 0.7, padding: 0.15)
        #expect(view.renderCount == 1)
        view.render(style: .solid, strength: 0.7, padding: 0.2)
        #expect(view.renderCount == 2)
        let directory = FileManager.default.temporaryDirectory.appending(path: "SitrImprovements-\(UUID())")
        let model = model(directory)
        defer { UserDefaults.standard.removePersistentDomain(forName: directory.lastPathComponent) }
        model.policy.rules.defaultMode = .curtain
        model.preferences.coverStyle = .solid
        model.preferences.bodyPadding = 0.4
        model.resetAppearance()
        #expect(model.preferences.coverStyle == .gaussian && model.preferences.bodyPadding == 0.15)
        #expect(model.policy.rules.defaultMode == .curtain)
    }

    @Test func repeatedInferenceFailuresAreVisibleAndRecover() {
        let meter = DetectionMeter()
        for second in 0...4 { meter.recordFailure(display: 1, at: Double(second)) }
        #expect(meter.hasFailures && meter.isDegraded)
        for second in 5...11 { meter.record(display: 1, seconds: 0.05, at: Double(second)) }
        #expect(!meter.hasFailures && !meter.isDegraded)
        meter.recordFailure(display: 2, at: 0)
        meter.recordFailure(display: 2, at: 4)
        meter.forget(display: 2)
        #expect(!meter.hasFailures)
    }

}

extension RobustnessTests {
    @Test func pauseStopsStreamsAndResumeDoesNotOverrideSleep() {
        let manager = DisplayManager(permission: PermissionMonitor())
        manager.simulatedScreens = [ScreenSnapshot(id: 9999, frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 1)]
        manager.start()
        defer { manager.stop() }
        let session = manager.displays[0].session
        #expect(session.isConnected)
        manager.processingEnabled = false
        #expect(!session.isConnected)
        manager.suspendCapture()
        manager.processingEnabled = true
        #expect(!session.isConnected)
        manager.resumeCapture()
        #expect(session.isConnected)
    }

    @Test(arguments: ["pause", "rules", "capture"])
    func staleDetectionCannotCommitAfterInvalidation(reason: String) async throws {
        let (frames, continuation) = AsyncStream.makeStream(of: Frame.self, bufferingPolicy: .bufferingNewest(1))
        let panel = OverlayPanel(screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let detector = HeldDetector()
        let validity = Mutex(true)
        var policy = Policy(hiddenSet: .everyone, rules: Rules(defaultMode: .blur))
        let pipeline = Pipeline(displayID: 1, frames: frames, panel: panel, renderer: CoverRenderer(),
                                policy: policy, appearance: CoverAppearance(style: .solid), detector: detector)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 100, 100, kCVPixelFormatType_32BGRA, nil, &buffer)
        let frame = Frame(pixelBuffer: try #require(buffer), displayID: 1,
                          isCurrent: { validity.withLock { $0 } }, sequence: 1, timestamp: CACurrentMediaTime(), dirtyRects: [],
                          contentRect: .zero, scaleFactor: 1, contentScale: 1, displaySize: CGSize(width: 100, height: 100))
        await pipeline.start()
        continuation.yield(frame)
        for _ in 0..<100 {
            if await detector.waiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await detector.waiting)
        switch reason {
        case "pause": policy.protection = .disabled; pipeline.update(policy)
        case "rules": policy.rules.defaultMode = .off; pipeline.update(policy)
        default: validity.withLock { $0 = false }
        }
        await detector.release()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await pipeline.metrics.framesOut == 0)
        #expect(panel.layerCount == 0)
        if reason == "pause" {
            continuation.yield(frame)
            try await Task.sleep(for: .milliseconds(50))
            #expect(await detector.calls == 1, "Paused frames must not invoke inference")
        }
        policy.protection = .active
        policy.rules.defaultMode = .blur
        pipeline.update(policy)
        let fresh = Frame(pixelBuffer: frame.pixelBuffer, displayID: 1, sequence: 2, timestamp: CACurrentMediaTime(), dirtyRects: [],
                          contentRect: .zero, scaleFactor: 1, contentScale: 1, displaySize: frame.displaySize)
        continuation.yield(fresh)
        for _ in 0..<100 {
            if await detector.waiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await detector.release()
        for _ in 0..<100 where panel.layerCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(panel.layerCount == 1, "Fresh capture must resume protection")
        policy.protection = .disabled
        pipeline.update(policy)
        for _ in 0..<100 where panel.layerCount != 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(panel.layerCount == 0, "Clearing must compare against the layers actually on screen")
        await pipeline.stop()
        continuation.finish()
        panel.close()
    }
}

private actor HeldDetector: PersonDetecting {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    var waiting: Bool { continuation != nil }
    func detect(in frame: Frame) async throws -> [Detection] {
        guard frame.sequence != 0 else { return [] } // warm-up
        calls += 1
        await withCheckedContinuation { continuation = $0 }
        return [Detection(box: Rect(x: 10, y: 10, width: 70, height: 80), confidence: 1)]
    }
    func release() { continuation?.resume(); continuation = nil }
}
