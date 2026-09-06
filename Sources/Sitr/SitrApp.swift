import AppKit
import QuartzCore
import SitrCore
import SitrDetect
import SwiftUI
import os

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

/// The running app: `AppModel` + `PermissionMonitor` + `DisplayManager` + `WindowTracker` + `FilterBuilder` + one `Pipeline` per
/// display + `Notifier`, connected (M2-T12 glue, M2-T16 fail states, M3-T03 filters, M3-T05 Curtain, M3-T06 fail-closed,
/// M4-T10 suspend/resume). The selftests build one too, so the wiring exists exactly once.
@MainActor final class Runtime {
    /// Capture rate for displays showing a Curtain window (docs/spike/latency.md: 15 fps alone is 72 ms p95). `SITR_CURTAIN_FPS`
    /// overrides it for the 30-vs-60 measurement.
    nonisolated static let curtainFPS = Int(ProcessInfo.processInfo.environment["SITR_CURTAIN_FPS"] ?? "") ?? 30
    /// No complete frame for this long after a Curtain window changed = the stream stalled (PRD FR10).
    nonisolated static let stallAfter = 1.0

    let model: AppModel
    let permission = PermissionMonitor()
    let displayManager: DisplayManager
    let windowTracker = WindowTracker()
    let filters: FilterBuilder
    let notifier = Notifier()
    /// M4-T06: Low Power Mode → 8 fps on every session.
    let lowPower: LowPowerMonitor
    /// M4-T10: sleep/wake, lock/unlock, fast user switching, displays off/on.
    let systemEvents = SystemEventMonitor()
    private(set) var pipelines: [CGDirectDisplayID: Pipeline] = [:]
    /// Selftest hooks: every processed frame of every display, on the main actor, with the commit time; every frame arrival with
    /// its pre-covers.
    var onCommit: ((CGDirectDisplayID, [CoverLayerSpec], Frame, Double) -> Void)?
    var onPreCover: ((CGDirectDisplayID, [CoverLayerSpec], Frame, Double) -> Void)?
    /// Displays whose stream is stalled (M3-T06): fail-closed covers are up on them.
    private(set) var stalled: Set<CGDirectDisplayID> = []
    /// Stall checks waiting to fire, at most one per display (M4-T10: a burst of window changes — Stage Manager shuffling
    /// a Space, a Curtain window resizing — must not leave one task per change behind).
    var pendingStallChecks: Int { stallChecks.count }
    /// Detection plug-ins shared by every display's pipeline: the CoreML models once `loadModels()` has them, else these fallbacks.
    private var detector: any PersonDetecting = VisionPersonDetector()
    private var classifier: any GenderClassifying = NoClassifier()
    private var sawOK: Set<CGDirectDisplayID> = []
    /// Per display: whether the session was `.ok` at the last look (a false → true edge re-installs the filter).
    private var sessionOK: [CGDirectDisplayID: Bool] = [:]
    private var healthTask: Task<Void, Never>?
    private var lastFrameAt: [CGDirectDisplayID: Double] = [:]
    private var curtainRects: [CGDirectDisplayID: [CGRect]] = [:]
    private var curtainChangedAt: [CGDirectDisplayID: Double] = [:]
    private var stallChecks: [CGDirectDisplayID: Task<Void, Never>] = [:]
    private var stallDegraded = false
    private var windowPIDs: Set<pid_t> = []
    private let log = Logger(subsystem: "com.goldentik.Sitr", category: "runtime")

    init(model: AppModel) {
        self.model = model
        let displays = DisplayManager(permission: permission)
        displayManager = displays
        lowPower = LowPowerMonitor(reducesFrameRate: { model.preferences.lowPowerReducesFrameRate })
        filters = FilterBuilder(rules: model.policy.rules) { displays.displays }
        model.onPolicyChanged = { [weak self] policy in
            guard let self else { return }
            self.pipelines.values.forEach { $0.update(policy) }
            self.filters.rules = policy.rules
            self.windowsChanged()
        }
        model.onRevealChanged = { [weak self] revealed in self?.displayManager.setRevealed(revealed) }
        // Wired in `init`, observed in `start()`: the unit tests drive `systemEvents.simulate(_:)` on a runtime that
        // never starts real capture.
        systemEvents.onChange = { [weak self] state, _ in self?.systemActivityChanged(state) }
    }

    /// Dynamic type names of the plug-ins in use, for logs and the selftests.
    var modelsNote: String { "detector=\(String(describing: type(of: detector))) classifier=\(String(describing: type(of: classifier)))" }

    /// Brings capture, windows, filters, pipelines and health tracking up; follows display, permission, window and rule changes from
    /// then on. The models load while capture connects (~0.5 s): ~0.1 s when the ANE cache is warm, 3–5 s on the first launch after
    /// an update.
    func start() {
        DetectionMeter.shared.reset()  // M4-T07: a new Runtime starts from a clean detection history
        displayManager.start()
        lowPower.onChange = { [weak self] _ in self?.windowsChanged() }  // windowsChanged is the only writer of session.fps
        lowPower.start()
        systemEvents.start()
        windowTracker.start()
        filters.start()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.checkHealth()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        Task {
            await loadModels()
            reconcile()
            observe()
            observeWindows()
            windowsChanged()
        }
    }

    /// Selftests: stops pipelines and capture, closes the panels.
    func stop() async {
        healthTask?.cancel()
        healthTask = nil
        lowPower.stop()
        systemEvents.reset()
        for t in stallChecks.values { t.cancel() }
        stallChecks = [:]
        filters.stop()
        windowTracker.stop()
        for p in pipelines.values { await p.stop() }
        pipelines = [:]
        displayManager.stop()
    }

    var appearance: CoverAppearance {
        CoverAppearance(style: model.preferences.coverStyle, strength: model.preferences.blurStrength, padding: model.preferences.bodyPadding)
    }

    /// M2-T06 / M2-T07: `PersonDetector.mlmodelc` and `GenderClassifier.mlmodelc` from the bundle (`scripts/build-app.sh` compiles
    /// them in), both on `.cpuAndNeuralEngine` (the GPU stays free for rendering; `.all` put parts of the ViT on the GPU and doubled
    /// its latency). A model that cannot load leaves its fallback (Vision persons / every person Unknown) with one logged line.
    private func loadModels() async {
        let t0 = CACurrentMediaTime()
        async let d = Self.load("person detector (CoreML)") {
            try await CoreMLPersonDetector(contentsOf: Self.modelURL("PersonDetector"), computeUnits: .cpuAndNeuralEngine)
        }
        async let c = Self.load("gender classifier") { try await GenderClassifier(contentsOf: Self.modelURL("GenderClassifier")) }
        if let d = await d { detector = d }
        if let c = await c { classifier = c }
        log.info("models \(self.modelsNote, privacy: .public) load_ms=\(Int((CACurrentMediaTime() - t0) * 1000))")
    }

    private nonisolated static func load<T: Sendable>(_ what: String, _ make: @Sendable () async throws -> T) async -> T? {
        do {
            return try await make()
        } catch {
            Logger(subsystem: "com.goldentik.Sitr", category: "runtime")
                .error("\(what, privacy: .public) unavailable, using the fallback: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private nonisolated static func modelURL(_ name: String) throws -> URL {
        if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") { return url }
        // ponytail: dev fallback keyed on #filePath so a checkout's `.build/debug/Sitr` (selftests, `swift run`) finds Models/dist and
        // compiles it on the fly (~0.6 s per model); a shipped app has the bundle copy and never gets here.
        let dist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Models/dist/\(name).mlpackage")
        guard FileManager.default.fileExists(atPath: dist.path) else { throw ModelError("\(name).mlmodelc is not in the bundle") }
        return dist
    }

    /// One Pipeline per ManagedDisplay, following hot-plug. A new display gets a filter at the builder's next refresh.
    /// Idempotent: the keys of `pipelines` are exactly the ids of `displayManager.displays` when it returns, so however
    /// many times a transition calls it there is one pipeline, one panel and one stream per display (M4-T10).
    private func reconcile() {
        let current = displayManager.displays
        for id in Array(pipelines.keys) where !current.contains(where: { $0.id == id }) {
            let gone = pipelines.removeValue(forKey: id)
            sawOK.remove(id)
            DetectionMeter.shared.forget(display: id)  // M4-T07: an unplugged display leaves no degraded state behind
            filters.forget(id)
            Task { await gone?.stop() }
        }
        for d in current where pipelines[d.id] == nil {
            let p = Pipeline(displayID: d.id, frames: d.session.frames, panel: d.panel, renderer: d.renderer,
                             policy: model.policy, appearance: appearance, detector: detector, classifier: classifier)
            let id = d.id
            p.onCommit { [weak self] specs, frame, at in self?.frameCommitted(id, specs, frame, at) }
            p.onPreCover { [weak self] specs, frame, at in self?.onPreCover?(id, specs, frame, at) }
            p.update(windows: windowTracker.windows)
            pipelines[id] = p
            Task { await p.start() }
            filters.schedule()
        }
    }

    // MARK: - M4-T10 sleep / wake / lock / fast user switching

    /// The screen went away or came back. `.active` is only ever produced by a frame arriving, which `frameCommitted`
    /// already handles, so there is nothing to do for it here.
    private func systemActivityChanged(_ state: SystemActivity) {
        switch state {
        case .suspended: suspend()
        case .resuming: resume()
        case .active: break
        }
    }

    /// Going to sleep, locking, or handing the session to another user. Every stream stops on purpose (a stream macOS
    /// tears down under us costs an error and a backoff retry per display), the stall watches are cancelled, and every
    /// per-display judgement made against the old streams is forgotten — a session we stopped ourselves is not evidence
    /// of a lost grant, and detection timings from before a sleep say nothing about after it. Panels and pipelines are
    /// left exactly as they are: closing and reopening them is how duplicates appear.
    private func suspend() {
        for t in stallChecks.values { t.cancel() }
        stallChecks = [:]
        stalled = []
        sawOK = []
        sessionOK = [:]
        lastFrameAt = [:]
        curtainChangedAt = [:]
        curtainRects = [:]
        DetectionMeter.shared.reset()
        displayManager.suspendCapture()
        refreshFailClosed()  // FR10: Curtain windows stay covered across the gap, and through the wake
        logTopology("suspended")
    }

    /// Awake, unlocked, or our session is back. The topology is re-read first — displays can be plugged, unplugged,
    /// mirrored or re-arranged while we are away — then the streams come back, then the pipelines follow whatever the
    /// display set now is. Fail-closed covers stay up until the first frame commits (`frameCommitted`).
    private func resume() {
        permission.refresh()
        displayManager.refresh()
        displayManager.resumeCapture()
        reconcile()
        filters.refreshNow()  // the stream is new: its filter has to be installed again
        windowsChanged()
        checkHealth()
        refreshFailClosed()
        logTopology("resuming")
    }

    /// The M4-T10 invariant in one line per transition: one pipeline, one panel and one stream per managed display.
    private func logTopology(_ what: String) {
        let line = "\(what) displays=\(displayManager.displays.count) pipelines=\(pipelines.count) "
            + "panels=\(OverlayPanel.openCount) streams=\(CaptureSession.liveStreams)"
        log.notice("\(line, privacy: .public)")
    }

    /// M4-T10 seam for `--selftest robustness` and the unit tests: re-read the topology and reconcile panels, streams and
    /// pipelines in this turn, instead of waiting for the observation callback.
    func reconcileNow() {
        displayManager.refresh()
        reconcile()
        windowsChanged()
    }

    /// Displays (hot-plug), permission, and appearance preferences. `onChange` fires before the value lands; act next turn.
    private func observe() {
        withObservationTracking {
            _ = displayManager.displays
            _ = permission.state
            _ = model.preferences.coverStyle
            _ = model.preferences.blurStrength
            _ = model.preferences.bodyPadding
            _ = model.preferences.lowPowerReducesFrameRate
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.lowPower.update()  // M4-T06: the General toggle takes effect without waiting for a power state change
                self.reconcile()
                self.checkHealth()
                let a = self.appearance
                for p in self.pipelines.values { p.update(a) }
                self.windowsChanged()
                self.observe()
            }
        }
    }

    /// `WindowTracker.windows` changes (≤ 10 Hz, only when something moved / appeared / went).
    private func observeWindows() {
        withObservationTracking { _ = windowTracker.windows } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.windowsChanged()
                self.observeWindows()
            }
        }
    }

    /// Windows or rules changed: snapshot to the pipelines (attribution, Curtain tiles, clipping), capture rate per display
    /// (M3-T05), stall watch and fail-closed rects (M3-T06), filter rebuild when the set of window-owning processes changed (M3-T03).
    private func windowsChanged() {
        let windows = windowTracker.windows
        let rules = model.policy.rules
        let now = CACurrentMediaTime()
        for d in displayManager.displays {
            pipelines[d.id]?.update(windows: windows)
            d.session.fps = captureFPS(windows: windows, rules: rules, displayID: d.id, curtainFPS: Self.curtainFPS,
                                       cap: lowPower.cap)  // M4-T06 caps M3-T05's Curtain rate; each applies it with updateConfiguration
            let rects = windows.filter { $0.displayID == d.id && rules.mode(for: $0.bundleID) == .curtain }.map(\.rect)
            if rects != curtainRects[d.id] {
                curtainRects[d.id] = rects
                if !rects.isEmpty {
                    curtainChangedAt[d.id] = now
                    armStallCheck(d.id)
                }
            }
        }
        let pids = Set(windows.map(\.pid))
        if pids != windowPIDs {
            windowPIDs = pids
            filters.refreshNow()
        }
        refreshFailClosed()
    }

    /// One pending check per display: `stallAfter` after a Curtain window changed, was there a frame?
    private func armStallCheck(_ id: CGDirectDisplayID) {
        guard stallChecks[id] == nil else { return }
        stallChecks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.stallAfter + 0.05))
            guard !Task.isCancelled else { return }
            self?.checkStall(id)
        }
    }

    /// The stall rule (PRD FR10): a Curtain window changed at `curtainChangedAt`, no frame has been committed since, and that was
    /// `stallAfter` or longer ago. Pure, unit-tested.
    nonisolated static func isStalled(lastFrameAt: Double?, curtainChangedAt: Double, now: Double, stallAfter: Double = stallAfter) -> Bool {
        (lastFrameAt ?? -.infinity) < curtainChangedAt && now - curtainChangedAt >= stallAfter
    }

    private func checkStall(_ id: CGDirectDisplayID) {
        stallChecks[id] = nil
        // M4-T10: "no frame arrived" says nothing while the stream is parked for a sleep or a lock, and the covers are
        // already up for that reason. `windowsChanged` arms a fresh check once the topology is back.
        guard systemEvents.capturesFrames else { return }
        guard let changed = curtainChangedAt[id], permission.state == .granted,
              displayManager.displays.first(where: { $0.id == id })?.session.health.isOK == true else { return }
        let now = CACurrentMediaTime()
        guard (lastFrameAt[id] ?? 0) < changed else { return }  // a frame came after the change: healthy
        guard Self.isStalled(lastFrameAt: lastFrameAt[id], curtainChangedAt: changed, now: now) else { armStallCheck(id); return }  // still changing: look again
        guard !stalled.contains(id) else { return }
        stalled.insert(id)
        log.error("capture stalled on display \(id): no frame for \(Int((now - (self.lastFrameAt[id] ?? changed)) * 1000)) ms while Curtain windows changed")
        // ponytail: a stall is reported as `.degraded` (warning icon, one notification); `.needsPermission` would also reopen
        // onboarding and hide every Blur cover for what may be a transient hiccup. M4-T07 owns the degraded rules and strings.
        if model.policy.health == .ok {
            stallDegraded = true
            setHealth(.degraded)
        }
        refreshFailClosed()
    }

    /// M3-T06: while the grant is gone or a display's stream is stalled, every Curtain window on it gets a Solid cover over its
    /// visible region (rects from the `WindowTracker`, so they follow moves at 10 Hz); Blur apps stay uncovered. Lifted by the first
    /// frame the pipeline commits (`frameCommitted`).
    /// M4-T10 adds the suspended and resuming states to that: from the moment the Mac starts to sleep or the screen locks
    /// until the first frame after the wake, capture is not live, so Curtain windows are covered rather than trusted.
    private func refreshFailClosed() {
        let down = model.policy.health == .needsPermission || !systemEvents.capturesFrames
        for d in displayManager.displays {
            let specs = down || stalled.contains(d.id)
                ? failClosedSpecs(windows: windowTracker.windows, rules: model.policy.rules, displayID: d.id, color: d.renderer.solidColor) : []
            pipelines[d.id]?.update(failClosed: specs)
        }
    }

    /// M2-T16: no grant, or a capture session that stopped or errored → `.needsPermission` (Blur fails open, warning icon,
    /// one notification). Back to `.ok` on the first frame a pipeline commits once every session runs again. A session's
    /// initial `.stopped(nil)` before its first connect is not a failure; `stop()` after it ran is.
    /// M4-T07: with capture healthy, slow detection is `.degraded` and speeding up again clears it (`DetectionMeter`).
    /// Needs permission outranks degraded (FR7) and only a committed frame leaves it.
    /// M4-T10: across sleep, lock and fast user switching the streams are down because we stopped them, so health holds
    /// where it is until capture has had `SystemActivityMachine.settleFor` to come back. A grant that is really gone still
    /// reports immediately, and the covers do not depend on this — `refreshFailClosed` keeps Curtain windows covered for
    /// the whole transition.
    func checkHealth() {
        if permission.state == .granted, systemEvents.holdsHealth() { return }
        var failed = permission.state != .granted
        for d in displayManager.displays {
            switch d.session.health {
            case .ok: sessionBecameOK(d.id)
            case .stopped(let error):
                sessionOK[d.id] = false
                if error != nil || sawOK.contains(d.id) { failed = true }
            }
        }
        if failed {
            setHealth(.needsPermission)
        } else if model.policy.health != .needsPermission {
            setHealth(detectionHealth)
        }
    }

    /// `.degraded` while any display's detection has been over 250 ms/frame for 3 s (PRD FR10).
    private var detectionHealth: Health { DetectionMeter.shared.isDegraded ? .degraded : .ok }

    /// A session (re)connected: install its filter on the live stream. `CaptureSession.updateFilter` while `connect()` is between
    /// `SCStream(...)` and `stream = s` only records the filter (`stream` is still nil), so the first install can be lost and the
    /// stream runs with the default own-process exclusion until this re-install (a few frames after the first `.ok`).
    // ponytail: the fix belongs in CaptureSession.connect (apply `customFilter` after `stream = s` when it changed meanwhile),
    // not this task's file; until then the 250 ms health poll plus one SCShareableContent fetch bound the leak.
    private func sessionBecameOK(_ id: CGDirectDisplayID) {
        sawOK.insert(id)
        guard sessionOK[id] != true else { return }
        sessionOK[id] = true
        filters.forget(id)
        filters.refreshNow()
    }

    private func frameCommitted(_ id: CGDirectDisplayID, _ specs: [CoverLayerSpec], _ frame: Frame, _ at: Double) {
        sessionBecameOK(id)
        lastFrameAt[id] = at
        // M4-T10: the wake is over and the covers can come down — but only on a frame from a stream that is actually
        // connected. `SCStream.stopCapture` is asynchronous, so a frame or two from the stream we tore down for the sleep
        // still arrives afterwards; ending the resume on one of those closes the health grace before the new stream is up
        // and flashes "Needs Screen Recording permission" on the way through.
        if displayManager.displays.first(where: { $0.id == id })?.session.isConnected == true, systemEvents.framesResumed() {
            refreshFailClosed()
        }
        if stalled.remove(id) != nil {
            if stalled.isEmpty, stallDegraded, model.policy.health == .degraded {
                stallDegraded = false
                setHealth(.ok)
            }
            refreshFailClosed()
        }
        if model.policy.health == .needsPermission, permission.state == .granted,
           displayManager.displays.allSatisfy({ $0.session.health.isOK }) {
            setHealth(detectionHealth)  // capture is back; slow detection stays degraded rather than flashing `.ok`
        }
        onCommit?(id, specs, frame, at)
    }

    private func setHealth(_ health: Health) {
        guard model.policy.health != health else { return }
        model.policy.health = health
        notifier.healthChanged(to: health)
        refreshFailClosed()
    }
}

nonisolated struct ModelError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
