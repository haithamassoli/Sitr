// M4-T01 unit tests: the pure onboarding flow (steps per chosen feature, Strict forced for Everyone, finish outcome for
// hiding vs music only, the permission-only reopen), the rules seed for a missing rules.json with and without SITR_DEV_BLUR, the
// reopen-on-needs-permission trigger, and what `AppModel.completeOnboarding` stores.
import Foundation
import SitrCore
import Testing

@testable import Sitr

@Suite struct OnboardingFlowTests {
    @Test func stepsFollowTheChosenFeatures() {
        var flow = OnboardingFlow()
        #expect(flow.step == .welcome && !flow.canContinue && !flow.finished && !flow.permissionOnly)  // nothing preselected
        flow.wantsHide = true
        #expect(flow.steps == [.welcome, .hiddenSet, .permission, .done])
        flow.wantsMusic = true
        #expect(flow.steps == [.welcome, .hiddenSet, .permission, .music, .done] && flow.stepCount == 5)
        flow.wantsHide = false
        #expect(flow.steps == [.welcome, .music, .done])  // music only: no Screen Recording request
        flow.back()  // no step before welcome
        #expect(flow.step == .welcome)
    }

    @Test func continueRulesPerStep() {
        var flow = OnboardingFlow()
        flow.advance()  // welcome needs a feature
        #expect(flow.step == .welcome)
        flow.wantsHide = true
        flow.advance()
        #expect(flow.step == .hiddenSet && !flow.canContinue && flow.hiddenSet == nil)  // no preselection
        flow.advance()
        #expect(flow.step == .hiddenSet)
        flow.hiddenSet = .men
        flow.advance()
        #expect(flow.step == .permission && !flow.canContinue && flow.stepNumber == 3)
        flow.advance()  // Return without the grant: nothing happens
        #expect(flow.step == .permission)
        flow.permissionGranted = true
        flow.advance()
        #expect(flow.step == .done && flow.canContinue && flow.isLast && !flow.finished)
        flow.back()
        #expect(flow.step == .permission)
        flow.advance()
        flow.advance()
        #expect(flow.finished && flow.step == .done)
    }

    @Test func musicOnlySkipsThePermissionAndWatchesNothing() {
        var flow = OnboardingFlow()
        flow.wantsMusic = true
        flow.advance()
        #expect(flow.step == .music && flow.canContinue)
        flow.advance()
        #expect(flow.step == .done)
        flow.advance()
        #expect(flow.finished)
        let rules = flow.rulesOnFinish(Rules(defaultMode: .blur))
        #expect(rules == Rules(defaultMode: .off) && rules?.hasMonitoredApps == false)
    }

    @Test func skipForNowMovesOnWithoutTheGrant() {
        var flow = OnboardingFlow()
        flow.skipPermission()  // only on the permission step
        #expect(flow.step == .welcome)
        flow.wantsHide = true
        flow.wantsMusic = true
        flow.step = .permission
        flow.skipPermission()
        #expect(flow.step == .music && !flow.permissionGranted)
    }

    @Test func strictIsOnByDefaultAndForcedForEveryone() {
        var flow = OnboardingFlow()
        #expect(flow.strict && flow.effectiveStrict && !flow.strictLocked)
        flow.strict = false
        flow.hiddenSet = .women
        #expect(!flow.effectiveStrict && !flow.strictLocked)
        flow.hiddenSet = .everyone
        #expect(flow.effectiveStrict && flow.strictLocked)  // shown on and disabled
        flow.hiddenSet = .men
        #expect(!flow.effectiveStrict)  // the user's own choice comes back
    }

    @Test func finishWithHidingAppliesThePresetAndKeepsTheDefaultRuleOff() {
        var flow = OnboardingFlow(permissionGranted: true)
        flow.wantsHide = true
        flow.hiddenSet = .women
        let rules = flow.rulesOnFinish(Rules(defaultMode: .blur, overrides: [AppRule(bundleID: "com.example.Other", mode: .off)]))
        #expect(rules?.defaultMode == .off)
        #expect(rules.map(RecommendedPreset.isApplied) == true)
        #expect(rules?.mode(for: "com.example.Other") == .off)  // existing overrides survive
        #expect(flow.registersLaunchAtLogin)  // default on
        flow.launchAtLogin = false
        #expect(!flow.registersLaunchAtLogin)
    }

    @Test func permissionOnlyReopenIsThePermissionStepAlone() {
        var flow = OnboardingFlow(permissionOnly: true)
        #expect(flow.step == .permission && flow.stepCount == 1 && flow.isLast && !flow.canContinue)
        flow.back()
        #expect(flow.step == .permission)
        #expect(flow.rulesOnFinish(Rules(defaultMode: .blur)) == nil)  // rules untouched
        #expect(!flow.registersLaunchAtLogin)
        var skipped = flow
        skipped.skipPermission()
        #expect(skipped.finished)
        flow.permissionGranted = true
        flow.advance()
        #expect(flow.finished)
    }

    @Test(arguments: [
        (completed: false, env: [String: String](), mode: RuleMode.off),
        (completed: false, env: ["SITR_DEV_BLUR": "1"], mode: .blur),
        (completed: false, env: ["SITR_DEV_BLUR": "0"], mode: .off),
        (completed: true, env: ["SITR_DEV_BLUR": "1"], mode: .off),
        (completed: true, env: [String: String](), mode: .off),
    ])
    func missingRulesFileSeeds(completed: Bool, env: [String: String], mode: RuleMode) {
        #expect(OnboardingFlow.seedDefaultMode(onboardingCompleted: completed, environment: env) == mode)
    }

    @Test func reopensOnlyWhenTheStatusBecomesNeedsPermission() {
        #expect(OnboardingFlow.reopens(from: .ok, to: .needsPermission))
        #expect(OnboardingFlow.reopens(from: .degraded, to: .needsPermission))
        #expect(!OnboardingFlow.reopens(from: .needsPermission, to: .needsPermission))
        #expect(!OnboardingFlow.reopens(from: .needsPermission, to: .ok))
        #expect(!OnboardingFlow.reopens(from: .ok, to: .degraded))
    }

    @Test func devStepParsing() {
        #expect(OnboardingFlow.Step(devValue: "2") == .hiddenSet)
        #expect(OnboardingFlow.Step(devValue: "5") == .done)
        #expect(OnboardingFlow.Step(devValue: "6") == nil)
        #expect(OnboardingFlow.Step(devValue: "x") == nil)
        #expect(OnboardingFlow.Step(devValue: nil) == nil)
        #expect(OnboardingFlow(step: .music).step == .music && OnboardingFlow(step: .music).steps.contains(.music))
    }
}

@MainActor @Suite struct OnboardingModelTests {
    private let suite = "SitrTests.\(UUID().uuidString)"
    private let directory = FileManager.default.temporaryDirectory.appending(path: "SitrTests-\(UUID().uuidString)")
    private var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
    private var store: RulesStore { RulesStore(directory: directory) }

    private func makeModel() -> AppModel { AppModel(preferences: Preferences(defaults: defaults), rulesStore: store) }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func firstLaunchSeedsOffWithoutWritingAndIsNotCompleted() {
        let model = makeModel()
        #expect(!model.preferences.onboardingCompleted)
        #expect(model.policy.rules == Rules(defaultMode: .off))  // the test process has no SITR_DEV_BLUR
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(!AppModel.showsOnboarding)  // never a window from the test runner
        cleanUp()
    }

    @Test func completingStoresChoicesRulesAndTheFlag() {
        let model = makeModel()
        var flow = OnboardingFlow(permissionGranted: true)
        flow.wantsHide = true
        flow.advance()
        flow.hiddenSet = .women
        flow.strict = false
        flow.advance()
        flow.advance()
        flow.advance()
        #expect(flow.finished)
        model.completeOnboarding(flow)
        #expect(model.preferences.onboardingCompleted)
        #expect(model.policy.hiddenSet == .women && !model.policy.effectiveStrict)
        #expect(model.policy.rules.defaultMode == .off && RecommendedPreset.isApplied(model.policy.rules))
        #expect(store.load() == model.policy.rules)  // rules.json written
        let reloaded = makeModel()  // a fresh process reads the file and the flag
        #expect(reloaded.preferences.onboardingCompleted && reloaded.policy.rules == model.policy.rules)
        #expect(reloaded.policy.hiddenSet == .women && !reloaded.policy.effectiveStrict)
        cleanUp()
    }

    @Test func skippingThePermissionLeavesNeedsPermissionWithTheWarningIcon() {
        let model = makeModel()
        model.policy.health = .needsPermission  // what Runtime sets without the grant
        var flow = OnboardingFlow()
        flow.wantsHide = true
        flow.advance()
        flow.hiddenSet = .everyone
        flow.advance()
        flow.skipPermission()
        flow.advance()
        model.completeOnboarding(flow)
        #expect(model.status == .needsPermission && model.iconState == .warning && !model.revealAvailable)
        #expect(model.policy.hiddenSet == .everyone && model.policy.effectiveStrict)
        cleanUp()
    }

    @Test func musicOnlyNeverShowsThePermissionWarning() {
        let model = makeModel()
        model.policy.health = .needsPermission  // no grant, and none asked for
        var flow = OnboardingFlow()
        flow.wantsMusic = true
        flow.advance()
        flow.advance()
        flow.advance()
        model.completeOnboarding(flow)
        #expect(flow.finished && model.status == .noApps && model.iconState == .dimmed)
        #expect(!model.policy.rules.hasMonitoredApps)
        cleanUp()
    }

    @Test func permissionOnlyCompletionChangesNothingButKeepsTheFlag() {
        let model = makeModel()
        model.preferences.onboardingCompleted = true
        model.updateRules { $0.defaultMode = .curtain }
        var flow = OnboardingFlow(permissionOnly: true)
        flow.skipPermission()
        model.completeOnboarding(flow)
        #expect(model.preferences.onboardingCompleted)
        #expect(model.policy.rules.defaultMode == .curtain && model.policy.hiddenSet == .everyone)
        cleanUp()
    }
}
