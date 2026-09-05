import ServiceManagement
import SwiftUI

/// Launch at login via `SMAppService.mainApp` (M2-T15). The toggle re-reads the real status on appear and whenever the
/// app becomes active, so a change made in System Settings › Login Items shows up too.
struct LaunchAtLoginToggle: View {
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Launch at login", isOn: Binding(get: { status == .enabled }, set: { set($0) }))
                .accessibilityLabel("Launch at login")
            if status == .requiresApproval {
                HStack {
                    Text("Approve Sitr in System Settings › Login Items.")
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                        .accessibilityLabel("Open Login Items in System Settings")
                }
                .font(.callout)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    private func refresh() { status = SMAppService.mainApp.status }
}

enum LaunchAtLogin {
    /// `Sitr --launch-at-login [on|off|status]`: applies the change, prints `launch_at_login=<status>`, exits.
    /// Shell-only check for M2-T15; the app has no bundle-external way to read `SMAppService` otherwise.
    static func selfcheck(_ command: String?) {
        let service = SMAppService.mainApp
        do {
            switch command {
            case "on": try service.register()
            case "off": try service.unregister()
            default: break
            }
        } catch {
            print("launch_at_login_error=\(error)")
        }
        print("launch_at_login=\(name(service.status))")
        exit(0)
    }

    static func name(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "notRegistered"
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown(\(status.rawValue))"
        }
    }
}
