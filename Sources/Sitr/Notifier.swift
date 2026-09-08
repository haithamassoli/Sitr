// M2-T16: one user notification per health transition through UNUserNotificationCenter. Authorization is requested lazily on
// the first post. `dryRun` (selftests, unit tests) counts instead of posting, so no authorization dialog ever comes from a test.
// M4-T07 adds the spacing: the same transition is announced at most once every five minutes (`HealthNotificationGate`).
import CoreServices
import Foundation
import QuartzCore
import SitrCore
import UserNotifications
import os

@MainActor final class Notifier {
    /// Count posts instead of talking to UNUserNotificationCenter.
    static var dryRun = false
    /// Notifications posted (or counted, in dry run) since creation.
    private(set) var posted = 0
    private(set) var lastHealth: Health = .ok
    /// Clock for the M4-T07 spacing; injected by the unit tests so five minutes need not pass for real.
    var now: @MainActor () -> Double = { CACurrentMediaTime() }
    private var gate = HealthNotificationGate()
    private var center: UNUserNotificationCenter?
    private let log = Logger(subsystem: "com.goldentik.Sitr", category: "notifier")

    init() {}

    /// Health transition → at most one notification, and at most one per five minutes for the same transition (M4-T07:
    /// a detector flapping in and out of degraded must not fill Notification Centre). `.ok` announces a recovery only
    /// (never at launch). Texts come from the String Catalog (M4-T05).
    func healthChanged(to health: Health) {
        let previous = lastHealth
        guard gate.allows(from: previous, to: health, at: now()) else {
            // A suppressed transition still happened: the next one is judged from the state the app is really in.
            if health != previous {
                log.info("\(String(describing: health), privacy: .public) not announced (5 min spacing)")
            }
            lastHealth = health
            return
        }
        lastHealth = health
        switch health {
        case .needsPermission:
            post(title: String(localized: "Sitr protection is off", comment: "Notification title"),
                 body: String(localized: "Screen Recording permission is missing. Curtain apps stay covered; Blur apps are uncovered until capture resumes.",
                              comment: "Notification body"))
        case .degraded:
            post(title: String(localized: "Sitr protection is degraded", comment: "Notification title"),
                 body: String(localized: "Capture or detection needs attention. Open Sitr for status and recovery actions.", comment: "Notification body"))
        case .ok where previous != .ok:
            post(title: String(localized: "Sitr protection restored", comment: "Notification title"),
                 body: String(localized: "Screen capture is running again. Your protection rules apply.", comment: "Notification body"))
        case .ok:
            break
        }
    }

    private func post(title: String, body: String) {
        posted += 1
        guard !Self.dryRun else {
            log.notice("notification (dry run): \(title, privacy: .public)")
            return
        }
        guard let center = notificationCenter() else { return }
        let log = log
        // Completion handlers run on the center's own queue: @Sendable, and nothing non-Sendable captured (the center is
        // re-fetched, which is safe once it has been created successfully). The system shows the dialog once; later calls
        // return the stored decision at once.
        center.requestAuthorization(options: [.alert, .sound]) { @Sendable granted, error in
            guard granted else {
                log.notice("notifications not authorized (\(error?.localizedDescription ?? "denied", privacy: .public))")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { @Sendable error in
                if let error { log.error("notification failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }

    /// `UNUserNotificationCenter.current()` raises an ObjC exception Swift cannot catch when the process has no bundle proxy:
    /// a bare `.build/debug/Sitr`, or a bundle LaunchServices has never seen. Only proceed from inside a registered `.app`.
    private func notificationCenter() -> UNUserNotificationCenter? {
        if let center { return center }
        let bundle = Bundle.main
        guard bundle.bundleIdentifier != nil, bundle.bundleURL.pathExtension == "app" else {
            log.error("notifications unavailable: not an app bundle (\(bundle.bundleURL.path, privacy: .public))")
            return nil
        }
        // ponytail: a shell-launched build/Sitr.app is unknown to LaunchServices until registered; a no-op for Finder launches.
        let status = LSRegisterURL(bundle.bundleURL as CFURL, false)
        guard status == noErr else {
            log.error("notifications unavailable: LSRegisterURL status \(status)")
            return nil
        }
        let created = UNUserNotificationCenter.current()
        center = created
        return created
    }
}
