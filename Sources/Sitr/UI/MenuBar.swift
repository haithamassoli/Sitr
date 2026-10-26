import AppKit
import SitrCore
import SwiftUI

/// Menu bar icon (FR7): template glyph, dimmed while paused or disabled, warning glyph when permission is missing or
/// detection is degraded.
struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(nsImage: Self.icon(for: model.iconState))
            .accessibilityLabel("Sitr: \(model.statusText)")
            .onAppear {
                // Dev smoke runs only (docs/m4/settings.md): SITR_OPEN_SETTINGS=<tab> opens Settings right after launch.
                guard SettingsView.requestedTab != nil else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    openSettings()
                    NSApp.activate()
                }
            }
    }

    /// The status item ignores SwiftUI `.opacity` on the label (checked by screenshot), so dimming is baked into a
    /// template image: the symbol drawn at 50 % alpha.
    static func icon(for state: AppModel.IconState) -> NSImage {
        let name = state == .warning ? "eye.trianglebadge.exclamationmark" : "eye.slash"
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)!
        guard state == .dimmed else { return symbol }
        let dimmed = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.5)
            return true
        }
        dimmed.isTemplate = true
        return dimmed
    }
}

/// The menu bar panel: one card per feature (hide people, remove music), each with its own switch, so a user who only
/// wants one of them never has to read about the other. Every literal is a String Catalog key (M4-T05).
struct MenuBarContent: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                Text("Sitr").font(.headline)
                Spacer()
                Button { open(.protection) } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(",")
                    .help(Text("Settings…"))
                    .accessibilityLabel("Settings")
            }
            HidePeopleCard(model: model, open: open)
            MusicCard(open: open)
            HStack {
                Button("Check for Updates…") { AppModel.checkForUpdates() }
                    .accessibilityHint("Opens the releases page on GitHub in your browser")
                Spacer()
                Button("Quit Sitr") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
        }
        .padding(14)
        .frame(width: 320)
    }

    private func open(_ tab: SettingsView.Tab) {
        model.settingsTab = tab
        NSApp.keyWindow?.close()  // the panel stays up behind Settings otherwise
        openSettings()
        NSApp.activate()
    }
}

/// Card chrome shared by both features: icon, title, status line, switch, then the card's own controls.
private struct FeatureCard<Content: View>: View {
    let symbol: String
    let title: Text
    let status: Text
    let tone: Color
    @Binding var isOn: Bool
    let toggleLabel: Text
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isOn ? Color.white : Color.secondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(isOn ? Color.accentColor : Color.secondary.opacity(0.15)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    title.font(.system(size: 13, weight: .semibold))
                    status.font(.callout).foregroundStyle(tone).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Toggle(isOn: $isOn) { toggleLabel }
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct HidePeopleCard: View {
    let model: AppModel
    let open: (SettingsView.Tab) -> Void

    private var policy: Policy { model.policy }
    /// On = protection not disabled and at least one app watched. Turning it on with no apps applies the recommended
    /// browsers and chats, so one click is enough for a user who skipped this in setup.
    private var isOn: Binding<Bool> {
        Binding(
            get: { policy.protection != .disabled && policy.rules.hasMonitoredApps },
            set: { on in
                guard on else { return model.disable() }
                if !policy.rules.hasMonitoredApps { model.updateRules { RecommendedPreset.apply(to: &$0) } }
                model.enable()
            })
    }

    var body: some View {
        let on = isOn.wrappedValue
        FeatureCard(
            symbol: "eye.slash", title: Text("Hide people"),
            status: on ? Text(model.statusText) : Text("Off"), tone: on ? model.status.tone : .secondary,
            isOn: isOn, toggleLabel: Text("Hide people")
        ) {
            if on {
                Picker("Hide", selection: Binding(get: { policy.hiddenSet }, set: { model.setHiddenSet($0) })) {
                    Text("Women").tag(HiddenSet.women)
                    Text("Men").tag(HiddenSet.men)
                    Text("Everyone").tag(HiddenSet.everyone)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Hidden set")
                HStack(spacing: 6) {
                    ProtectionRecovery(model: model, open: open)
                    if case .paused = model.status {
                        Button("Resume Protection") { model.resume() }
                            .buttonStyle(.borderedProminent)
                    } else if model.status == .protected || model.status == .waitingForApps {
                        Text("Pause").foregroundStyle(.secondary)
                        Button("15 minutes") { model.pause(minutes: 15) }
                            .accessibilityLabel("Pause Protection for 15 minutes")
                        Button("1 hour") { model.pause(minutes: 60) }
                            .accessibilityLabel("Pause Protection for 1 hour")
                    }
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
                .font(.callout)
                if model.revealAvailable {
                    let hotkey = model.preferences.hotkey.displayString
                    Text("Reveal: hold \(hotkey)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct MusicCard: View {
    let open: (SettingsView.Tab) -> Void
    private let music = MusicService.shared

    var body: some View {
        FeatureCard(
            symbol: "music.note", title: Text("Remove music"),
            status: music.enabled ? music.statusText : Text("Off"), tone: music.enabled ? music.tone : .secondary,
            isOn: Binding(get: { music.enabled }, set: { music.enabled = $0 }), toggleLabel: Text("Remove music")
        ) {
            if music.enabled {
                if music.extensionConnected {
                    Text("On any video, press Remove music. Press it again to hear the original audio.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Button("Install the browser extension…") { open(.music) }
                        .controlSize(.small)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                music.refreshHelperStatus()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

extension AppModel.Status {
    /// Status line color: green when covering, orange when the user has something to fix, grey otherwise.
    var tone: Color {
        switch iconState {
        case .normal: .green
        case .warning: .orange
        case .dimmed: .secondary
        }
    }
}

/// Shared actions keep the menu and Settings aligned with the actual failure.
struct ProtectionRecovery: View {
    let model: AppModel
    var open: ((SettingsView.Tab) -> Void)?

    var body: some View {
        switch model.status {
        case .needsPermission:
            Button("Allow Screen Recording") { model.openPermissionSettings() }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Opens Privacy & Security, Screen & System Audio Recording")
        case .recovering, .modelUnavailable, .detectionFailed:
            Button("Retry Protection") { model.retryProtection() }
        case .noApps:
            if let open { Button("Configure Protected Apps") { open(.protection) } }
        default:
            EmptyView()
        }
    }
}
