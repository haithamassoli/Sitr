// M2-T04: display topology. One CaptureSession + one OverlayPanel + one CoverRenderer per NSScreen, keyed by
// CGDirectDisplayID (the same id `SCDisplay.displayID` carries). Re-reconciles 300 ms after the last screen-parameter change.
import AppKit
import Observation

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
    private(set) var displays: [ManagedDisplay] = []
    let permission: PermissionMonitor
    @ObservationIgnored private var running = false
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

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
        refresh()
        observePermission()
    }

    /// Stops every session and closes every panel.
    func stop() {
        running = false
        debounce?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        for d in displays {
            d.session.stop()
            d.panel.close()
        }
        displays = []
    }

    /// Reveal Hold (M2-T13): hides or shows every cover on every display.
    func setRevealed(_ revealed: Bool) {
        for d in displays { d.panel.setRevealed(revealed) }
    }

    /// Reconciles `displays` with `NSScreen.screens` now. Kept displays whose frame or scale changed get their panel frame
    /// updated and their stream restarted (the output size follows the new geometry).
    func refresh() {
        guard running else { return }
        let screens = Dictionary(NSScreen.screens.compactMap { s in s.displayID.map { ($0, s) } }, uniquingKeysWith: { a, _ in a })
        let diff = DisplayDiff.compute(current: displays.map(\.id), desired: Array(screens.keys))
        for d in displays where diff.remove.contains(d.id) {
            d.session.stop()
            d.panel.close()
        }
        displays.removeAll { diff.remove.contains($0.id) }
        for i in displays.indices {
            guard let s = screens[displays[i].id],
                  s.frame != displays[i].frame || s.backingScaleFactor != displays[i].scale else { continue }
            displays[i].frame = s.frame
            displays[i].scale = s.backingScaleFactor
            displays[i].panel.setFrame(s.frame, display: true)
            displays[i].session.restart()
        }
        for id in diff.add {
            guard let s = screens[id] else { continue }
            let d = ManagedDisplay(id: id, frame: s.frame, scale: s.backingScaleFactor,
                                   session: CaptureSession(displayID: id, permission: permission),
                                   panel: OverlayPanel(screenFrame: s.frame), renderer: CoverRenderer())
            d.panel.orderFrontRegardless()
            displays.append(d)
            if permission.state == .granted { d.session.start() }
        }
    }

    /// macOS posts several screen-parameter notifications per topology change; act once, 300 ms after the last.
    private func scheduleRefresh() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// Capture follows the grant: sessions start when it arrives and stop when it goes (panels stay; covers are Policy's call).
    private func observePermission() {
        withObservationTracking { _ = permission.state } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.running else { return }
                let granted = self.permission.state == .granted
                for d in self.displays { granted ? d.session.start() : d.session.stop() }
                self.observePermission()
            }
        }
    }
}

extension NSScreen {
    /// `CGDirectDisplayID` of this screen: the key shared with `SCDisplay.displayID` and `CGDisplayBounds`.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
