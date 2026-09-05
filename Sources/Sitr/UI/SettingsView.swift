import SitrCore
import SwiftUI

/// Placeholder Settings window (M2-T14): General and About. M4-T02..T04 add the remaining tabs and contents.
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            Form {
                LaunchAtLoginToggle()
                Picker("Hide", selection: Binding(get: { model.policy.hiddenSet }, set: { model.setHiddenSet($0) })) {
                    Text("Women").tag(HiddenSet.women)
                    Text("Men").tag(HiddenSet.men)
                    Text("Everyone").tag(HiddenSet.everyone)
                }
                .accessibilityLabel("Hidden set")
                // PRD: Everyone forces Strict Mode on and disables the toggle.
                Toggle(
                    "Blur Unknown (Strict Mode)",
                    isOn: Binding(get: { model.policy.effectiveStrict }, set: { model.setStrict($0) })
                )
                .disabled(model.policy.hiddenSet == .everyone)
                .accessibilityLabel("Blur Unknown, Strict Mode")
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gear") }

            VStack(spacing: 12) {
                Text("Sitr \(AppModel.version)").font(.title2)
                Text("Hides people on screen, entirely on this Mac.").foregroundStyle(.secondary)
                Button("Check for Updates…") { AppModel.checkForUpdates() }
                    .accessibilityLabel("Check for Updates")
            }
            .padding()
            .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 440, height: 260)
    }
}
