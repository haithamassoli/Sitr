// M4-T06: Low Power Mode → capture at 8 fps instead of 15 (PRD: `minimumFrameInterval` 1/15 s, 1/8 s in Low Power Mode).
// `NSProcessInfoPowerStateDidChange` is the only trigger; the Runtime pushes the new rate into every `CaptureSession`,
// which applies it with `SCStream.updateConfiguration` — the stream is never torn down for a frame-rate change.
import Foundation
import os

@MainActor final class LowPowerMonitor {
    /// PRD performance targets: 15 fps normally, 8 fps in Low Power Mode.
    static let standardFPS = 15
    static let lowPowerFPS = 8

    /// The rate every display should capture at right now.
    private(set) var fps = LowPowerMonitor.standardFPS
    /// The ceiling every display's rate is clamped to. `.max` — no clamp — unless Low Power Mode is actually reducing, so a
    /// Curtain display keeps its 30 fps on mains power (M3-T05) and drops to 8 with the rest on battery.
    var cap: Int { fps < Self.standardFPS ? fps : .max }
    /// Called on the main actor whenever `fps` changes.
    var onChange: ((Int) -> Void)?
    /// Test and selftest seam (`--selftest lowpower`): forces the power state, since Low Power Mode itself can only be
    /// flipped by hand in System Settings. nil = the real `ProcessInfo` value.
    var simulatedLowPower: Bool?

    /// Settings › General, "Reduce frame rate in Low Power Mode" (M4-T04). Read on every update, so switching it off
    /// while Low Power Mode is on restores 15 fps at once.
    private let reducesFrameRate: @MainActor () -> Bool
    private var observer: (any NSObjectProtocol)?
    private let log = Logger(subsystem: "com.goldentik.Sitr", category: "power")

    init(reducesFrameRate: @escaping @MainActor () -> Bool) {
        self.reducesFrameRate = reducesFrameRate
    }

    /// The rate for a power state and the General toggle. Pure.
    static func fps(lowPower: Bool, reduce: Bool) -> Int {
        lowPower && reduce ? lowPowerFPS : standardFPS
    }

    /// Starts observing the power state and applies whatever it is now. Idempotent.
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
        update()
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// Re-reads the power state and the preference. Logs one line per call (the notification fires only when the power
    /// state actually changes) and notifies the Runtime when the rate moved.
    func update() {
        let lowPower = simulatedLowPower ?? ProcessInfo.processInfo.isLowPowerModeEnabled
        let reduce = reducesFrameRate()
        let next = Self.fps(lowPower: lowPower, reduce: reduce)
        let changed = next != fps
        fps = next
        log.notice(
            "low_power=\(lowPower, privacy: .public) reduce=\(reduce, privacy: .public) fps=\(next) changed=\(changed)")
        if changed { onChange?(next) }
    }
}
