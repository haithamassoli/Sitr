import SwiftUI

/// Settings window (PRD FR9): one tab per thing a user comes here to do — who and where to hide, music, the rest, about.
/// Tab titles are String Catalog keys (M4-T05). `SITR_OPEN_SETTINGS=<tab>` (dev smoke runs, docs/m4/settings.md) selects
/// the initial tab; `MenuBarLabel` opens the window.
struct SettingsView: View {
    nonisolated enum Tab: String, CaseIterable {
        case protection, music, general, about
    }

    let model: AppModel

    init(model: AppModel) {
        self.model = model
        if let initial = Self.initialTab { model.settingsTab = initial }
    }

    /// Value of `SITR_OPEN_SETTINGS`, when set ("1" opens the last tab used, Hide People at launch).
    static var requestedTab: String? { ProcessInfo.processInfo.environment["SITR_OPEN_SETTINGS"] }
    /// Initial dev tab, consumed on appearance. Later navigation uses AppModel.settingsTab,
    /// which also works when the settings window is already visible.
    static var initialTab: Tab? = Tab(rawValue: requestedTab ?? "")

    var body: some View {
        TabView(selection: Binding(get: { model.settingsTab }, set: { model.settingsTab = $0 })) {
            ProtectionTab(model: model)
                .tabItem { Label("Hide People", systemImage: "eye.slash") }
                .tag(Tab.protection)
            MusicTab()
                .tabItem { Label("Remove Music", systemImage: "music.note") }
                .tag(Tab.music)
            GeneralTab(model: model)
                .tabItem { Label("General", systemImage: "gear") }
                .tag(Tab.general)
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(Tab.about)
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 600, idealHeight: 680)
        .onAppear {
            // Apply the dev-requested tab once; later navigation is shared through the model.
            if let requested = Self.initialTab {
                model.settingsTab = requested
                Self.initialTab = nil
            }
        }
    }
}
