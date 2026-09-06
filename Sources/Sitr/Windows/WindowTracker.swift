// M3-T02: which app owns which on-screen region. One WindowServer round-trip (`CGWindowListCopyWindowInfo`) at 10 Hz plus an
// immediate refresh on app activate / launch / terminate; owner PID → bundle ID through `NSRunningApplication`, cached per PID.
// Never reads window titles (`kCGWindowName`): bundle IDs, bounds and counts only. Works without Screen Recording permission
// (the window list is public; only titles are gated), which FR10's fail-closed Curtain covers rely on.
import AppKit
import Observation

/// One on-screen window clipped to one display. A window straddling two displays yields one entry per display.
nonisolated struct WindowRect: Sendable, Hashable {
    let windowID: CGWindowID
    let pid: pid_t
    /// `nil` when the owner is not an application (or vanished before it was resolved).
    var bundleID: String?
    let displayID: CGDirectDisplayID
    /// Display-local points, origin at the display's top-left, y down — the space `CoverLayerSpec.frame` and `Frame` use.
    let rect: CGRect
    /// Front-to-back index among the kept windows; 0 = frontmost. The per-display entries of one window share it.
    let zOrder: Int
}

@Observable @MainActor
final class WindowTracker {
    /// Front to back (ascending `zOrder`). Reassigned only when something changed, so observers stay quiet on a static screen.
    private(set) var windows: [WindowRect] = []
    // ponytail: 10 Hz polling (measured 0.15–0.21 % of a core in release with ~23 on-screen windows, scales with that count;
    // docs/m3/window-tracker.md) instead of window-server notifications, which need the private SkyLight API or one AX observer
    // per app. Upgrade = SkyLight `SLSRegisterConnectionNotifyProc`, or 200 ms here if a quiet-phase measurement is over 0.3 %.
    private static let pollInterval: Duration = .milliseconds(100)
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// PID → bundle ID; `.some(nil)` = resolved, not an app. Rebuilt from the PIDs seen on every refresh, so a terminated app's
    /// entry goes at the refresh its terminate notification triggers.
    // ponytail: a PID reused by a new process within one poll interval would keep the old bundle ID; upgrade = key by (pid, launchDate).
    @ObservationIgnored private var bundleIDs: [pid_t: String?] = [:]

    /// Refreshes now, then every 100 ms and on `NSWorkspace` activate / launch / terminate. Idempotent.
    func start() {
        guard pollTask == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self, !Task.isCancelled else { return }
                self.refresh()
            }
        }
    }

    /// Stops polling and clears `windows` (no stale rects for consumers).
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers = []
        windows = []
    }

    /// One WindowServer round-trip → `windows`. Displays come from `NSScreen.screens` so the IDs match `DisplayManager`'s keys;
    /// their bounds from `CGDisplayBounds` (the window list's coordinate space).
    func refresh() {
        let displays = NSScreen.screens.compactMap(\.displayID).map { (id: $0, bounds: CGDisplayBounds($0)) }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        var next = WindowGeometry.parse(list, displays: displays)
        var seen = Set<pid_t>()
        for i in next.indices {
            let pid = next[i].pid
            if bundleIDs[pid] == nil { bundleIDs[pid] = .some(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier) }
            next[i].bundleID = bundleIDs[pid] ?? nil
            seen.insert(pid)
        }
        bundleIDs = bundleIDs.filter { seen.contains($0.key) }
        if next != windows { windows = next }
    }

    /// Frontmost window under a display-local point (per-detection attribution); `nil` over the desktop.
    func topmostWindow(at point: CGPoint, on displayID: CGDirectDisplayID) -> WindowRect? {
        windows.first { $0.displayID == displayID && $0.rect.contains(point) }
    }

    /// Every on-screen window of one app, front to back (Curtain covers, FR10 fail-closed).
    func windows(for bundleID: String) -> [WindowRect] {
        windows.filter { $0.bundleID == bundleID }
    }
}

/// Pure geometry and parsing, unit-tested. `CGWindowListCopyWindowInfo` bounds and `CGDisplayBounds` share the global Core
/// Graphics space (origin at the main display's top-left, y down), so display-local = global − display origin, clipped to the
/// display. Never `NSScreen.frame` here (AppKit, y up).
nonisolated enum WindowGeometry {
    typealias Display = (id: CGDirectDisplayID, bounds: CGRect)

    /// The part of `globalRect` on each display, in that display's local space; empty when it is off every display.
    static func split(globalRect: CGRect, displays: [Display]) -> [(id: CGDirectDisplayID, localRect: CGRect)] {
        displays.compactMap { d in
            let clipped = globalRect.intersection(d.bounds)
            guard !clipped.isEmpty else { return nil }
            return (d.id, clipped.offsetBy(dx: -d.bounds.minX, dy: -d.bounds.minY))
        }
    }

    /// Window-list dictionaries (front to back) → `WindowRect`s with `bundleID == nil`: layer 0 only, alpha > 0, at least 8×8 pt,
    /// one entry per display touched. Walks the CF objects directly: bridging to `[[String: Any]]` doubled the per-poll CPU.
    static func parse(_ list: CFArray?, displays: [Display]) -> [WindowRect] {
        guard let list else { return [] }
        var out: [WindowRect] = []
        var z = 0
        for i in 0..<CFArrayGetCount(list) {
            guard let p = CFArrayGetValueAtIndex(list, i), CFGetTypeID(unsafeBitCast(p, to: CFTypeRef.self)) == CFDictionaryGetTypeID()
            else { continue }
            let info = unsafeBitCast(p, to: CFDictionary.self)
            guard number(info, kCGWindowLayer) == 0, (number(info, kCGWindowAlpha) ?? 1) > 0,
                  let bounds = rect(info, kCGWindowBounds), bounds.width >= 8, bounds.height >= 8,
                  let wid = number(info, kCGWindowNumber), let pid = number(info, kCGWindowOwnerPID)
            else { continue }
            let parts = split(globalRect: bounds, displays: displays)
            guard !parts.isEmpty else { continue }
            for part in parts {
                out.append(WindowRect(windowID: CGWindowID(wid), pid: pid_t(pid), bundleID: nil,
                                      displayID: part.id, rect: part.localRect, zOrder: z))
            }
            z += 1
        }
        return out
    }

    private static func value(_ d: CFDictionary, _ key: CFString, _ typeID: CFTypeID) -> CFTypeRef? {
        guard let p = CFDictionaryGetValue(d, Unmanaged.passUnretained(key).toOpaque()) else { return nil }
        let v = unsafeBitCast(p, to: CFTypeRef.self)
        return CFGetTypeID(v) == typeID ? v : nil
    }

    private static func number(_ d: CFDictionary, _ key: CFString) -> Double? {
        guard let v = value(d, key, CFNumberGetTypeID()) else { return nil }
        var out = 0.0
        return CFNumberGetValue(unsafeDowncast(v, to: CFNumber.self), .doubleType, &out) ? out : nil
    }

    private static func rect(_ d: CFDictionary, _ key: CFString) -> CGRect? {
        value(d, key, CFDictionaryGetTypeID()).flatMap { CGRect(dictionaryRepresentation: unsafeDowncast($0, to: CFDictionary.self)) }
    }
}
