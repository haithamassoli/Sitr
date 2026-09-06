// M3-T03: rules → one `SCContentFilter` per display, kept live. Default Rule Off: capture only the override apps (Blur / Curtain).
// Default Rule on: capture everything except the Off apps and our own process (the overlay panels must never feed back into
// detection; docs/spike/overlay.md). Rebuilt, debounced 300 ms, on a rules change, on `NSWorkspace` launch / terminate, and
// when the set of window-owning processes changes (`Runtime` forwards `WindowTracker` changes: an app launched after start shows up
// in `SCShareableContent.applications` only once it has a window). `CaptureSession.updateFilter` swaps the filter on the running stream.
import AppKit
import ScreenCaptureKit
import SitrCore

/// Which processes a display's filter names, from the rules alone. Pure, unit-tested.
nonisolated enum FilterPlan: Equatable, Sendable {
    /// Default Rule Off: only these apps are captured (an empty list captures the bare desktop).
    case include([pid_t])
    /// Default Rule Blur / Curtain: everything but these apps (Off apps and our own process).
    case exclude([pid_t])

    struct App: Equatable, Sendable {
        var pid: pid_t
        var bundleID: String

        init(pid: pid_t, bundleID: String) {
            self.pid = pid
            self.bundleID = bundleID
        }
    }

    /// `apps` = `SCShareableContent.applications` (pid + bundle id); `ownPID` is never included and always excluded.
    static func compute(rules: Rules, apps: [App], ownPID: pid_t) -> FilterPlan {
        if rules.defaultMode == .off {
            return .include(apps.filter { $0.pid != ownPID && rules.isMonitored($0.bundleID) }.map(\.pid))
        }
        return .exclude(apps.filter { $0.pid == ownPID || !rules.isMonitored($0.bundleID) }.map(\.pid))
    }
}

@MainActor final class FilterBuilder {
    /// Debounce for launch / terminate bursts and rapid rule edits.
    static let debounce: Duration = .milliseconds(300)

    var rules: Rules { didSet { if rules != oldValue { schedule() } } }
    /// Selftests only: keep capturing our own windows other than the overlay panels (the in-process stimulus). The app never sets it.
    var capturesOwnWindows = false { didSet { if capturesOwnWindows != oldValue { schedule() } } }
    /// Filters installed since creation, and the plan behind each display's current filter (selftests and logs).
    private(set) var installs = 0
    private(set) var plans: [CGDirectDisplayID: FilterPlan] = [:]
    /// Last error from `SCShareableContent` / `updateFilter`, for the selftest lines.
    private(set) var lastError: String?

    private let displays: @MainActor () -> [ManagedDisplay]
    private var observers: [any NSObjectProtocol] = []
    private var pending: Task<Void, Never>?
    /// Signature of what each display's stream currently filters, so an unchanged plan does not touch the stream.
    private var installed: [CGDirectDisplayID: String] = [:]

    init(rules: Rules, displays: @escaping @MainActor () -> [ManagedDisplay]) {
        self.rules = rules
        self.displays = displays
    }

    /// Installs filters now and follows app launches / terminations from then on. Idempotent.
    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            })
        }
        refreshNow()
    }

    /// Rebuild without the debounce: the first install, and a change in the set of window-owning processes (the tracker already
    /// coalesces those at 10 Hz), so a new Off app leaves the frames after one `SCShareableContent` fetch, not 300 ms later.
    func refreshNow() {
        pending?.cancel()
        pending = Task { [weak self] in await self?.refresh() }
    }

    func stop() {
        pending?.cancel()
        pending = nil
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers = []
    }

    /// A display's session was (re)created: forget what it had so the next refresh installs a filter on it.
    func forget(_ id: CGDirectDisplayID) {
        installed[id] = nil
        plans[id] = nil
    }

    /// Rebuild after `debounce`; a burst of triggers collapses into one `SCShareableContent` fetch.
    func schedule() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// One `SCShareableContent` fetch → one filter per display, installed only where the plan changed.
    func refresh() async {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            lastError = String(describing: error)
            return
        }
        guard !Task.isCancelled else { return }
        let own = getpid()
        let apps = content.applications.map { FilterPlan.App(pid: $0.processID, bundleID: $0.bundleIdentifier) }
        let plan = FilterPlan.compute(rules: rules, apps: apps, ownPID: own)
        let byPID = Dictionary(content.applications.map { ($0.processID, $0) }, uniquingKeysWith: { a, _ in a })
        let managed = displays()
        let panelIDs = Set(managed.map { CGWindowID($0.panel.windowNumber) })
        // Selftest mode: our process stays excluded, but every own window that is not an overlay panel is excepted back in.
        let ownWindows = capturesOwnWindows
            ? content.windows.filter { $0.owningApplication?.processID == own && !panelIDs.contains($0.windowID) } : []
        let panels = capturesOwnWindows ? content.windows.filter { panelIDs.contains($0.windowID) } : []
        let signature = "\(plan) own=\(ownWindows.map(\.windowID).sorted()) panels=\(panels.map(\.windowID).sorted())"
        for d in managed {
            guard let display = content.displays.first(where: { $0.displayID == d.id }) else { continue }
            plans[d.id] = plan
            guard installed[d.id] != signature else { continue }
            let filter: SCContentFilter
            switch plan {
            case .include(let pids):
                var included = pids.compactMap { byPID[$0] }
                if capturesOwnWindows, let me = byPID[own] { included.append(me) }
                filter = SCContentFilter(display: display, including: included, exceptingWindows: panels)
            case .exclude(let pids):
                filter = SCContentFilter(display: display, excludingApplications: pids.compactMap { byPID[$0] }, exceptingWindows: ownWindows)
            }
            do {
                try await d.session.updateFilter(filter)
                installed[d.id] = signature
                installs += 1
            } catch {
                lastError = String(describing: error)
            }
        }
    }
}
