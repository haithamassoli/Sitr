import AppKit
import Observation
import SwiftUI
import os

@_silgen_name("notify_register_check") private func musicNotifyRegister(_ name: UnsafePointer<CChar>, _ token: UnsafeMutablePointer<Int32>) -> UInt32
@_silgen_name("notify_set_state") private func musicNotifySetState(_ token: Int32, _ state: UInt64) -> UInt32
@_silgen_name("notify_post") private func musicNotifyPost(_ name: UnsafePointer<CChar>) -> UInt32
@_silgen_name("notify_get_state") private func musicNotifyGetState(_ token: Int32, _ state: UnsafeMutablePointer<UInt64>) -> UInt32

/// The music helper is a separate app so Sitr's screen-protection process keeps its no-network sandbox.
@Observable @MainActor final class MusicService {
    static let shared = MusicService()
    static let storeURL: URL? = nil // Set to the published Chrome Web Store listing after review.
    private static let notificationName = "com.goldentik.Sitr.Music.enabled"

    enum State { case off, missing, starting, running, stopped, failed, stopFailed }
    /// Published by the helper (MusicBackend/server.py): it downloads the voice model on first use.
    enum ModelState: UInt64 { case unknown = 0, preparing = 1, ready = 2, failed = 3 }

    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: "browserMusicEnabled")
            enabled ? start() : stop()
        }
    }
    private(set) var state: State = .off
    private(set) var lastError: String?
    private(set) var modelState: ModelState = .unknown
    /// Sticky: once the helper has seen a request from the extension, the install guide collapses.
    private(set) var extensionConnected = UserDefaults.standard.bool(forKey: "musicExtensionConnected")

    private let helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/SitrMusicHelper.app")
    private var runningApp: NSRunningApplication?
    @ObservationIgnored private var wantsRunning = false
    @ObservationIgnored private var launchTask: Task<Void, Never>?
    @ObservationIgnored private var terminatedObserver: NSObjectProtocol?
    @ObservationIgnored private var notifyToken: Int32 = 0
    @ObservationIgnored private var notifyReady = false
    @ObservationIgnored private var modelToken: Int32 = 0
    @ObservationIgnored private var extensionToken: Int32 = 0

    private init() {
        enabled = UserDefaults.standard.bool(forKey: "browserMusicEnabled")
        notifyReady = Self.notificationName.withCString { musicNotifyRegister($0, &notifyToken) == 0 }
        _ = "com.goldentik.Sitr.Music.model".withCString { musicNotifyRegister($0, &modelToken) }
        _ = "com.goldentik.Sitr.Music.extension".withCString { musicNotifyRegister($0, &extensionToken) }
        terminatedObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, let pid, self.runningApp?.processIdentifier == pid else { return }
                self.runningApp = nil
                if self.enabled { self.state = .stopped }
            }
        }
    }

    /// At launch: start the helper when enabled; otherwise stop one a crashed Sitr left running (the notify state stays 1).
    func startIfEnabled() {
        if enabled { start() } else if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL == helperURL }) { stop() }
    }

    /// Polled by the Music tab while it is visible; notify state reads are cheap.
    func refreshHelperStatus() {
        var value: UInt64 = 0
        if musicNotifyGetState(modelToken, &value) == 0 { modelState = ModelState(rawValue: value) ?? .unknown }
        if !extensionConnected, musicNotifyGetState(extensionToken, &value) == 0, value == 1 {
            extensionConnected = true
            UserDefaults.standard.set(true, forKey: "musicExtensionConnected")
        }
    }

    func start() {
        guard enabled, state != .starting else { return }
        wantsRunning = true
        guard signalHelper(enabled: true) else { state = .failed; return }
        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            state = .missing
            return
        }
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL == helperURL }) {
            runningApp = app
            state = .running
            return
        }
        state = .starting
        lastError = nil
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: helperURL, configuration: configuration) { [weak self] app, error in
            Task { @MainActor in
                guard let self else { return }
                guard self.wantsRunning else { return }
                if let app {
                    self.runningApp = app
                    self.state = .running
                } else if self.state != .running {
                    self.lastError = error.map { String(describing: $0) }
                    self.state = .failed
                }
            }
        }
        // A command-line helper need not finish LaunchServices' AppKit handshake.
        launchTask?.cancel()
        launchTask = Task { [weak self] in
            for _ in 0..<40 {
                guard let self, self.wantsRunning, !Task.isCancelled else { return }
                if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL == self.helperURL }) {
                    self.runningApp = app
                    self.state = .running
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            if let self, self.state == .starting {
                self.lastError = "Timed out waiting for music helper"
                self.state = .failed
            }
        }
    }

    func stop() {
        wantsRunning = false
        launchTask?.cancel()
        launchTask = nil
        let signaled = signalHelper(enabled: false)
        runningApp = nil
        state = signaled ? .off : .stopFailed
    }

    @discardableResult private func signalHelper(enabled: Bool) -> Bool {
        // ponytail: a hard Sitr crash leaves the helper alive; add a short lease heartbeat if crash cleanup becomes necessary.
        let set = notifyReady ? musicNotifySetState(notifyToken, enabled ? 1 : 0) : UInt32.max
        let post = Self.notificationName.withCString { musicNotifyPost($0) }
        guard set == 0 && post == 0 else {
            lastError = "Music helper signal failed (set=\(set), post=\(post))"
            Logger(subsystem: "com.goldentik.Sitr", category: "music").error("\(self.lastError ?? "Music helper signal failed", privacy: .public)")
            return false
        }
        return true
    }
}

struct MusicTab: View {
    private let music = MusicService.shared

    var body: some View {
        Form {
            Section {
                Toggle("Enable music removal", isOn: Binding(get: { music.enabled }, set: { music.enabled = $0 }))
                LabeledContent("Status") { status }
                if music.enabled && (music.state == .stopped || music.state == .failed) {
                    Button("Try again") { music.start() }
                }
                if music.state == .stopFailed { Button("Try stopping again") { music.stop() } }
                if let error = music.lastError {
                    Text("Restart Sitr. If the helper still cannot start, reinstall Sitr.")
                    DisclosureGroup("Technical details") { Text(error) }
                }
            } header: {
                Text("Music removal in browser")
            } footer: {
                Text("Audio is processed on this Mac. The first time, Sitr downloads a voice model (about 80 MB); after that the helper only downloads the audio of videos you choose.")
            }

            Section {
                if music.extensionConnected {
                    Label("Extension connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("On any video, press Remove music. Press it again to hear the original audio.")
                    DisclosureGroup("Installation steps") { ExtensionInstallSteps() }
                } else {
                    ExtensionInstallSteps()
                }
            } header: {
                Text("Browser extension")
            } footer: {
                Text("Works in Google Chrome, Microsoft Edge, Brave and Arc. Keep Sitr in the Applications folder; the browser loads the extension from there.")
            }

            Section {
                Text("Speech may sound different. Singing can remain because the model keeps the human voice. Some sites or protected videos may not work.")
            } header: {
                Text("What to expect")
            }
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                music.refreshHelperStatus()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch music.state {
        case .off: Text("Off")
        case .missing: Text("Helper missing from this build")
        case .starting: Text("Starting…")
        case .running:
            switch music.modelState {
            case .preparing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Downloading the voice model…")
                }
            case .failed: Text("Could not download the voice model. Check your internet connection; Sitr keeps trying.")
            case .ready, .unknown: Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case .stopped: Text("Stopped unexpectedly")
        case .failed: Text("Could not start")
        case .stopFailed: Text("Could not stop helper")
        }
    }
}

/// Until the Chrome Web Store listing is live, installation is a guided "Load unpacked": the browser refuses
/// chrome:// URLs opened from outside, so Sitr copies the address and the user pastes it.
struct ExtensionInstallSteps: View {
    private static let browsers: [(id: String, name: String)] = [
        ("com.google.Chrome", "Google Chrome"), ("com.microsoft.edgemac", "Microsoft Edge"),
        ("com.brave.Browser", "Brave"), ("company.thebrowser.Browser", "Arc"),
    ]
    private let browser: (url: URL, name: String)? = Self.browsers.lazy.compactMap { entry in
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.id).map { ($0, entry.name) }
    }.first
    @State private var copied = false

    var body: some View {
        if let storeURL = MusicService.storeURL {
            Link("Add to Chrome", destination: storeURL)
                .buttonStyle(.borderedProminent)
        } else if let browser {
            step(1, "Open the extensions page",
                 copied ? "Copied. In the browser, press ⌘L, then ⌘V, then Return." : "Sitr opens your browser and copies the extensions page address for you.") {
                Button(String(localized: "Open \(browser.name)")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("chrome://extensions", forType: .string)
                    NSWorkspace.shared.openApplication(at: browser.url, configuration: NSWorkspace.OpenConfiguration())
                    copied = true
                }
            }
            step(2, "Turn on Developer mode", "The switch is in the top-right corner of the extensions page.") { EmptyView() }
            step(3, "Drag the extension onto the page", "Sitr shows the BrowserExtension folder in Finder. Drag it onto the extensions page.") {
                Button("Show extension folder") {
                    let folder = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/BrowserExtension")
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
            }
            step(4, "Try it", "Open a video and press Remove music on it. A checkmark appears here once the extension connects.") { EmptyView() }
        } else {
            Text("Music removal needs Google Chrome or another Chromium browser.")
            Link("Download Google Chrome", destination: URL(string: "https://www.google.com/chrome/")!)
        }
    }

    private func step<Action: View>(_ number: Int, _ title: LocalizedStringKey, _ detail: LocalizedStringKey,
                                    @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number, format: .number)
                .font(.callout.bold())
                .frame(width: 22, height: 22)
                .background(Circle().fill(.tint.opacity(0.18)))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).bold()
                Text(detail).font(.callout).foregroundStyle(.secondary)
                action()
            }
        }
        .padding(.vertical, 2)
    }
}
