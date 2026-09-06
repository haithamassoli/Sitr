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
        case protected, disabled, needsPermission, degraded
        case paused(until: Date)

        var text: String {
            switch self {
            case .protected: "Protected"
            case .paused(let until): "Paused until \(until.formatted(date: .omitted, time: .shortened))"
            case .disabled: "Disabled"
            case .needsPermission: "Needs Screen Recording permission"
            case .degraded: "Degraded"
            }
        }

        /// FR7 icon: dimmed for the user's own Paused / Disabled, warning badge for Degraded / Needs permission.
        var iconState: IconState {
            switch self {
            case .protected: .normal
            case .paused, .disabled: .dimmed
            case .needsPermission, .degraded: .warning
            }
        }

        /// Reveal Hold only makes sense while covers are produced with healthy capture.
        var revealAvailable: Bool { self == .protected }
    }

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
        didSet { if policy != oldValue { onPolicyChanged?(policy) } }
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
        // ponytail: M2 = Entire Mac Blur; M4-T01 onboarding switches the default to Off. Until then a missing rules.json
        // seeds Blur in memory only (nothing is written), so onboarding can still tell a first launch from a saved choice.
        let rules = FileManager.default.fileExists(atPath: rulesStore.fileURL.path) ? rulesStore.load() : Rules(defaultMode: .blur)
        policy = Policy(hiddenSet: preferences.hiddenSet, strictMode: preferences.strictMode, rules: rules)
        hotkey = HotkeyManager(combo: preferences.hotkey)
        hotkey.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkey.onRelease = { [weak self] in self?.hotkeyReleased() }
        observe(NSWorkspace.didWakeNotification, on: NSWorkspace.shared.notificationCenter) { $0.refreshTimers() }
        observe(NSApplication.didResignActiveNotification) { $0.reveal.lostRelease() }
        observe(NSApplication.willTerminateNotification) { $0.hotkey.unregister() }
    }

    // MARK: Status

    var status: Status { Self.status(for: policy, now: CACurrentMediaTime(), wallClock: .now) }
    var statusText: String { status.text }
    var iconState: IconState { status.iconState }
    var revealAvailable: Bool { status.revealAvailable }

    /// Pure FR7 mapping. Needs permission outranks everything (nothing is covered and only the user can fix it), then
    /// the user's Disabled / Paused, then Degraded. An elapsed pause counts as active, like `Policy.isProtecting`.
    nonisolated static func status(for policy: Policy, now: Double, wallClock: Date) -> Status {
        if policy.health == .needsPermission { return .needsPermission }
        switch policy.protection {
        case .disabled: return .disabled
        case .paused(let until) where until > now: return .paused(until: wallClock.addingTimeInterval(until - now))
        default: return policy.health == .degraded ? .degraded : .protected
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
    /// The capture filter that stops capturing Off apps is M3-T03; until it lands, Off only removes covers.
    func updateRules(_ edit: (inout Rules) -> Void) {
        var rules = policy.rules
        edit(&rules)
        guard rules != policy.rules else { return }
        policy.rules = rules
        do {
            try rulesStore.save(rules)
        } catch {
            log.error("rules save failed: \(error.localizedDescription, privacy: .public)")
        }
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
