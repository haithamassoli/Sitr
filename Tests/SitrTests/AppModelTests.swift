import AppKit
import QuartzCore
import SitrCore
import Testing

@testable import Sitr

private let wall = Date(timeIntervalSince1970: 1_700_000_000)

/// Every Policy state → FR7 status, icon, and reveal availability. Media clock `now` is 50 in every row.
private let statusMatrix:
    [(protection: ProtectionState, health: Health, status: AppModel.Status, icon: AppModel.IconState, reveal: Bool)] = [
        (.active, .ok, .protected, .normal, true),
        (.paused(until: 110), .ok, .paused(until: wall.addingTimeInterval(60)), .dimmed, false),
        (.paused(until: 50), .ok, .protected, .normal, true),  // elapsed pause behaves as active
        (.disabled, .ok, .disabled, .dimmed, false),
        (.active, .needsPermission, .needsPermission, .warning, false),
        (.paused(until: 110), .needsPermission, .needsPermission, .warning, false),
        (.disabled, .needsPermission, .needsPermission, .warning, false),
        (.active, .degraded, .degraded, .warning, false),
        (.paused(until: 110), .degraded, .paused(until: wall.addingTimeInterval(60)), .dimmed, false),
        (.disabled, .degraded, .disabled, .dimmed, false),
    ]

@Suite struct StatusMappingTests {
    @Test(arguments: statusMatrix)
    func policyStateMapsToStatusIconAndReveal(
        protection: ProtectionState, health: Health, status: AppModel.Status, icon: AppModel.IconState, reveal: Bool
    ) {
        let policy = Policy(hiddenSet: .everyone, protection: protection, health: health, rules: Rules(defaultMode: .blur))
        let mapped = AppModel.status(for: policy, now: 50, wallClock: wall)
        #expect(mapped == status, "\(protection) \(health)")
        #expect(mapped.iconState == icon)
        #expect(mapped.revealAvailable == reveal)
    }

    @Test func statusTexts() {
        #expect(AppModel.Status.protected.text == "Protected")
        #expect(AppModel.Status.disabled.text == "Disabled")
        #expect(AppModel.Status.needsPermission.text == "Needs Screen Recording permission")
        #expect(AppModel.Status.degraded.text == "Degraded")
        let time = wall.formatted(date: .omitted, time: .shortened)
        #expect(AppModel.Status.paused(until: wall).text == "Paused until \(time)")
    }
}

@MainActor @Suite struct AppModelTests {
    private let suite = "SitrTests.\(UUID().uuidString)"
    private var defaults: UserDefaults { UserDefaults(suiteName: suite)! }

    private func makeModel() -> AppModel {
        let model = AppModel(preferences: Preferences(defaults: defaults), rulesStore: RulesStore(directory: FileManager.default.temporaryDirectory.appending(path: suite)))
        model.policy.rules = Rules(defaultMode: .blur)
        model.readiness = .ready
        return model
    }

    @Test func placeholderDefaultsAreEveryoneStrictProtected() {
        let model = makeModel()
        #expect(model.policy.hiddenSet == .everyone)
        #expect(model.policy.effectiveStrict)
        #expect(model.status == .protected)
        #expect(model.iconState == .normal)
        #expect(model.revealAvailable)
        #expect(model.preferences.hotkey == .default)
    }

    @Test func pauseResumeDisableEnable() throws {
        let model = makeModel()
        model.pause(minutes: 15)
        guard case .paused(let until) = model.policy.protection else { throw TestFailure("not paused") }
        #expect(abs(until - CACurrentMediaTime() - 900) < 1)
        #expect(model.iconState == .dimmed)
        #expect(!model.revealAvailable)
        #expect(model.statusText.hasPrefix("Paused until "))
        model.resume()
        #expect(model.policy.protection == .active)
        #expect(model.status == .protected)
        model.disable()
        #expect(model.status == .disabled)
        #expect(model.statusText == "Disabled")
        model.enable()
        #expect(model.policy.protection == .active)
    }

    @Test func policyChangesReachTheHook() {
        let model = makeModel()
        var seen: [Policy] = []
        model.onPolicyChanged = { seen.append($0) }
        model.setHiddenSet(.men)
        model.policy.health = .needsPermission
        model.policy.health = .needsPermission  // no change, no callback
        #expect(seen.map(\.hiddenSet) == [.men, .men])
        #expect(seen.last?.health == .needsPermission)
        #expect(model.status == .needsPermission)
        #expect(model.iconState == .warning)
    }

    @Test func autoResumesWhenThePauseElapses() async throws {
        let model = makeModel()
        model.pause(seconds: 0.2)
        #expect(model.status != .protected)
        try await Task.sleep(for: .seconds(1))
        #expect(model.policy.protection == .active)
    }

    @Test func wakeReSyncsTheMediaDeadlineToTheWallClock() throws {
        let model = makeModel()
        model.pause(seconds: 60)
        // A long sleep stalls the media clock, so the policy deadline ends up far beyond the wall-clock deadline.
        model.policy.protection = .paused(until: CACurrentMediaTime() + 1e6)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        guard case .paused(let until) = model.policy.protection else { throw TestFailure("not paused") }
        #expect(abs(until - CACurrentMediaTime() - 60) < 1)
    }

    @Test func elapsedDeadlineResumesOnRefresh() {
        // The wake path: refreshTimers() sees a wall-clock deadline that already passed and resumes at once.
        let model = makeModel()
        model.pause(seconds: -1)
        #expect(model.policy.protection == .active)
        #expect(model.status == .protected)
    }

    @Test func revealFollowsTheHotkeyOnlyWhileProtected() {
        let model = makeModel()
        var changes: [Bool] = []
        model.onRevealChanged = { changes.append($0) }
        model.hotkeyPressed()
        #expect(model.reveal.isRevealed)
        model.hotkeyPressed()  // key repeat: no second callback
        model.hotkeyReleased()
        #expect(model.reveal == .covered)
        #expect(changes == [true, false])
        model.pause(minutes: 15)
        model.hotkeyPressed()
        #expect(model.reveal == .covered)
        model.resume()
        model.policy.health = .needsPermission
        model.hotkeyPressed()
        #expect(model.reveal == .covered)
    }

    @Test func safetyTickerCoversWhenTheModifiersAreNotHeld() async throws {
        // Nobody holds ⌃⌥ in the test process, so the 100 ms poll treats the hold as a lost release.
        let model = makeModel()
        model.hotkeyPressed()
        #expect(model.reveal.isRevealed)
        // Poll instead of one fixed sleep: a loaded machine can miss a 100 ms tick inside 400 ms.
        for _ in 0..<100 where model.reveal != .covered {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(model.reveal == .covered)
    }

    @Test func hiddenSetStrictAndHotkeyPersist() {
        let model = makeModel()
        let combo = KeyCombo(keyCode: 80, carbonModifiers: 256 | 512 | 2048 | 4096)  // ⌃⌥⇧⌘F19: nobody's key
        model.setHiddenSet(.women)
        model.setStrict(false)
        model.setHotkey(combo)
        #expect(model.policy.hiddenSet == .women)
        #expect(!model.policy.effectiveStrict)
        #expect(model.hotkey.combo == combo)
        let reloaded = Preferences(defaults: defaults)
        #expect(reloaded.hiddenSet == .women)
        #expect(reloaded.strictMode == false)
        #expect(reloaded.hotkey == combo)
        defaults.removePersistentDomain(forName: suite)
    }
}

private struct TestFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
