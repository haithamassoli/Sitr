// M4-T10: the transitions that take the screen away from us — the Mac sleeping, the screen locking, the displays going
// dark, another user taking the session — and the ones that give it back. All eight are notifications; this turns them
// into `SystemActivity` (SitrCore, pure) and hands `Runtime` one callback. `simulate(_:)` drives the same path, so the
// unit tests and `--selftest robustness` run twenty wake cycles without touching the machine's power state.
import AppKit
import QuartzCore
import SitrCore
import os

@MainActor final class SystemEventMonitor {
    typealias Event = SystemActivityMachine.Event

    /// New state, and the event that produced it. Called on the main actor, after the machine has moved.
    var onChange: ((SystemActivity, Event) -> Void)?
    /// Events seen since creation, newest last (selftest output and the "no event was dropped" assertions).
    private(set) var seen: [Event] = []

    private var machine = SystemActivityMachine()
    private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
    private let log = Logger(subsystem: "com.goldentik.Sitr", category: "system")

    var state: SystemActivity { machine.state }
    var reasons: SuspensionReasons { machine.reasons }
    /// PRD FR10: fail-closed covers stay up while capture is not known to be live.
    var capturesFrames: Bool { machine.capturesFrames }

    /// `NSWorkspace` sleep/wake, session (fast user switching) and screen-power notifications, plus the two distributed
    /// notifications macOS posts for the lock screen. Idempotent.
    func start() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let pairs: [(Notification.Name, Event)] = [
            (NSWorkspace.willSleepNotification, .willSleep),
            (NSWorkspace.didWakeNotification, .didWake),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionResignedActive),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionBecameActive),
            (NSWorkspace.screensDidSleepNotification, .screensDidSleep),
            (NSWorkspace.screensDidWakeNotification, .screensDidWake),
        ]
        for (name, event) in pairs { observe(name, as: event, on: workspace) }
        // Lock and unlock have no public NSWorkspace notification; these two are what the system posts, and receiving a
        // distributed notification is allowed inside the sandbox (the M3 selftests already rely on that).
        // ponytail: undocumented names — if they ever stop arriving, a lock still reaches us as `screensDidSleep` a few
        // seconds later (display sleep on lock), so the worst case is a late suspend, never a missed one.
        let distributed = DistributedNotificationCenter.default() as NotificationCenter
        observe(Notification.Name("com.apple.screenIsLocked"), as: .screenLocked, on: distributed)
        observe(Notification.Name("com.apple.screenIsUnlocked"), as: .screenUnlocked, on: distributed)
    }

    func stop() {
        for o in observers { o.center.removeObserver(o.token) }
        observers = []
    }

    /// Test and selftest seam: the exact path a real notification takes, minus the notification.
    func simulate(_ event: Event) {
        handle(event)
    }

    /// A frame reached the pipeline. Returns true when that ended a resume (`.resuming` → `.active`), so the caller can
    /// drop the fail-closed covers it was holding.
    @discardableResult
    func framesResumed() -> Bool {
        guard machine.framesResumed(at: CACurrentMediaTime()) != nil else { return false }
        log.notice("system resumed: frames are flowing again")
        return true
    }

    /// True while a stopped stream is explained by the transition rather than by a lost grant.
    func holdsHealth() -> Bool {
        machine.holdsHealth(at: CACurrentMediaTime())
    }

    /// `Runtime.stop()`: back to a cold `.active` with nothing observed.
    func reset() {
        stop()
        machine.reset()
        seen = []
    }

    private func observe(_ name: Notification.Name, as event: Event, on center: NotificationCenter) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        observers.append((center, token))
    }

    private func handle(_ event: Event) {
        seen.append(event)
        let state = machine.handle(event, at: CACurrentMediaTime())
        let line = "system \(event) reasons=\(machine.reasons.rawValue) state=\(machine.state) changed=\(state != nil)"
        log.notice("\(line, privacy: .public)")
        guard let state else { return }
        onChange?(state, event)
    }
}
