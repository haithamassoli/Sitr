// M2-T05: one SCStream per display. `.complete` frames land in `frames` (latest-only); `.idle` frames are dropped in the
// callback. Stop/error → `health`, restart with exponential backoff (1, 2, 4, 8, 10, 10… s); revocation-class errors also
// reach the PermissionMonitor. The filter excludes our own process (docs/spike/overlay.md) unless M3 installs its own.
import AppKit
import ScreenCaptureKit
import Synchronization

@MainActor
final class CaptureSession {
    enum Health {
        case ok
        /// `nil` error = stopped on request.
        case stopped(Error?)

        var isOK: Bool { if case .ok = self { return true } else { return false } }
    }

    let displayID: CGDirectDisplayID
    /// Latest-only: a slow consumer sees the newest frame, never a backlog.
    let frames: AsyncStream<Frame>
    private(set) var health: Health = .stopped(nil)
    /// Restarts scheduled after an error since the session was created.
    private(set) var restarts = 0
    /// Capture rate, applied live (`updateConfiguration`). Curtain mode (M3) and Low Power (M4) change it at runtime.
    var fps: Int = CaptureSession.devOverride("SITR_FPS", default: 15) { didSet { if fps != oldValue { applyConfiguration() } } }
    /// Long side of the output buffer in pixels (PRD: detection input ≤ 1280), applied live.
    var captureLongSide: Int = CaptureSession.devOverride("SITR_CAPTURE_SIDE", default: 1280) {
        didSet { if captureLongSide != oldValue { applyConfiguration() } }
    }

    // ponytail: dev-only starting values from the environment (`SITR_FPS`, `SITR_CAPTURE_SIDE`) so scripts/measure-system.sh
    // (M1-T08) can compare 15 vs 30 fps and 1280 vs 1920 without a UI knob; Curtain (M3) / Low Power (M4) set the properties
    // at runtime and win. Upgrade path: delete this once the product has its own setting, nothing else reads the environment.
    private nonisolated static func devOverride(_ name: String, default value: Int) -> Int {
        ProcessInfo.processInfo.environment[name].flatMap(Int.init) ?? value
    }
    /// Counters from the callback: complete / idle / other frames, dirty rect total, last buffer size and attachments.
    var stats: CaptureStats { sink.stats.withLock { $0 } }

    private let permission: PermissionMonitor
    private let sink: FrameSink
    private var stream: SCStream?
    private var activeFilter: SCContentFilter?
    /// Installed by `updateFilter`; nil = the default (display minus our own process).
    private var customFilter: SCContentFilter?
    private var wantsRunning = false
    private var attempt = 0
    private var startedAt = 0.0
    private var restartTask: Task<Void, Never>?

    init(displayID: CGDirectDisplayID, permission: PermissionMonitor) {
        self.displayID = displayID
        self.permission = permission
        let (stream, continuation) = AsyncStream.makeStream(of: Frame.self, bufferingPolicy: .bufferingNewest(1))
        frames = stream
        sink = FrameSink(displayID: displayID, continuation: continuation)
    }

    /// Connects (asynchronously) and keeps the stream alive until `stop()`. Idempotent.
    func start() {
        wantsRunning = true
        restartTask?.cancel()
        sink.onStop.withLock {
            $0 = { [weak self] error in
                let session = self  // a `let`, not the weak box, so the main-actor task can capture it
                Task { @MainActor in session?.failed(error) }
            }
        }
        Task { await connect() }
    }

    func stop() {
        wantsRunning = false
        restartTask?.cancel()
        teardown()
        health = .stopped(nil)
    }

    /// Tears the stream down and reconnects with fresh display geometry (resolution change, display re-plugged).
    func restart() {
        guard wantsRunning else { return }
        teardown()
        attempt = 0
        Task { await connect() }
    }

    /// M3 filter builder: replaces the default own-process exclusion, live when the stream runs, otherwise at the next start.
    func updateFilter(_ filter: SCContentFilter) async throws {
        customFilter = filter
        activeFilter = filter
        try await stream?.updateContentFilter(filter)
    }

    /// `SCContentFilter` that captures `display` without any of our own windows (menu bar UI, panels, settings).
    static func ownProcessExcluded(display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
        let own = content.applications.filter { $0.processID == getpid() }
        return SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
    }

    private func connect() async {
        guard wantsRunning, stream == nil else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw CaptureError.displayGone }
            let filter = customFilter ?? Self.ownProcessExcluded(display: display, content: content)
            let s = SCStream(filter: filter, configuration: configuration(for: filter), delegate: sink)
            try s.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
            sink.displaySize.withLock { $0 = CGSize(width: display.width, height: display.height) }
            try await s.startCapture()
            guard wantsRunning, stream == nil else { try? await s.stopCapture(); return }  // stop() or restart() raced us
            stream = s
            activeFilter = filter
            startedAt = CACurrentMediaTime()
            health = .ok
        } catch {
            failed(error)
        }
    }

    /// BGRA, 1/`fps` s, queueDepth 3, no cursor; output scaled so the long side is `captureLongSide` px (never upscaled).
    private func configuration(for filter: SCContentFilter) -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        cfg.queueDepth = 3  // PRD says 3–5; 3 is what every spike number was measured with
        cfg.showsCursor = false
        let native = CGSize(width: filter.contentRect.width * Double(filter.pointPixelScale),
                            height: filter.contentRect.height * Double(filter.pointPixelScale))
        let k = min(1, Double(captureLongSide) / max(1, native.width, native.height))
        cfg.width = max(1, Int(native.width * k))
        cfg.height = max(1, Int(native.height * k))
        return cfg
    }

    private func applyConfiguration() {
        guard let stream, let activeFilter else { return }
        let cfg = configuration(for: activeFilter)
        Task { try? await stream.updateConfiguration(cfg) }
    }

    private func teardown() {
        guard let s = stream else { return }
        stream = nil
        Task { try? await s.stopCapture() }
    }

    /// Delegate error or failed start. Revocation-class errors inform the PermissionMonitor; while the grant is gone nothing
    /// is retried here (DisplayManager restarts sessions when it returns). Otherwise: backoff 1, 2, 4, 8, 10, 10… s.
    private func failed(_ error: Error) {
        let ranFor = stream == nil ? 0 : CACurrentMediaTime() - startedAt
        teardown()
        health = .stopped(error)
        if PermissionLogic.isRevocation(error) { permission.markRevoked() }
        guard wantsRunning, permission.state == .granted else { return }
        if ranFor > 30 { attempt = 0 }  // a stream that ran for a while earns a fresh backoff
        let delay = min(10.0, pow(2.0, Double(attempt)))
        attempt += 1
        restarts += 1
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.connect()
        }
    }
}

nonisolated enum CaptureError: Error {
    /// The display left `SCShareableContent` between the topology refresh and the connect.
    case displayGone
}

nonisolated struct CaptureStats: Sendable {
    var complete = 0, idle = 0, other = 0, dirtyRects = 0
    var size = CGSize.zero
    var contentRect = CGRect.zero
    var scaleFactor = 0.0, contentScale = 0.0
}

/// `SCStreamOutput` + `SCStreamDelegate` on the sample-handler queue. Sendable state only; the session stays on the main actor.
nonisolated final class FrameSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "sitr.capture")
    let stats = Mutex(CaptureStats())
    let displaySize = Mutex(CGSize.zero)
    let onStop = Mutex<(@Sendable (Error) -> Void)?>(nil)
    private let displayID: CGDirectDisplayID
    private let continuation: AsyncStream<Frame>.Continuation
    private let sequence = Mutex(0)

    init(displayID: CGDirectDisplayID, continuation: AsyncStream<Frame>.Continuation) {
        self.displayID = displayID
        self.continuation = continuation
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        let t = CACurrentMediaTime()
        guard type == .screen, let a = FrameAttachments(sb) else { return }
        let pb = sb.imageBuffer
        stats.withLock { s in
            switch a.status {
            case .complete: s.complete += 1
            case .idle: s.idle += 1
            default: s.other += 1
            }
            s.dirtyRects += a.dirtyRects.count
            if let pb { s.size = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb)) }
            s.contentRect = a.contentRect
            s.scaleFactor = a.scaleFactor
            s.contentScale = a.contentScale
        }
        guard a.status == .complete, let pb else { return }  // idle (and stopped/blank) frames never reach the pipeline
        let seq = sequence.withLock { $0 += 1; return $0 }
        continuation.yield(Frame(pixelBuffer: pb, displayID: displayID, sequence: seq, timestamp: t, dirtyRects: a.dirtyRects,
                                 contentRect: a.contentRect, scaleFactor: a.scaleFactor, contentScale: a.contentScale,
                                 displaySize: displaySize.withLock { $0 }))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop.withLock { $0 }?(error)
    }
}
