import AppKit
import Observation
import QuartzCore
import os
// Scoped: `SitrCore.Observation` (the tracker input) would shadow the Observation module inside the @Observable expansion.
import SitrCore

/// Single source of truth for the menu bar, Settings, and the pipeline (M2-T13/T14). Everything runs on the main
/// actor. Integration: the pipeline takes `Policy` snapshots from `onPolicyChanged` (or reads `policy`) and passes
/// `CACurrentMediaTime()` as `now`; overlay panels follow `onRevealChanged`; permission and capture health are written
/// straight into `policy.health`.
@Observable @MainActor final class AppModel {
    /// PRD FR7 status line. `paused(until:)` is wall clock, for "Paused until HH:MM".
    nonisolated enum Status: Hashable {
        case protected, disabled, needsPermission, degraded, preparing, noApps, waitingForApps, recovering, modelUnavailable, detectionFailed, updatingRules
        case paused(until: Date)

        /// FR7 status line, from the String Catalog (M4-T05). The pause time is formatted per locale before it is inserted.
        var text: String {
            switch self {
            case .preparing: return String(localized: "Preparing protection")
            case .noApps: return String(localized: "No apps configured")
            case .waitingForApps: return String(localized: "Waiting for a protected app")
            case .recovering: return String(localized: "Recovering screen capture")
            case .modelUnavailable: return String(localized: "Protection is limited")
            case .detectionFailed: return String(localized: "Detection needs attention")
            case .updatingRules: return String(localized: "Applying protection rules")
            case .protected: return String(localized: "Protected", comment: "Menu bar status line: protection active")
            case .paused(let until):
                let time = until.formatted(date: .omitted, time: .shortened)
                return String(localized: "Paused until \(time)", comment: "Menu bar status line; %@ is a short time such as 3:45 PM")
            case .disabled: return String(localized: "Disabled", comment: "Menu bar status line: protection disabled by the user")
            case .needsPermission: return String(localized: "Needs Screen Recording permission", comment: "Menu bar status line")
            case .degraded: return String(localized: "Degraded", comment: "Menu bar status line: detection is slow, covers may lag")
            }
        }

        /// FR7 icon: dimmed for the user's own Paused / Disabled, warning badge for Degraded / Needs permission.
        var iconState: IconState {
            switch self {
            case .protected: .normal
            case .paused, .disabled, .preparing, .noApps, .waitingForApps, .updatingRules: .dimmed
            case .needsPermission, .degraded, .recovering, .modelUnavailable, .detectionFailed: .warning
            }
        }

        /// Reveal Hold only makes sense while covers are produced with healthy capture.
        var revealAvailable: Bool { self == .protected }
    }

    nonisolated enum Readiness: Sendable {
        case preparing, ready, waitingForApps, recovering, modelUnavailable, detectionFailed, updatingRules
    }
    var readiness: Readiness = .preparing
    var rulesProblem: String?
    var rulesNeedRecovery = false
    var settingsTab: SettingsView.Tab = .general
    var showSetupSummary = false
    var loginProblem: String?
    var relaunchProblem: String?
    @ObservationIgnored var onRetryProtection: (() -> Void)?
    @ObservationIgnored var onOpenPermissionSettings: (() -> Void)?

    nonisolated enum IconState: Hashable {
        case normal, dimmed, warning
    }

    static let releasesURL = URL(string: "https://github.com/haithamassoli/Sitr/releases")!
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? SitrCore.version

    let preferences: Preferences
    let hotkey: HotkeyManager
    /// `rules.json` (M3-T01) in Application Support; inside the sandbox that is the app container's copy.
    let rulesStore: RulesStore

    var policy: Policy {
        didSet {
            if policy != oldValue {
                if !policy.isProtecting(at: CACurrentMediaTime()) { reveal.release() }
                onPolicyChanged?(policy)
            }
            // FR8: a lost grant brings the permission step back; `present` never opens a second window.
            if Self.showsOnboarding, OnboardingFlow.reopens(from: oldValue.health, to: policy.health) {
                Task { @MainActor [weak self] in if let self { OnboardingWindow.present(model: self) } }
            }
        }
    }

    var reveal: RevealState = .covered {
        didSet {
            guard reveal.isRevealed != oldValue.isRevealed else { return }
            log.info("reveal \(self.reveal.isRevealed ? "on" : "off", privacy: .public)")
            onRevealChanged?(reveal.isRevealed)
            ticker?.cancel()
            ticker = reveal.isRevealed ? Task { [weak self] in await self?.runSafetyTicker() } : nil
        }
    }

    /// Integration hooks: a `Policy` snapshot per change; `true` while all overlay panels should be hidden.
    @ObservationIgnored var onPolicyChanged: ((Policy) -> Void)?
    @ObservationIgnored var onRevealChanged: ((Bool) -> Void)?

    /// Wall-clock deadline of the current pause. The media clock (`CACurrentMediaTime`) stops during sleep, so this is
    /// the truth and `policy.protection`'s `until` is re-derived from it in `refreshTimers()`.
    @ObservationIgnored private var pauseDeadline: Date?
    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.goldentik.Sitr", category: "model")

    init(preferences: Preferences = Preferences(), rulesStore: RulesStore = RulesStore(directory: AppModel.rulesDirectory)) {
        self.preferences = preferences
        self.rulesStore = rulesStore
        // Missing rules.json: Default Rule Off (PRD), in memory only until the user changes something. SITR_DEV_BLUR=1 keeps
        // the M2 Entire-Mac Blur for pipeline selftests before onboarding has run (docs/m4/onboarding.md).
        let seed = Rules(defaultMode: OnboardingFlow.seedDefaultMode(
            onboardingCompleted: preferences.onboardingCompleted, environment: ProcessInfo.processInfo.environment))
        let rules: Rules
        do {
            rules = try rulesStore.loadChecked(defaultRules: seed)
        } catch {
            rules = seed
            rulesNeedRecovery = true
            rulesProblem = String(localized: "Saved rules could not be read. The original file is unchanged. Retry reading it or reset your rules.")
        }
        policy = Policy(hiddenSet: preferences.hiddenSet, strictMode: preferences.strictMode, rules: rules)
        hotkey = HotkeyManager(combo: preferences.hotkey)
        hotkey.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkey.onRelease = { [weak self] in self?.hotkeyReleased() }
        observe(NSWorkspace.didWakeNotification, on: NSWorkspace.shared.notificationCenter) { $0.refreshTimers() }
        observe(NSApplication.didResignActiveNotification) { $0.reveal.lostRelease() }
        observe(NSApplication.willTerminateNotification) { $0.hotkey.unregister() }
        // M4-T01: first launch opens onboarding on the next run-loop turn (the window needs the running app).
        if Self.showsOnboarding, !preferences.onboardingCompleted || OnboardingWindow.devStep != nil {
            Task { @MainActor [weak self] in if let self { OnboardingWindow.present(model: self) } }
        }
    }

    /// Onboarding UI only from inside the .app: never in the test runner or a `--selftest` run, and not in `SITR_DEV_BLUR=1`
    /// pipeline runs, which want the M2 behaviour with no windows of ours on screen.
    // ponytail: process-wide flag from bundle + arguments; Runtime (SitrApp.swift, another task's file) would be the natural owner.
    static let showsOnboarding = Bundle.main.bundleURL.pathExtension == "app" && !CommandLine.arguments.contains("--selftest")
        && ProcessInfo.processInfo.environment["SITR_DEV_BLUR"] != "1"

    /// What finishing onboarding stores: the hidden set and Strict Mode (when asked), the rules (Default Rule Off, preset
    /// overrides when chosen; `rules.json` is written), and the completed flag. Health is untouched: skipping the
    /// permission leaves the app in Needs permission with the warning icon.
    func completeOnboarding(_ flow: OnboardingFlow) {
        if let hiddenSet = flow.hiddenSet {
            setHiddenSet(hiddenSet)
            setStrict(flow.effectiveStrict)
        }
        if let rules = flow.rulesOnFinish(policy.rules) { updateRules { $0 = rules } }
        preferences.onboardingCompleted = true
        if !flow.permissionOnly { showSetupSummary = true }
    }

    // MARK: Status

    var status: Status { Self.status(for: policy, now: CACurrentMediaTime(), wallClock: .now, readiness: readiness) }
    var scopeText: String {
        if policy.rules.defaultMode == .off { return String(localized: "Selected apps") }
        return policy.rules.overrides.contains(where: { $0.mode == .off })
            ? String(localized: "All apps except overrides") : String(localized: "All apps")
    }

    var recoveryText: String? {
        switch status {
        case .needsPermission: String(localized: "Allow Screen Recording to resume detection. Curtain apps stay covered; Blur apps are uncovered.")
        case .recovering: String(localized: "Screen capture stopped. Sitr is reconnecting; Curtain apps stay covered.")
        case .modelUnavailable: String(localized: "Some detection features could not load. Category-specific protection may be less accurate; Unknown follows Strict Mode.")
        case .detectionFailed: String(localized: "Detection has repeatedly failed. Existing covers remain; new people may be missed.")
        case .degraded: String(localized: "Detection is slower than 250 ms per frame, so covers can lag until it speeds up again.")
        case .noApps: String(localized: "Add an app or use the recommended settings to start protection.")
        case .waitingForApps: String(localized: "Open an app covered by your protection rules.")
        default: nil
        }
    }

    func resetAppearance() {
        let defaults = CoverAppearance()
        preferences.coverStyle = defaults.style
        preferences.blurStrength = defaults.strength
        preferences.bodyPadding = defaults.padding
    }

    func retryProtection() { onRetryProtection?() }
    func openPermissionSettings() { onOpenPermissionSettings?() }

    var statusText: String { status.text }
    var iconState: IconState { status.iconState }
    var revealAvailable: Bool { status.revealAvailable }

    /// Pure FR7 mapping. Needs permission outranks everything (nothing is covered and only the user can fix it), then
    /// the user's Disabled / Paused, then Degraded. An elapsed pause counts as active, like `Policy.isProtecting`.
    nonisolated static func status(for policy: Policy, now: Double, wallClock: Date, readiness: Readiness = .ready) -> Status {
        if policy.health == .needsPermission { return .needsPermission }
        switch policy.protection {
        case .disabled: return .disabled
        case .paused(let until) where until > now: return .paused(until: wallClock.addingTimeInterval(until - now))
        default: break
        }
        guard policy.rules.hasMonitoredApps else { return .noApps }
        switch readiness {
        case .preparing: return .preparing
        case .waitingForApps: return .waitingForApps
        case .recovering: return .recovering
        case .modelUnavailable: return .modelUnavailable
        case .detectionFailed: return .detectionFailed
        case .updatingRules: return .updatingRules
        case .ready: return policy.health == .degraded ? .degraded : .protected
        }
    }

    // MARK: Actions

    func pause(minutes: Int) { pause(seconds: Double(minutes) * 60) }

    func pause(seconds: Double) {
        pauseDeadline = Date(timeIntervalSinceNow: seconds)
        policy.protection = .paused(until: CACurrentMediaTime() + seconds)
        refreshTimers()
    }

    func resume() {
        pauseDeadline = nil
        policy.protection = .active
        refreshTimers()
    }

    func enable() { resume() }

    func disable() {
        pauseDeadline = nil
        policy.protection = .disabled
        refreshTimers()
    }

    func setHiddenSet(_ hiddenSet: HiddenSet) {
        policy.hiddenSet = hiddenSet
        preferences.hiddenSet = hiddenSet
    }

    func setStrict(_ on: Bool) {
        policy.strictMode = on
        preferences.strictMode = on
    }

    func setHotkey(_ combo: KeyCombo) {
        hotkey.rebind(combo)
        preferences.hotkey = combo
    }

    /// `~/Library/Application Support/Sitr` (the container's, when sandboxed).
    static var rulesDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Sitr")
    }

    /// M3-T08: edits the rules in place, pushes them to the pipelines through `onPolicyChanged`, and saves `rules.json`.
    /// Runtime invalidates pending frames and applies the matching capture filter.
    func updateRules(_ edit: (inout Rules) -> Void) {
        var rules = policy.rules
        edit(&rules)
        guard rules != policy.rules else { return }
        policy.rules = rules
        saveRules()
    }

    func saveRules() {
        guard !rulesNeedRecovery else { return }
        do {
            try rulesStore.save(policy.rules)
            rulesProblem = nil
        } catch {
            rulesProblem = String(localized: "Changes apply until quit; saving failed. Retry to keep these settings.")
            log.error("rules save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func reloadRules() {
        do {
            let rules = try rulesStore.loadChecked()
            policy.rules = rules
            rulesNeedRecovery = false
            rulesProblem = nil
        } catch {
            rulesNeedRecovery = true
            rulesProblem = String(localized: "Saved rules could not be read. The original file is unchanged. Retry reading it or reset your rules.")
        }
    }

    func resetRules() {
        do {
            try rulesStore.preserveForRecovery()
            let rules = Rules()
            try rulesStore.save(rules)
            policy.rules = rules
            rulesNeedRecovery = false
            rulesProblem = nil
        } catch {
            rulesProblem = String(localized: "Rules could not be reset. Your existing files have been kept.")
        }
    }

    /// Used by both the workspace callback and its regression check.
    func finishRelaunch(error: Error?, terminate: () -> Void) {
        guard error == nil else {
            relaunchProblem = String(localized: "Sitr could not relaunch. Keep using the app and try again.")
            return
        }
        relaunchProblem = nil
        terminate()
    }

    static func checkForUpdates() { NSWorkspace.shared.open(releasesURL) }

    // MARK: Reveal Hold

    func hotkeyPressed() {
        if revealAvailable { reveal.press(at: CACurrentMediaTime()) }
    }

    func hotkeyReleased() { reveal.release() }

    /// FR5 safety, every 100 ms while revealed: the 30 s timeout via `RevealState.tick`, and a lost release when the
    /// combo's modifiers are no longer down (`NSEvent.modifierFlags` reads the hardware state without permissions).
    private func runSafetyTicker() async {
        while !Task.isCancelled, reveal.isRevealed {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            if preferences.hotkey.modifiersHeld(in: NSEvent.modifierFlags) {
                reveal.tick(now: CACurrentMediaTime())
            } else {
                log.info("reveal lost release")
                reveal.lostRelease()
            }
        }
    }

    // MARK: Timers

    /// Arms the auto-resume for the current pause. Also runs on `NSWorkspace.didWakeNotification`: a deadline that
    /// passed during sleep resumes right away, otherwise `policy.protection` is re-synced to the wall clock and the
    /// timer re-armed. Tolerates `policy.protection` set to `.paused` directly (no deadline recorded).
    func refreshTimers() {
        resumeTask?.cancel()
        resumeTask = nil
        guard case .paused(let until) = policy.protection else {
            pauseDeadline = nil
            return
        }
        let deadline = pauseDeadline ?? Date(timeIntervalSinceNow: until - CACurrentMediaTime())
        pauseDeadline = deadline
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            resume()
            return
        }
        policy.protection = .paused(until: CACurrentMediaTime() + remaining)
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            if !Task.isCancelled { self?.resume() }
        }
    }

    private func observe(
        _ name: Notification.Name, on center: NotificationCenter = .default,
        _ action: @escaping @MainActor (AppModel) -> Void
    ) {
        // queue nil: runs synchronously on the posting thread, which is main for all three notifications, so the
        // terminate handler still runs before the process exits.
        center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
    }
}
