import SwiftUI

/// Menu bar icon (FR7): template glyph, dimmed while paused or disabled, warning glyph when permission is missing or
/// detection is degraded.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        Image(nsImage: Self.icon(for: model.iconState))
            .accessibilityLabel("Sitr: \(model.statusText)")
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

/// FR7 menu, items in order. Strings are literals until the String Catalog lands (M4-T05).
struct MenuBarContent: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(model.statusText)
            .accessibilityLabel("Status: \(model.statusText)")
        Divider()
        if case .paused = model.status {
            Button("Resume Protection") { model.resume() }
                .accessibilityLabel("Resume Protection")
        } else {
            Menu("Pause Protection") {
                Button("15 minutes") { model.pause(minutes: 15) }
                    .accessibilityLabel("Pause Protection for 15 minutes")
                Button("1 hour") { model.pause(minutes: 60) }
                    .accessibilityLabel("Pause Protection for 1 hour")
            }
            .disabled(model.policy.protection == .disabled)
            .accessibilityLabel("Pause Protection")
        }
        if model.policy.protection == .disabled {
            Button("Enable Protection") { model.enable() }
                .accessibilityLabel("Enable Protection")
        } else {
            Button("Disable Protection") { model.disable() }
                .accessibilityLabel("Disable Protection")
        }
        Text(model.revealAvailable ? "Reveal: hold \(model.preferences.hotkey.displayString)" : "Reveal unavailable")
            .accessibilityLabel(
                model.revealAvailable
                    ? "Reveal available: hold \(model.preferences.hotkey.displayString)" : "Reveal unavailable")
        Divider()
        Button("Settings…") {
            openSettings()
            NSApp.activate()
        }
        .keyboardShortcut(",")
        .accessibilityLabel("Settings")
        Button("Check for Updates…") { AppModel.checkForUpdates() }
            .accessibilityLabel("Check for Updates")
        Divider()
        Button("Quit Sitr") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
            .accessibilityLabel("Quit Sitr")
    }
}
