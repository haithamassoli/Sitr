// M2-T04: display topology. One CaptureSession + one OverlayPanel + one CoverRenderer per NSScreen, keyed by
// CGDirectDisplayID (the same id `SCDisplay.displayID` carries). Re-reconciles 300 ms after the last screen-parameter change.
// M4-T10: `CGDisplayRegisterReconfigurationCallback` is a second trigger (it fires for changes AppKit does not post, and
// for the wake of a display that never changed geometry), mirror sets collapse to one panel, and `suspend()`/`resume()`
// park the streams across sleep, lock and fast user switching without touching the panels.
import AppKit
import Observation
import SitrCore
import ScreenCaptureKit
import os

/// Everything Sitr keeps per display. The members are references; treat the struct as a handle.
struct ManagedDisplay: Identifiable {
    let id: CGDirectDisplayID
    /// `NSScreen.frame`: global AppKit points, origin at the bottom-left of the main display.
    var frame: CGRect
    var scale: CGFloat
    let session: CaptureSession
    let panel: OverlayPanel
    let renderer: CoverRenderer
}

/// One line of the display list: what `NSScreen` says plus what `CGDisplayMirrorsDisplay` says. The M4-T10 test seam
/// feeds these directly, so hot-plug, resolution changes and mirroring are exercised without hardware.
struct ScreenSnapshot: Hashable, Sendable {
    var id: CGDirectDisplayID
    var frame: CGRect
    var scale: CGFloat
    /// The display this one mirrors, 0 for none.
    var mirrors: CGDirectDisplayID = 0
}

/// add / remove / keep between the displays we manage and the displays macOS reports. Pure, unit-tested.
nonisolated enum DisplayDiff {
    struct Result: Equatable {
        var add: [CGDirectDisplayID] = []
        var remove: [CGDirectDisplayID] = []
        var keep: [CGDirectDisplayID] = []
    }

    static func compute(current: [CGDirectDisplayID], desired: [CGDirectDisplayID]) -> Result {
        let have = Set(current), want = Set(desired)
        return Result(add: desired.filter { !have.contains($0) },
                      remove: current.filter { !want.contains($0) },
                      keep: desired.filter { have.contains($0) })
    }
}

@Observable @MainActor
final class DisplayManager {
    /// macOS posts several screen-parameter notifications per topology change, and a `CGDisplay` reconfiguration arrives
    /// as a begin/end pair per display; act once, this long after the last one.
    static let refreshDebounce: Duration = .milliseconds(300)

    private(set) var displays: [ManagedDisplay] = []
    let permission: PermissionMonitor
    var makeFilter: ((SCDisplay, SCShareableContent) throws -> SCContentFilter)?
    var processingEnabled = true {
        didSet {
            guard processingEnabled != oldValue else { return }
            for d in displays {
                if processingEnabled && !suspended && captureAvailable { d.session.start() }
                else { d.session.stop() }
            }
        }
    }
    /// M4-T10 test / selftest seam: the screen list to reconcile against, instead of `NSScreen.screens`. Simulated
    /// displays get sessions that never talk to ScreenCaptureKit and panels that are never ordered on screen, so hot-plug,
    /// mirroring and twenty wake cycles cost nothing and disturb nothing. nil = the real hardware.
    @ObservationIgnored var simulatedScreens: [ScreenSnapshot]? {
        didSet { if running, simulatedScreens != oldValue { refresh() } }
    }
    /// M4-T10: streams are parked (sleep, lock, fast user switching). Panels and pipelines stay exactly as they are.
    @ObservationIgnored private(set) var suspended = false
    /// The ids `refresh()` last decided to manage. A session asks this before backing off against a display that is gone.
    @ObservationIgnored private(set) var knownIDs: Set<CGDirectDisplayID> = []
    @ObservationIgnored private var running = false
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var observer: (any NSObjectProtocol)?
    @ObservationIgnored private var reconfigurationCallbackInstalled = false
    @ObservationIgnored private let log = Logger(subsystem: "com.goldentik.Sitr", category: "displays")

    /// A simulated topology is its own world: no TCC is involved, so its sessions run whenever we are not suspended.
    private var captureAvailable: Bool { simulatedScreens != nil || permission.state == .granted }

    init(permission: PermissionMonitor) {
        self.permission = permission
    }

    /// Creates panels for the current screens, starts capture while permission is granted, follows topology and permission changes.
    func start() {
        guard !running else { return }
        running = true
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.scheduleRefresh() } }
        installReconfigurationCallback()
        refresh()
        observePermission()
    }

    /// Stops every session and closes every panel.
    func stop() {
        running = false
        suspended = false
        debounce?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        removeReconfigurationCallback()
        for d in displays {
            d.session.stop()
            d.panel.close()
        }
        displays = []
        knownIDs = []
    }

    /// Reveal Hold (M2-T13): hides or shows every cover on every display.
    func setRevealed(_ revealed: Bool) {
        for d in displays { d.panel.setRevealed(revealed) }
    }

    /// M4-T10: the Mac is going to sleep, the screen is locking, or another user is taking the session. Every stream is
    /// stopped on purpose — macOS tears them down anyway, and a torn-down stream costs an error and a backoff retry per
    /// display — while the panels, the renderers and the pipelines stay untouched. Closing and reopening panels here is
    /// exactly how duplicates appear, so this never does.
    func suspendCapture() {
        guard !suspended else { return }
        suspended = true
        for d in displays { d.session.stop() }
        log.notice("displays suspended count=\(self.displays.count) streams=\(CaptureSession.liveStreams)")
    }

    /// M4-T10: awake, unlocked, or our session is back. Starts every stream that should be running; the caller refreshes
    /// the topology first, since displays can be plugged, unplugged or re-arranged while we were away.
    func resumeCapture() {
        guard suspended else { return }
        suspended = false
        guard captureAvailable, processingEnabled else { return }
        for d in displays { d.session.start() }
        log.notice("displays resumed count=\(self.displays.count)")
    }

    /// Reconciles `displays` with the screen list now. Kept displays whose frame or scale changed get their panel frame
    /// updated and their stream restarted (the output size follows the new geometry).
    func refresh() {
        guard running else { return }
        let snapshots = screenSnapshots()
        // One panel per distinct id, and none for a display that only mirrors another one we already manage (M4-T10).
        var byID: [CGDirectDisplayID: ScreenSnapshot] = [:]
        for s in snapshots where byID[s.id] == nil { byID[s.id] = s }
        let desired = DisplayTopology.managed(snapshots.map { DisplayLink(id: $0.id, mirrors: $0.mirrors) })
        knownIDs = Set(desired)
        let diff = DisplayDiff.compute(current: displays.map(\.id), desired: desired)
        for d in displays where diff.remove.contains(d.id) {
            d.session.stop()
            d.panel.close()
        }
        displays.removeAll { diff.remove.contains($0.id) }
        for i in displays.indices {
            guard let s = byID[displays[i].id],
                  s.frame != displays[i].frame || s.scale != displays[i].scale else { continue }
            displays[i].frame = s.frame
            displays[i].scale = s.scale
            displays[i].panel.setFrame(s.frame, display: true)
            displays[i].session.restart()
        }
        for id in diff.add {
            guard let s = byID[id] else { continue }
            let simulated = simulatedScreens != nil
            let session = CaptureSession(displayID: id, permission: permission, simulated: simulated)
            session.makeFilter = makeFilter
            session.displayIsPresent = { [weak self] in self?.knownIDs.contains(id) ?? false }
            let d = ManagedDisplay(id: id, frame: s.frame, scale: s.scale, session: session,
                                   panel: OverlayPanel(screenFrame: s.frame), renderer: CoverRenderer())
            if !simulated { d.panel.orderFrontRegardless() }  // a synthetic topology puts nothing on the user's screen
            displays.append(d)
            if captureAvailable, !suspended, processingEnabled { d.session.start() }
        }
        if !diff.add.isEmpty || !diff.remove.isEmpty {
            let line = "displays reconciled count=\(displays.count) added=\(diff.add) removed=\(diff.remove) "
                + "panels=\(OverlayPanel.openCount) streams=\(CaptureSession.liveStreams)"
            log.notice("\(line, privacy: .public)")
        }
    }

    /// The screen list: the seam if one is installed, else `NSScreen.screens` plus each screen's mirror master.
    private func screenSnapshots() -> [ScreenSnapshot] {
        if let simulatedScreens { return simulatedScreens }
        return NSScreen.screens.compactMap { s in
            s.displayID.map { ScreenSnapshot(id: $0, frame: s.frame, scale: s.backingScaleFactor, mirrors: CGDisplayMirrorsDisplay($0)) }
        }
    }

    /// macOS posts several screen-parameter notifications per topology change; act once, `refreshDebounce` after the last.
    private func scheduleRefresh() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: DisplayManager.refreshDebounce)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// M4-T10: `NSApplication.didChangeScreenParametersNotification` needs a live app run loop and does not fire for every
    /// change a display can go through (a mirror set forming, a display waking with the same geometry). The CoreGraphics
    /// callback does, and it costs one registration. Both land on the same debounced `refresh()`, so a change that fires
    /// both is still one reconciliation.
    private func installReconfigurationCallback() {
        guard !reconfigurationCallbackInstalled else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = CGDisplayRegisterReconfigurationCallback(sitrDisplayReconfigured, context)
        reconfigurationCallbackInstalled = status == .success
        if status != .success { log.error("CGDisplayRegisterReconfigurationCallback failed: \(status.rawValue)") }
    }

    private func removeReconfigurationCallback() {
        guard reconfigurationCallbackInstalled else { return }
        CGDisplayRemoveReconfigurationCallback(sitrDisplayReconfigured, Unmanaged.passUnretained(self).toOpaque())
        reconfigurationCallbackInstalled = false
    }

    /// Called by the CoreGraphics callback below (already on the main thread).
    fileprivate func displayReconfigured(_ id: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags) {
        guard !flags.contains(.beginConfigurationFlag) else { return }  // the pair's "about to change" half says nothing yet
        log.notice("display \(id) reconfigured flags=\(flags.rawValue)")
        scheduleRefresh()
    }

    /// Capture follows the grant: sessions start when it arrives and stop when it goes (panels stay; covers are Policy's call).
    private func observePermission() {
        withObservationTracking { _ = permission.state } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.running else { return }
                let granted = self.captureAvailable && !self.suspended && self.processingEnabled
                for d in self.displays { granted ? d.session.start() : d.session.stop() }
                self.observePermission()
            }
        }
    }
}

/// `CGDisplayReconfigurationCallBack`: a C function pointer, so it cannot capture. CoreGraphics delivers it on the main
/// thread of the process that registered it.
private nonisolated func sitrDisplayReconfigured(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let manager = Unmanaged<DisplayManager>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { manager.displayReconfigured(display, flags) }
}

extension NSScreen {
    /// `CGDirectDisplayID` of this screen: the key shared with `SCDisplay.displayID` and `CGDisplayBounds`.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
