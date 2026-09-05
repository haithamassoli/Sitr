import CoreGraphics
import Foundation

/// `Sitr --selftest`: prints what automated tests need to know about this process, then exits.
enum Selftest {
    static func run() {
        let env = ProcessInfo.processInfo.environment
        print("bundle_id=\(Bundle.main.bundleIdentifier ?? "nil")")
        print("sandboxed=\(env["APP_SANDBOX_CONTAINER_ID"] != nil)")
        print("screen_capture_preflight=\(CGPreflightScreenCaptureAccess())")
        exit(0)
    }
}
