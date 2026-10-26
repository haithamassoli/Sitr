// M4-T01 onboarding (PRD FR8) and its M4-T11 accessibility. `OnboardingFlow` is the pure state (unit-tested),
// `OnboardingWindow` the one NSWindow + NSHostingView, `OnboardingView` the SwiftUI pages. Every literal is a String Catalog
// key (M4-T05); computed texts go through `String(localized:)`.
import AppKit
import ServiceManagement
import SitrCore
import SwiftUI
import os

/// Which step, what the user chose, and what finishing applies. The view binds to it; tests drive it without a window.
/// The first page asks what Sitr is for; the steps after it follow from that: hiding people needs who + the permission,
/// music needs the browser extension, a music-only user never sees the Screen Recording request.
nonisolated struct OnboardingFlow: Equatable, Sendable {
    nonisolated enum Step: Int, CaseIterable, Sendable {
        case welcome = 1, hiddenSet, permission, music, done

        /// `SITR_ONBOARDING_STEP=<1…5>` (dev smoke runs, docs/m4/onboarding.md).
        init?(devValue: String?) {
            guard let value = devValue, let number = Int(value), let step = Step(rawValue: number) else { return nil }
            self = step
        }
    }

    var step: Step
    /// Reopened after a completed onboarding because the grant is gone (FR8 "reopens at Needs permission"): the permission
    /// step alone; nothing else is asked again and rules are not touched.
    let permissionOnly: Bool
    var permissionGranted: Bool
    /// Welcome: the two features, nothing preselected; at least one is required.
    var wantsHide = false
    var wantsMusic = false
    /// FR8: required when hiding, no preselection.
    var hiddenSet: HiddenSet?
    var strict = true
    var launchAtLogin = true
    private(set) var finished = false

    init(permissionOnly: Bool = false, permissionGranted: Bool = false, step: Step? = nil) {
        self.permissionOnly = permissionOnly
        self.permissionGranted = permissionGranted
        self.step = step ?? (permissionOnly ? .permission : .welcome)
        if step != nil, !permissionOnly { wantsHide = true; wantsMusic = true }  // dev runs: every step is reachable
    }

    /// The pages this user walks through, in order.
    var steps: [Step] {
        if permissionOnly { return [.permission] }
        return [.welcome] + (wantsHide ? [.hiddenSet, .permission] : []) + (wantsMusic ? [.music] : []) + [.done]
    }
    var stepNumber: Int { (steps.firstIndex(of: step) ?? 0) + 1 }
    var stepCount: Int { steps.count }
    var isLast: Bool { step == steps.last }
    /// Strict Mode as applied: Everyone forces it on (PRD Definitions); the toggle then shows on and disabled.
    var effectiveStrict: Bool { hiddenSet == .everyone || strict }
    var strictLocked: Bool { hiddenSet == .everyone }

    /// Continue / Finish enabled: welcome needs a feature, the hidden set a choice, the permission the grant.
    var canContinue: Bool {
        switch step {
        case .welcome: wantsHide || wantsMusic
        case .hiddenSet: hiddenSet != nil
        case .permission: permissionGranted
        case .music, .done: true
        }
    }

    mutating func back() {
        guard !permissionOnly, let i = steps.firstIndex(of: step), i > 0 else { return }
        step = steps[i - 1]
    }

    /// Return / Continue. Does nothing while `canContinue` is false (Return cannot skip the permission); finishes on the last step.
    mutating func advance() {
        guard canContinue else { return }
        moveOn()
    }

    /// "Skip for now": on without the grant (Needs permission, warning icon, nothing covered); in a reopen it just closes.
    mutating func skipPermission() {
        guard step == .permission else { return }
        moveOn()
    }

    private mutating func moveOn() {
        if isLast {
            finished = true
        } else if let i = steps.firstIndex(of: step) {
            step = steps[i + 1]
        }
    }

    // MARK: Finish outcome

    /// Rules after finishing: the Default Rule becomes Off, and hiding adds the recommended browsers and chat apps (editable
    /// in Settings › Hide People). Without hiding nothing is watched. Nil for a permission-only reopen.
    func rulesOnFinish(_ current: Rules) -> Rules? {
        guard !permissionOnly else { return nil }
        var rules = current
        rules.defaultMode = .off
        if wantsHide { RecommendedPreset.apply(to: &rules) }
        return rules
    }

    var registersLaunchAtLogin: Bool { !permissionOnly && launchAtLogin }

    // MARK: AppModel hooks (pure)

    /// Seed for a missing `rules.json`: Off (PRD: the Default Rule's initial value). `SITR_DEV_BLUR=1` before onboarding has
    /// run keeps the M2 Entire-Mac Blur, so the pipeline selftests still cover everything.
    static func seedDefaultMode(onboardingCompleted: Bool, environment: [String: String]) -> RuleMode {
        !onboardingCompleted && environment["SITR_DEV_BLUR"] == "1" ? .blur : .off
    }

    /// The window comes back when the status becomes Needs permission (a revoked grant, FR8 step 2).
    static func reopens(from old: Health, to new: Health) -> Bool {
        new == .needsPermission && old != .needsPermission
    }
}

/// The onboarding window: opened by `AppModel` on first launch and when the status becomes Needs permission. A second
/// `present` only brings the existing window to the front. Centered, not resizable, closes on finish.
enum OnboardingWindow {
    private static var window: NSWindow?
    // ponytail: own PermissionMonitor (it only polls CGPreflightScreenCaptureAccess); Runtime's lives in SitrApp.swift,
    // another task's file. Upgrade = hand Runtime.permission in through AppModel.
    private static var permission: PermissionMonitor?
    private static let log = Logger(subsystem: "com.goldentik.Sitr", category: "onboarding")
    /// `SITR_ONBOARDING_STEP=<1…5>` (dev smoke runs): opens at that step, shows step 2 as not granted, never auto-advances,
    /// and finishing skips the Launch at login registration.
    static let devStep = OnboardingFlow.Step(devValue: ProcessInfo.processInfo.environment["SITR_ONBOARDING_STEP"])

    static func present(model: AppModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let permission = permission ?? PermissionMonitor()
        Self.permission = permission
        permission.refresh()
        let flow = OnboardingFlow(
            permissionOnly: model.preferences.onboardingCompleted && devStep == nil,
            permissionGranted: devStep == nil && permission.state == .granted,
            step: devStep)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: OnboardingView.size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.minSize = CGSize(width: 520, height: 420)
        window.contentView = NSHostingView(rootView: OnboardingView(model: model, permission: permission, flow: flow))
        window.title = String(localized: "Sitr Setup", comment: "Onboarding window title (hidden, read by accessibility)")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        Self.window = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { Self.window = nil }
        }
        log.info("onboarding open step=\(flow.step.rawValue) permission_only=\(flow.permissionOnly)")
    }

    static func close() { window?.close() }

    /// Finish, step 5: `SMAppService` registration; General › Launch at login shows the resulting status afterwards.
    static func registerLaunchAtLogin(model: AppModel, register: () throws -> Void = { try SMAppService.mainApp.register() }) {
        guard devStep == nil else { return }
        do {
            try register()
            model.loginProblem = nil
        } catch {
            model.loginProblem = String(localized: "Launch at login could not be enabled. Try again in General settings.")
            log.error("launch at login: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// The pages, one bottom bar. Return = the default button; Esc is not bound (nothing skips the permission by accident).
/// No animations (M4-T11).
struct OnboardingView: View {
    static let size = CGSize(width: 560, height: 480)

    let model: AppModel
    let permission: PermissionMonitor
    @State var flow: OnboardingFlow
    private let music = MusicService.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if flow.permissionOnly {
                    Text("Sitr needs your attention")
                } else if flow.step != .welcome {
                    let step = flow.stepNumber, count = flow.stepCount
                    Text("Step \(step) of \(count)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(height: 16, alignment: .leading)
            .padding(.bottom, 10)
            ScrollView { content.frame(maxWidth: .infinity, alignment: .leading) }
            Spacer(minLength: 12)
            buttons
        }
        .padding(.horizontal, 32)
        .padding(.top, 10)
        .padding(.bottom, 22)
        .frame(minWidth: 520, idealWidth: Self.size.width, minHeight: 420, idealHeight: Self.size.height)
        .transaction { $0.animation = nil }
        .onChange(of: permission.state, initial: true) { _, state in permissionChanged(state) }
        .onChange(of: flow.step, initial: true) { _, step in
            if step == .music, OnboardingWindow.devStep == nil { music.enabled = true }  // the helper must run for the extension to connect
        }
        .task {
            while !Task.isCancelled {
                music.refreshHelperStatus()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: Pages

    @ViewBuilder private var content: some View {
        switch flow.step {
        case .welcome:
            page(nil, Text("Welcome to Sitr")) {
                Text("What would you like Sitr to do? Choose one or both.")
                    .foregroundStyle(.secondary)
                ChoiceCard(symbol: "eye.slash", title: Text("Hide people on screen"),
                           detail: Text("Covers women, men, or everyone in your browsers and chat apps."),
                           selected: flow.wantsHide, multiple: true) { flow.wantsHide.toggle() }
                ChoiceCard(symbol: "music.note", title: Text("Remove music from videos"),
                           detail: Text("Hear speech without the music in Chrome, Edge, Brave and Arc."),
                           selected: flow.wantsMusic, multiple: true) { flow.wantsMusic.toggle() }
                Label("Everything runs on this Mac. Nothing on your screen leaves it.", systemImage: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        case .hiddenSet:
            page("person.2", Text("Who should be hidden?")) {
                ChoiceCard(symbol: "figure.stand.dress", title: Text("Women"), detail: nil,
                           selected: flow.hiddenSet == .women, multiple: false) { flow.hiddenSet = .women }
                ChoiceCard(symbol: "figure.stand", title: Text("Men"), detail: nil,
                           selected: flow.hiddenSet == .men, multiple: false) { flow.hiddenSet = .men }
                ChoiceCard(symbol: "person.3", title: Text("Everyone"), detail: Text("Includes people Sitr cannot classify."),
                           selected: flow.hiddenSet == .everyone, multiple: false) { flow.hiddenSet = .everyone }
                Toggle(isOn: Binding(get: { flow.effectiveStrict }, set: { flow.strict = $0 })) {
                    Text("Blur Unknown (Strict Mode)")
                    Text("Also hides people Sitr cannot tell apart: facing away, face hidden or too small.")
                }
                .toggleStyle(.switch)
                .disabled(flow.strictLocked)
                .accessibilityLabel("Blur Unknown, Strict Mode")
                .accessibilityHint(
                    flow.strictLocked
                        ? String(localized: "Always on while Everyone is selected", comment: "Accessibility hint for the Strict Mode toggle")
                        : String(localized: "Recommended on", comment: "Accessibility hint for the Strict Mode toggle in onboarding"))
                .padding(.top, 6)
                Text("Sitr starts with your browsers and chat apps (Safari, Chrome, Arc, Telegram, WhatsApp, Discord). Add or remove apps any time in Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .permission:
            page("rectangle.dashed.badge.record", Text("Allow Screen Recording")) {
                Text("Sitr can only cover what it can see, and macOS requires Screen Recording permission for that. The screen is analyzed on this Mac and never stored.")
                if flow.permissionGranted {
                    Label("Screen Recording is allowed.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    HStack {
                        Button("Allow Screen Recording") { permission.request() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .accessibilityHint("Shows the macOS permission dialog")
                        Button("Open System Settings") { permission.openSystemSettings() }
                            .controlSize(.large)
                            .accessibilityHint("Opens Privacy & Security, Screen & System Audio Recording")
                    }
                    Text("In System Settings, turn on Sitr under Screen & System Audio Recording. This page continues on its own.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("macOS may ask you to allow Screen Recording again. If permission is lost, Sitr shows a warning and reopens this step.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .music:
            page("music.note", Text("Add the browser extension")) {
                Text("Music removal works through a small extension in your browser. It takes about a minute.")
                if music.extensionConnected {
                    Label("Extension connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    ExtensionInstallSteps()
                }
                Text("You can also do this later in Settings › Remove Music.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .done:
            let hotkey = model.preferences.hotkey.displayString
            page("checkmark.circle", Text("You're all set")) {
                if flow.wantsHide {
                    summary("eye.slash", Text("Hiding people in your browsers and chat apps."))
                    summary("keyboard", Text("Hold \(hotkey) to reveal what is under the covers; release to cover again."))
                }
                if flow.wantsMusic {
                    summary("music.note", Text("On any video, press Remove music. Press it again to hear the original audio."))
                }
                summary("menubar.arrow.up.rectangle", Text("Sitr lives in the menu bar at the top of your screen. Turn each feature on or off from there."))
                Toggle(isOn: $flow.launchAtLogin) {
                    Text("Launch at login")
                    Text("Sitr starts as soon as you log in.")
                }
                .toggleStyle(.switch)
                .accessibilityLabel("Launch at login")
                .padding(.top, 6)
            }
        }
    }

    /// `title` is a `Text` so the call sites carry the literal (the String Catalog gate reads `Text("…")`).
    private func page(_ symbol: String?, _ title: Text, @ViewBuilder body: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 28))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                } else {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                        .accessibilityHidden(true)
                }
                title
                    .font(.title.bold())
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(.bottom, 2)
            body()
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summary(_ symbol: String, _ text: Text) -> some View {
        Label { text.fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 22)
        }
    }

    // MARK: Bottom bar

    private var buttons: some View {
        HStack {
            if !flow.permissionOnly, flow.step != .welcome {
                Button("Back") { flow.back() }
                    .accessibilityHint("Returns to the previous step")
            }
            Spacer()
            if flow.step == .permission, !flow.permissionGranted {
                Button("Skip for now") { skipPermission() }
                    .accessibilityHint("Continues without Screen Recording. Person detection stays off; Curtain app windows remain covered.")
            }
            Button(primaryTitle) { advance() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!flow.canContinue)
                .accessibilityHint(flow.canContinue ? "" : continueHint)
        }
        .controlSize(.large)
    }

    /// Continue on the way through, Finish on the last step, Done for the permission-only reopen.
    private var primaryTitle: String {
        guard flow.isLast else { return String(localized: "Continue", comment: "Onboarding primary button") }
        return flow.permissionOnly
            ? String(localized: "Done", comment: "Onboarding primary button on the permission-only reopen")
            : String(localized: "Finish", comment: "Onboarding primary button on the last step")
    }

    private var continueHint: String {
        switch flow.step {
        case .welcome: String(localized: "Choose at least one", comment: "Accessibility hint on the disabled Continue button")
        case .permission: String(localized: "Allow Screen Recording first, or choose Skip for now", comment: "Accessibility hint on the disabled Continue button")
        case .hiddenSet: String(localized: "Choose who should be hidden first", comment: "Accessibility hint on the disabled Continue button")
        default: ""
        }
    }

    // MARK: Actions

    private func advance() {
        flow.advance()
        if flow.finished { finish() }
    }

    private func skipPermission() {
        flow.skipPermission()
        if flow.finished { finish() }
    }

    /// The monitor's state → the flow; a grant that arrives on the permission step advances (full flow only). Dev step runs
    /// show it as not granted so the buttons can be reviewed.
    private func permissionChanged(_ state: PermissionMonitor.State) {
        guard OnboardingWindow.devStep == nil else { return }
        flow.permissionGranted = state == .granted
        if flow.step == .permission, flow.permissionGranted, !flow.permissionOnly { advance() }
    }

    private func finish() {
        model.completeOnboarding(flow)
        if !flow.permissionOnly, OnboardingWindow.devStep == nil { music.enabled = flow.wantsMusic }
        if flow.registersLaunchAtLogin { OnboardingWindow.registerLaunchAtLogin(model: model) }
        OnboardingWindow.close()
        if model.loginProblem != nil {
            model.settingsTab = .general
            openSettings()
            NSApp.activate()
        }
    }
}

/// A large, clickable option: a checkbox (`multiple`) or a radio button, drawn as a card.
private struct ChoiceCard: View {
    let symbol: String
    let title: Text
    let detail: Text?
    let selected: Bool
    let multiple: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(.tint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    title.font(.headline)
                    if let detail { detail.font(.callout).foregroundStyle(.secondary) }
                }
                Spacer()
                Image(systemName: selected ? (multiple ? "checkmark.square.fill" : "checkmark.circle.fill") : (multiple ? "square" : "circle"))
                    .font(.title2)
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
