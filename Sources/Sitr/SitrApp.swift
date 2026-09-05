import SwiftUI

@main
struct SitrApp: App {
    init() {
        if CommandLine.arguments.contains("--selftest") { Selftest.run() }
    }

    var body: some Scene {
        MenuBarExtra("Sitr", systemImage: "eye.slash") {
            Text("Sitr \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") — scaffold")
            Divider()
            Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
    }
}
