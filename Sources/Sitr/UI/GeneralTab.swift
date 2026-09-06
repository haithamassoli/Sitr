import AppKit
import SwiftUI

/// Settings › General (M2-T15, M4-T04): launch at login, language, Low Power behaviour.
struct GeneralTab: View {
    let model: AppModel

    // ponytail: the language the process started with, read once from the standard domain (the app's `Preferences` use it);
    // "Relaunch now" shows while the choice differs from it. Upgrade = keep it on AppModel if more views need it.
    private static let launchLanguage = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .system

    var body: some View {
        Form {
            // FR7's status line, where a user who opened Settings after seeing the warning icon looks for it. The
            // degraded footer is the only state that needs explaining (M4-T07); the others are self-describing.
            Section {
                LabeledContent("Protection status") { Text(model.statusText) }
            } footer: {
                if model.status == .degraded {
                    Text("Detection is slower than 250 ms per frame, so covers can lag until it speeds up again.")
                }
            }
            Section {
                LaunchAtLoginToggle()
            }
            Section {
                Picker("Language", selection: Binding(get: { model.preferences.language }, set: { model.preferences.language = $0 })) {
                    ForEach(AppLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityLabel("Language")
                if model.preferences.language != Self.launchLanguage {
                    LabeledContent("The new language applies after a relaunch.") {
                        Button("Relaunch now") { Self.relaunch() }
                            .accessibilityLabel("Relaunch Sitr now")
                            .accessibilityHint("Quits and reopens Sitr in the new language")
                    }
                    .font(.callout)
                }
            } footer: {
                Text("System follows the language order in System Settings › General › Language & Region.")
            }
            Section {
                Toggle(
                    "Reduce frame rate in Low Power Mode",
                    isOn: Binding(get: { model.preferences.lowPowerReducesFrameRate }, set: { model.preferences.lowPowerReducesFrameRate = $0 })
                )
                .accessibilityLabel("Reduce frame rate in Low Power Mode")
                .accessibilityHint("8 frames per second instead of 15 while the Mac is in Low Power Mode")
            } footer: {
                Text("Captures at 8 frames per second instead of 15 while the Mac is in Low Power Mode.")
            }
        }
        .formStyle(.grouped)
    }

    /// Starts a second instance from the same bundle, then quits this one; the new process reads `AppleLanguages` at launch.
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
