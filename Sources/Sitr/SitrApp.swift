import SwiftUI

@main
struct SitrApp: App {
    @State private var model = AppModel()

    init() {
        if CommandLine.arguments.contains("--selftest") { Selftest.run() }
        // Shell-only dev checks (docs/m2/track-c.md): M2-T15 status/toggle, and a timed graceful quit for hotkey runs.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--launch-at-login") { LaunchAtLogin.selfcheck(args.dropFirst(i + 1).first) }
        if let i = args.firstIndex(of: "--quit-after"), let seconds = args.dropFirst(i + 1).first.flatMap(Double.init) {
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                NSApp.terminate(nil)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        Settings {
            SettingsView(model: model)
        }
    }
}
