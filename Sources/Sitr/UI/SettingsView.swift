import SwiftUI

/// Settings window (PRD FR9), one file per tab. Strings are literals until the String Catalog lands (M4-T05).
/// `SITR_OPEN_SETTINGS=<tab>` (dev smoke runs, docs/m4/settings.md) selects the initial tab; `MenuBarLabel` opens the window.
struct SettingsView: View {
    nonisolated enum Tab: String, CaseIterable {
        case general, protection, appearance, shortcuts, about
    }

    let model: AppModel
    @State private var tab: Tab

    init(model: AppModel) {
        self.model = model
        _tab = State(initialValue: Tab(rawValue: Self.requestedTab ?? "") ?? .general)
    }

    /// Value of `SITR_OPEN_SETTINGS`, when set ("1" opens General).
    static var requestedTab: String? { ProcessInfo.processInfo.environment["SITR_OPEN_SETTINGS"] }

    var body: some View {
        TabView(selection: $tab) {
            GeneralTab(model: model)
                .tabItem { Label("General", systemImage: "gear") }
                .tag(Tab.general)
            ProtectionTab(model: model)
                .tabItem { Label("Protection", systemImage: "eye.slash") }
                .tag(Tab.protection)
            AppearanceTab(model: model)
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
                .tag(Tab.appearance)
            ShortcutsTab(model: model)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                .tag(Tab.shortcuts)
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(Tab.about)
        }
        .frame(width: 560, height: 600)
    }
}
