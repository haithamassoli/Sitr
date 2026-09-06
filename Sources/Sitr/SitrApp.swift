import AppKit
import QuartzCore
import SitrCore
import SwiftUI

@main
struct SitrApp: App {
    @State private var runtime: Runtime

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
        let runtime = Runtime(model: AppModel())
        _runtime = State(initialValue: runtime)
        Task { @MainActor in runtime.start() }  // first run-loop turn; capture and covers are up well inside a second (docs/m2/pipeline.md)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: runtime.model)
        } label: {
            MenuBarLabel(model: runtime.model)
        }
        Settings {
            SettingsView(model: runtime.model)
        }
    }
}

/// The running app: `AppModel` + `PermissionMonitor` + `DisplayManager` + one `Pipeline` per display + `Notifier`, connected
/// (M2-T12 glue, M2-T16 fail states). The selftests build one too, so the wiring exists exactly once.
@MainActor final class Runtime {
    let model: AppModel
    let permission = PermissionMonitor()
    let displayManager: DisplayManager
    let notifier = Notifier()
    private(set) var pipelines: [CGDirectDisplayID: Pipeline] = [:]
    /// Selftest hook: every processed frame of every display, on the main actor, with the commit time.
    var onCommit: ((CGDirectDisplayID, [CoverLayerSpec], Frame, Double) -> Void)?
    private var sawOK: Set<CGDirectDisplayID> = []
    private var healthTask: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        displayManager = DisplayManager(permission: permission)
        model.onPolicyChanged = { [weak self] policy in self?.pipelines.values.forEach { $0.update(policy) } }
        model.onRevealChanged = { [weak self] revealed in self?.displayManager.setRevealed(revealed) }
    }

    /// Brings capture, pipelines and health tracking up; follows display and permission changes from then on.
    func start() {
        displayManager.start()
        reconcile()
        observe()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.checkHealth()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Selftests: stops pipelines and capture, closes the panels.
    func stop() async {
        healthTask?.cancel()
        for p in pipelines.values { await p.stop() }
        pipelines = [:]
        displayManager.stop()
    }

    var appearance: CoverAppearance {
        CoverAppearance(style: model.preferences.coverStyle, strength: model.preferences.blurStrength, padding: model.preferences.bodyPadding)
    }

    /// One Pipeline per ManagedDisplay, following hot-plug.
    private func reconcile() {
        let current = displayManager.displays
        for id in pipelines.keys where !current.contains(where: { $0.id == id }) {
            let gone = pipelines.removeValue(forKey: id)
            sawOK.remove(id)
            Task { await gone?.stop() }
        }
        for d in current where pipelines[d.id] == nil {
            let p = Pipeline(displayID: d.id, frames: d.session.frames, panel: d.panel, renderer: d.renderer,
                             policy: model.policy, appearance: appearance)
            let id = d.id
            p.onCommit { [weak self] specs, frame, at in self?.frameCommitted(id, specs, frame, at) }
            pipelines[id] = p
            Task { await p.start() }
        }
    }

    /// Displays (hot-plug), permission, and appearance preferences. `onChange` fires before the value lands; act next turn.
    private func observe() {
        withObservationTracking {
            _ = displayManager.displays
            _ = permission.state
            _ = model.preferences.coverStyle
            _ = model.preferences.blurStrength
            _ = model.preferences.bodyPadding
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.reconcile()
                self.checkHealth()
                let a = self.appearance
                for p in self.pipelines.values { p.update(a) }
                self.observe()
            }
        }
    }

    /// M2-T16: no grant, or a capture session that stopped or errored → `.needsPermission` (Blur fails open, warning icon,
    /// one notification). Back to `.ok` on the first frame a pipeline commits once every session runs again. A session's
    /// initial `.stopped(nil)` before its first connect is not a failure; `stop()` after it ran is.
    func checkHealth() {
        var failed = permission.state != .granted
        for d in displayManager.displays {
            switch d.session.health {
            case .ok: sawOK.insert(d.id)
            case .stopped(let error): if error != nil || sawOK.contains(d.id) { failed = true }
            }
        }
        if failed { setHealth(.needsPermission) }
    }

    private func frameCommitted(_ id: CGDirectDisplayID, _ specs: [CoverLayerSpec], _ frame: Frame, _ at: Double) {
        sawOK.insert(id)
        if model.policy.health == .needsPermission, permission.state == .granted,
           displayManager.displays.allSatisfy({ $0.session.health.isOK }) {
            setHealth(.ok)
        }
        onCommit?(id, specs, frame, at)
    }

    private func setHealth(_ health: Health) {
        guard model.policy.health != health else { return }
        model.policy.health = health
        notifier.healthChanged(to: health)
    }
}
