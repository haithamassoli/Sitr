// M2-T03: Screen Recording permission. State transitions live in `PermissionLogic` (pure, unit-tested); the monitor
// wires them to TCC (`CGPreflightScreenCaptureAccess`), app activation, a 5 s poll while denied/revoked, and stream errors.
import AppKit
import Observation
import ScreenCaptureKit

@Observable @MainActor
final class PermissionMonitor {
    nonisolated enum State: Equatable, Sendable {
        case unknown
        case granted
        case denied
        /// Was granted once in this process (or a stream was running) and the grant is gone: macOS's monthly re-approval,
        /// `tccutil reset`, or the user toggling Screen Recording off. Same capabilities as `denied`, different wording.
        case revoked
    }

    private(set) var state: State = .unknown {
        didSet { if oldValue != state { pollWhileDenied() } }
    }
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?

    init() {
        // Menu bar apps rarely activate, so this is a bonus on top of the poll; it fires when the user comes back from System Settings.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        refresh()
    }

    /// Re-reads TCC now.
    func refresh() {
        state = PermissionLogic.transition(from: state, preflight: CGPreflightScreenCaptureAccess())
    }

    /// Shows the system prompt (macOS shows it at most once per TCC lifetime; afterwards only `openSystemSettings()` helps).
    func request() {
        _ = CGRequestScreenCaptureAccess()  // the dialog is asynchronous; the poll picks up the answer
        refresh()
    }

    /// System Settings › Privacy & Security › Screen & System Audio Recording.
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Capture layer: a stream stopped with a revocation-class `SCStreamError` (`PermissionLogic.isRevocation`).
    /// The preflight has the last word: a stream the user stopped from the menu bar's recording indicator leaves the grant intact.
    func markRevoked() {
        state = PermissionLogic.transition(from: state, streamErrorIsRevocation: true, preflight: CGPreflightScreenCaptureAccess())
    }

    private func pollWhileDenied() {
        pollTask?.cancel()
        pollTask = nil
        guard state == .denied || state == .revoked else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }
}

/// Pure transitions so grant / deny / revoke are unit-tested; the real TCC cycle is a manual item (see docs/m2/track-a.md).
nonisolated enum PermissionLogic {
    /// Preflight result → state. A `false` after `granted` (or `revoked`) is `revoked`; before any grant it is `denied`.
    static func transition(from state: PermissionMonitor.State, preflight: Bool) -> PermissionMonitor.State {
        if preflight { return .granted }
        switch state {
        case .granted, .revoked: return .revoked
        case .unknown, .denied: return .denied
        }
    }

    /// Stream error → state. Non-revocation errors are transient (the session restarts with backoff) and change nothing.
    /// A revocation-class error with a `true` preflight means the stream was stopped without losing the grant (recording
    /// indicator, system), so the state stays `granted`.
    static func transition(from state: PermissionMonitor.State, streamErrorIsRevocation: Bool, preflight: Bool) -> PermissionMonitor.State {
        guard streamErrorIsRevocation else { return state }
        return preflight ? .granted : .revoked
    }

    /// `SCStreamError` codes that can mean the grant is gone. Everything else (`attemptToStopStreamState`, `noDisplayList`
    /// during sleep, connection interrupted…) is a restart-with-backoff case.
    static func isRevocation(_ error: Error) -> Bool {
        guard let error = error as? SCStreamError else { return false }
        switch error.code {
        case .userDeclined, .userStopped, .systemStoppedStream, .missingEntitlements, .noCaptureSource: return true
        default: return false
        }
    }
}
