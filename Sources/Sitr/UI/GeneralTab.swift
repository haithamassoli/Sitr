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
                LabeledContent("Protection scope") { Text(model.scopeText) }
                ProtectionRecovery(model: model)
            } footer: {
                if let text = model.recoveryText { Text(text) }
            }
            Section {
                LaunchAtLoginToggle(model: model)
            }
            Section {
                Picker("Language", selection: Binding(get: { model.preferences.language }, set: { model.preferences.language = $0 })) {
                    ForEach(AppLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityLabel("Language")
                if model.preferences.language != Self.launchLanguage {
                    LabeledContent("The new language applies after a relaunch.") {
                        Button("Relaunch now") { Self.relaunch(model: model) }
                            .accessibilityLabel("Relaunch Sitr now")
                            .accessibilityHint("Quits and reopens Sitr in the new language")
                    }
                    .font(.callout)
                }
                if let problem = model.relaunchProblem { Text(problem).foregroundStyle(.red) }
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
    static func relaunch(model: AppModel) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { app, error in
            Task { @MainActor in
                model.finishRelaunch(error: error ?? (app == nil ? CocoaError(.executableNotLoadable) : nil)) { NSApp.terminate(nil) }
            }
        }
    }
}
