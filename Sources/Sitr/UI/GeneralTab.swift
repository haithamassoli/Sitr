import AppKit
import SwiftUI

/// Settings › General (M2-T15, M4-T04): how covers look, the reveal shortcut, launch at login, language, Low Power.
struct GeneralTab: View {
    let model: AppModel

    // ponytail: the language the process started with, read once from the standard domain (the app's `Preferences` use it);
    // "Relaunch now" shows while the choice differs from it. Upgrade = keep it on AppModel if more views need it.
    private static let launchLanguage = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .system

    var body: some View {
        Form {
            Section {
                LaunchAtLoginToggle(model: model)
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
                Toggle(isOn: Binding(get: { model.preferences.lowPowerReducesFrameRate }, set: { model.preferences.lowPowerReducesFrameRate = $0 })) {
                    Text("Reduce frame rate in Low Power Mode")
                    Text("Captures at 8 frames per second instead of 15 while the Mac is in Low Power Mode.")
                }
                .accessibilityLabel("Reduce frame rate in Low Power Mode")
            }
            AppearanceSection(model: model)
            ShortcutSection(model: model)
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
