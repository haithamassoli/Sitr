// M4-T01 onboarding (PRD FR8, five steps) and its M4-T11 accessibility. `OnboardingFlow` is the pure state (unit-tested),
// `OnboardingWindow` the one NSWindow + NSHostingView, `OnboardingView` the SwiftUI pages. Every literal is a String Catalog
// key (M4-T05); computed texts go through `String(localized:)`.
import AppKit
import ServiceManagement
import SitrCore
import SwiftUI
import os

/// Which step, what the user chose, and what finishing applies. The view binds to it; tests drive it without a window.
nonisolated struct OnboardingFlow: Equatable, Sendable {
    nonisolated enum Step: Int, CaseIterable, Sendable {
        case welcome = 1, permission, hiddenSet, recommended, done

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
    /// FR8 step 3: required, no preselection.
    var hiddenSet: HiddenSet?
    var strict = true
    /// Step 4: true = "Use recommended settings", false = "Configure myself", nil = not chosen yet.
    var usePreset: Bool?
    var launchAtLogin = true
    private(set) var finished = false

    init(permissionOnly: Bool = false, permissionGranted: Bool = false, step: Step? = nil) {
        self.permissionOnly = permissionOnly
        self.permissionGranted = permissionGranted
        self.step = step ?? (permissionOnly ? .permission : .welcome)
    }

    var stepCount: Int { permissionOnly ? 1 : Step.allCases.count }
    var isLast: Bool { permissionOnly || step == .done }
    /// Strict Mode as applied: Everyone forces it on (PRD Definitions); the toggle then shows on and disabled.
    var effectiveStrict: Bool { hiddenSet == .everyone || strict }
    var strictLocked: Bool { hiddenSet == .everyone }

    /// Continue / Finish enabled: permission needs the grant, the hidden set a choice, step 4 one of its two buttons.
    var canContinue: Bool {
        switch step {
        case .welcome, .done: true
        case .permission: permissionGranted
        case .hiddenSet: hiddenSet != nil
        case .recommended: usePreset != nil
        }
    }

    mutating func back() {
        guard !permissionOnly, let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    /// Return / Continue. Does nothing while `canContinue` is false (Return cannot skip the permission); finishes on the last step.
    mutating func advance() {
        guard canContinue else { return }
        if isLast {
            finished = true
        } else if let next = Step(rawValue: step.rawValue + 1) {
            step = next
        }
    }

    /// "Skip for now": on without the grant (Needs permission, warning icon, nothing covered); in a reopen it just closes.
    mutating func skipPermission() {
        guard step == .permission else { return }
        if permissionOnly { finished = true } else { step = .hiddenSet }
    }

    mutating func choosePreset(_ use: Bool) {
        guard step == .recommended else { return }
        usePreset = use
        advance()
    }

    // MARK: Finish outcome

    /// Rules after finishing: the Default Rule becomes Off (the preset keeps it there), preset overrides when chosen. Nil for
    /// a permission-only reopen.
    func rulesOnFinish(_ current: Rules) -> Rules? {
        guard !permissionOnly else { return nil }
        var rules = current
        rules.defaultMode = .off
        if usePreset == true { RecommendedPreset.apply(to: &rules) }
        return rules
    }

    /// "Configure myself" opens Settings › Protection once the window is gone.
    var opensSettingsOnFinish: Bool { !permissionOnly && usePreset == false }
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
            contentRect: NSRect(origin: .zero, size: OnboardingView.size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
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
    static func registerLaunchAtLogin() {
        guard devStep == nil else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            log.error("launch at login: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// The five pages, one bottom bar. Return = the default button; Esc is not bound (nothing skips the permission by accident).
/// No animations (M4-T11).
struct OnboardingView: View {
    static let size = CGSize(width: 560, height: 400)

    let model: AppModel
    let permission: PermissionMonitor
    @State var flow: OnboardingFlow
    @FocusState private var focus: Focus?
    @Environment(\.openSettings) private var openSettings

    private enum Focus: Hashable { case hiddenSet, primary }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if flow.permissionOnly {
                    Text("Sitr needs your attention")
                } else {
                    let step = flow.step.rawValue, count = flow.stepCount
                    Text("Step \(step) of \(count)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 12)
            content
            Spacer(minLength: 12)
            buttons
        }
        .padding(.horizontal, 32)
        .padding(.top, 6)
        .padding(.bottom, 22)
        .frame(width: Self.size.width, height: Self.size.height)
        .transaction { $0.animation = nil }
        .defaultFocus($focus, .primary)
        .onChange(of: flow.step) { _, step in focus = step == .hiddenSet ? .hiddenSet : .primary }
        .onChange(of: permission.state, initial: true) { _, state in permissionChanged(state) }
    }

    // MARK: Pages

    @ViewBuilder private var content: some View {
        switch flow.step {
        case .welcome:
            page("eye.slash", Text("Welcome to Sitr")) {
                Text("Sitr hides people on your screen as they appear — women, men, or everyone — in every app: browsers, chats, photos, video, calls.")
                Text("Everything happens on this Mac. Sitr has no network access, so nothing leaves your Mac: no pixels, no logs, no telemetry. Verify it any time:")
                Text(AboutTab.verifyCommand)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    .environment(\.layoutDirection, .leftToRight)  // a shell command stays LTR and left-aligned inside the RTL layout
                    .accessibilityLabel("Verification command: \(AboutTab.verifyCommand)")
            }
        case .permission:
            page("rectangle.dashed.badge.record", Text("Allow Screen Recording")) {
                Text("Sitr can only cover what it can see, and macOS requires Screen Recording permission for that. The screen is analyzed on this Mac and never stored.")
                if flow.permissionGranted {
                    Label("Screen Recording is allowed.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Not allowed yet. Until it is, Sitr covers nothing and shows a warning icon in the menu bar.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    HStack {
                        Button("Allow Screen Recording") { permission.request() }
                            .accessibilityHint("Shows the macOS permission dialog")
                        Button("Open System Settings") { permission.openSystemSettings() }
                            .accessibilityHint("Opens Privacy & Security, Screen & System Audio Recording")
                    }
                }
                Text("macOS 15.1 and later asks you to re-approve this permission about once a month. When the grant lapses, Sitr shows the warning icon and brings this step back.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .hiddenSet:
            page("person.2", Text("Who should be hidden?")) {
                Picker("Hide", selection: $flow.hiddenSet) {
                    Text("Women").tag(HiddenSet?.some(.women))
                    Text("Men").tag(HiddenSet?.some(.men))
                    Text("Everyone").tag(HiddenSet?.some(.everyone))
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .focused($focus, equals: .hiddenSet)
                .accessibilityLabel("Hidden set")
                .accessibilityHint("Required. Everyone includes people Sitr cannot classify.")
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Blur Unknown (Strict Mode)")
                        Text("Also hides people whose category is unknown: facing away, face hidden or too small, or the classifier unsure. Everyone always includes them.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Blur Unknown (Strict Mode)", isOn: Binding(get: { flow.effectiveStrict }, set: { flow.strict = $0 }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(flow.strictLocked)
                        .accessibilityLabel("Blur Unknown, Strict Mode")
                        .accessibilityHint(
                            flow.strictLocked
                                ? String(localized: "Always on while Everyone is selected", comment: "Accessibility hint for the Strict Mode toggle")
                                : String(localized: "Recommended on", comment: "Accessibility hint for the Strict Mode toggle in onboarding"))
                }
                .padding(.top, 6)
            }
        case .recommended:
            page("checkmark.shield", Text("Recommended Protection")) {
                Text("Curtain covers changed regions the moment they appear and uncovers what is verified safe: the mode for apps where people show up without warning. Every other app stays Off (the Default Rule) until you change it in Settings › Protection.")
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                    GridRow {
                        Text("Browsers").bold()
                        Text("Safari, Chrome, Arc")
                        Text("Curtain").foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    GridRow {
                        Text("Communication").bold()
                        Text("Telegram, WhatsApp, Discord")
                        Text("Curtain").foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Recommended rules")
            }
        case .done:
            let hotkey = model.preferences.hotkey.displayString
            page("keyboard", Text("You're all set")) {
                Text("Hold \(hotkey) to reveal what is under the covers; release to cover again. As a safety, covers come back after 30 seconds of holding.")
                Text("Change the shortcut in Settings › Shortcuts. Sitr lives in the menu bar: pause, disable, or open Settings from there.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at login")
                        Text("Sitr starts protecting as soon as you log in.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Launch at login", isOn: $flow.launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Launch at login")
                }
                .padding(.top, 6)
            }
        }
    }

    /// `title` is a `Text` so the call sites carry the literal (the String Catalog gate reads `Text("…")`).
    private func page(_ symbol: String, _ title: Text, @ViewBuilder body: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                title
                    .font(.title.bold())
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(.bottom, 4)
            body()
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    .accessibilityHint("Continues without Screen Recording. Sitr covers nothing until it is allowed.")
            }
            if flow.step == .recommended {
                Button("Configure myself") { flow.choosePreset(false) }
                    .accessibilityHint("Leaves every app Off and opens Settings, Protection, when setup finishes")
                Button("Use recommended settings") { flow.choosePreset(true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .focused($focus, equals: .primary)
                    .accessibilityHint("Sets Safari, Chrome, Arc, Telegram, WhatsApp and Discord to Curtain; the Default Rule stays Off")
            } else {
                Button(primaryTitle) { advance() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!flow.canContinue)
                    .focused($focus, equals: .primary)
                    .accessibilityHint(flow.canContinue ? "" : continueHint)
            }
        }
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

    /// The monitor's state → the flow; a grant that arrives on step 2 advances (full flow only). Dev step runs show step 2
    /// as not granted so the buttons can be reviewed.
    private func permissionChanged(_ state: PermissionMonitor.State) {
        guard OnboardingWindow.devStep == nil else { return }
        flow.permissionGranted = state == .granted
        if flow.step == .permission, flow.permissionGranted, !flow.permissionOnly { advance() }
    }

    private func finish() {
        model.completeOnboarding(flow)
        if flow.registersLaunchAtLogin { OnboardingWindow.registerLaunchAtLogin() }
        OnboardingWindow.close()
        if flow.opensSettingsOnFinish {
            SettingsView.initialTab = .protection
            openSettings()
            NSApp.activate()
        }
    }
}
