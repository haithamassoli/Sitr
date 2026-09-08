// M2-T05: one SCStream per display. `.complete` frames land in `frames` (latest-only); `.idle` frames are dropped in the
// callback. Stop/error → `health`, restart with exponential backoff (1, 2, 4, 8, 10, 10… s); revocation-class errors also
// reach the PermissionMonitor. The filter excludes our own process (docs/spike/overlay.md) unless M3 installs its own.
// M4-T10: the backoff itself is `SitrCore.RestartPolicy` (pure, injected clock) — one pending retry per session however
// many failures arrive at once, and no retry at all once the display has gone.
import AppKit
import ScreenCaptureKit
import SitrCore
import Synchronization
import os

@MainActor
final class CaptureSession {
    enum Health {
        case ok
        /// `nil` error = stopped on request.
        case stopped(Error?)

        var isOK: Bool { if case .ok = self { return true } else { return false } }
    }

    /// Sessions holding a live stream right now, across the process. Exactly one per managed display through sleep/wake,
    /// lock, fast user switching and hot-plug is the M4-T10 invariant; the unit tests and `--selftest robustness` read it.
    private(set) static var liveStreams = 0

    let displayID: CGDirectDisplayID
    /// Latest-only: a slow consumer sees the newest frame, never a backlog.
    let frames: AsyncStream<Frame>
    /// M4-T10 test seam: a session for a display that does not exist. It reports health and takes part in every
    /// reconciliation, but never talks to ScreenCaptureKit — so display topology, sleep/wake and the restart policy are
    /// unit-testable with no capture traffic and no contention for the screen.
    let simulated: Bool
    private(set) var health: Health = .stopped(nil)
    /// True between a successful connect and the next teardown; the only writer of `liveStreams`.
    private(set) var isConnected = false {
        didSet {
            guard isConnected != oldValue else { return }
            CaptureSession.liveStreams += isConnected ? 1 : -1
        }
    }
    /// Restarts scheduled after an error since the session was created.
    var restarts: Int { policy.retries }
    /// Seconds until the scheduled reconnect, nil when none is pending (M4-T10 logs and selftests).
    var pendingRetryDelay: Double? { policy.timeToRetry(at: CACurrentMediaTime()) }
    /// Whether the display still exists. `DisplayManager` points this at its own reconciled list, so a stream that fails
    /// while its display is being unplugged stops retrying instead of backing off against nothing (M4-T10).
    var displayIsPresent: @MainActor () -> Bool = { true }
    /// Whether capture is allowed at all; the `PermissionMonitor` by default. While the grant is gone nothing is retried
    /// here — `DisplayManager` starts the sessions again when it comes back. The M4-T10 tests point this at a fixed
    /// answer, since the machine's own TCC state is not their business.
    lazy var captureAllowed: @MainActor () -> Bool = { [permission] in permission.state == .granted }
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
    var acceptsFrames: Bool { sink.isAccepting }

    private let permission: PermissionMonitor
    private let sink: FrameSink
    private var stream: SCStream?
    private var activeFilter: SCContentFilter?
    /// Installed by `updateFilter`; nil = the default (display minus our own process).
    private var customFilter: SCContentFilter?
    var makeFilter: ((SCDisplay, SCShareableContent) throws -> SCContentFilter)?
    private var filterRevision = 0
    private var connectTask: Task<Void, Never>?
    private var filterTask: Task<Void, Error>?
    private var wantsRunning = false
    /// Which connection the stream delegate's callbacks belong to; bumped by every teardown (M4-T10).
    private var generation = 0
    private var policy = RestartPolicy(backoff: .captureStream)
    private var restartTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.goldentik.Sitr", category: "capture")

    init(displayID: CGDirectDisplayID, permission: PermissionMonitor, simulated: Bool = false) {
        self.displayID = displayID
        self.permission = permission
        self.simulated = simulated
        let (stream, continuation) = AsyncStream.makeStream(of: Frame.self, bufferingPolicy: .bufferingNewest(1))
        frames = stream
        sink = FrameSink(displayID: displayID, continuation: continuation)
    }

    /// Connects (asynchronously) and keeps the stream alive until `stop()`. Idempotent.
    func start() {
        wantsRunning = true
        restartTask?.cancel()
        beginConnect()
    }

    func stop() {
        wantsRunning = false
        restartTask?.cancel()
        restartTask = nil
        teardown()
        policy.reset()
        health = .stopped(nil)
    }

    /// Tears the stream down and reconnects with fresh display geometry (resolution change, display re-plugged).
    func restart() {
        guard wantsRunning else { return }
        restartTask?.cancel()
        restartTask = nil
        teardown()
        policy.reset()
        beginConnect()
    }

    /// A simulated session connects in this turn (the reconciliation tests assert counts without awaiting); a real one
    /// hands the ScreenCaptureKit round trip to a task.
    private func beginConnect() {
        guard !simulated else { return connectSimulated() }
        guard connectTask == nil, stream == nil else { return }
        connectTask = Task { await connect() }
    }

    private func connectSimulated() {
        guard wantsRunning, !isConnected else { return }
        isConnected = true
        policy.connected(at: CACurrentMediaTime())
        health = .ok
    }

    /// Close the delivery gate synchronously when rules change, including queued/in-flight frames.
    func invalidateFilter() {
        filterRevision &+= 1
        customFilter = nil
        sink.accept(nil)
    }

    func updateFilter(_ filter: SCContentFilter) async throws {
        customFilter = filter
        filterRevision &+= 1
        sink.accept(nil)
        guard let stream, isConnected else { return } // connect installs the newest filter before opening the gate
        if let filterTask { try await filterTask.value; return }
        let generation = self.generation
        let task = Task { try await self.installLatestFilter(on: stream, generation: generation) }
        filterTask = task
        defer { if generation == self.generation { filterTask = nil } }
        do { try await task.value }
        catch {
            if generation == self.generation { failed(error) }
            throw error
        }
    }

    private func installLatestFilter(on stream: SCStream, generation: Int) async throws {
        while let filter = customFilter {
            let revision = filterRevision
            try await stream.updateContentFilter(filter)
            guard self.generation == generation, self.stream === stream, !Task.isCancelled else { return }
            guard revision == filterRevision else { continue }
            activeFilter = filter
            sink.accept(stream)
            return
        }
    }

    /// `SCContentFilter` that captures `display` without any of our own windows (menu bar UI, panels, settings).
    static func ownProcessExcluded(display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
        let own = content.applications.filter { $0.processID == getpid() }
        return SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
    }

    private func connect() async {
        guard wantsRunning, stream == nil else { return }
        guard !simulated else { return connectSimulated() }
        let generation = self.generation
        defer { if generation == self.generation { connectTask = nil } }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard self.generation == generation, wantsRunning, !Task.isCancelled else { return }
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw CaptureError.displayGone }
            let filter = try makeFilter?(display, content) ?? customFilter ?? Self.ownProcessExcluded(display: display, content: content)
            let revision = filterRevision
            let s = SCStream(filter: filter, configuration: configuration(for: filter), delegate: sink)
            try s.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
            stream = s
            activeFilter = filter
            sink.displaySize.withLock { $0 = CGSize(width: display.width, height: display.height) }
            sink.onStop.withLock {
                $0 = { [weak self] stopped, error in
                    let stoppedID = ObjectIdentifier(stopped)
                    Task { @MainActor [weak self] in
                        guard let self, self.stream.map(ObjectIdentifier.init) == stoppedID else { return }
                        self.streamStopped(generation, error)
                    }
                }
            }
            sink.accept(s) // the initial filter already reflects the current rules; retain the first complete frame
            try await s.startCapture()
            guard self.generation == generation, wantsRunning, stream === s, !Task.isCancelled else {
                try? await s.stopCapture()
                return
            }
            if revision != filterRevision {
                try await installLatestFilter(on: s, generation: generation)
            }
            guard self.generation == generation, stream === s else { return }
            isConnected = true
            policy.connected(at: CACurrentMediaTime())
            health = .ok
        } catch {
            if self.generation == generation, !Task.isCancelled { failed(error) }
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
        generation &+= 1
        sink.accept(nil)
        connectTask?.cancel()
        connectTask = nil
        filterTask?.cancel()
        filterTask = nil
        isConnected = false
        guard let s = stream else { return }
        stream = nil
        Task { try? await s.stopCapture() }
    }

    /// `SCStreamDelegate.stream(_:didStopWithError:)`, from the stream of generation `generation`.
    private func streamStopped(_ generation: Int, _ error: Error) {
        guard generation == self.generation else { return }
        failed(error)
    }

    /// Delegate error or failed start. Revocation-class errors inform the PermissionMonitor; while the grant is gone, or
    /// once the display has left the topology, nothing is retried here (`DisplayManager` starts sessions again when the
    /// grant or the display returns). Otherwise `RestartPolicy` decides: backoff 1, 2, 4, 8, 10, 10… s, and a failure
    /// arriving while a retry is already pending joins it instead of stacking a second timer.
    private func failed(_ error: Error) {
        let now = CACurrentMediaTime()
        teardown()
        health = .stopped(error)
        if PermissionLogic.isRevocation(error) { permission.markRevoked() }
        let retryable = wantsRunning && captureAllowed() && displayIsPresent()
        switch policy.failed(at: now, retryable: retryable) {
        case .stop:
            restartTask?.cancel()
            restartTask = nil
            let line = "capture display=\(displayID) stopped, not retrying (wanted=\(wantsRunning) "
                + "allowed=\(captureAllowed()) display_present=\(displayIsPresent()))"
            log.notice("\(line, privacy: .public)")
        case .alreadyScheduled:
            break  // one timer per session: a burst of failures must not stack retries
        case .retry(let after):
            let line = "capture display=\(displayID) restart in \(fmtSeconds(after))s attempt=\(policy.attempt)"
            log.notice("\(line, privacy: .public)")
            restartTask?.cancel()
            restartTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(after))
                guard !Task.isCancelled else { return }
                await self?.retry()
            }
        }
    }

    private func retry() async {
        policy.retryFired()
        beginConnect()
    }

    /// M4-T10 test seam: the failure path without a stream to break, so the backoff and the display-gone rule are
    /// unit-testable. Only tests and `--selftest robustness` call it.
    func simulateStreamFailure(_ error: Error = CaptureError.displayGone) {
        failed(error)
    }
}

/// One decimal, for the restart log lines.
private func fmtSeconds(_ value: Double) -> String { String(format: "%.1f", value) }

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
    let onStop = Mutex<(@Sendable (SCStream, Error) -> Void)?>(nil)
    private let delivery = Mutex((stream: Optional<ObjectIdentifier>.none, revision: 0))

    var isAccepting: Bool { delivery.withLock { $0.stream != nil } }

    func accept(_ stream: SCStream?) {
        delivery.withLock { $0 = (stream.map(ObjectIdentifier.init), $0.revision &+ 1) }
    }
    private let displayID: CGDirectDisplayID
    private let continuation: AsyncStream<Frame>.Continuation
    private let sequence = Mutex(0)

    init(displayID: CGDirectDisplayID, continuation: AsyncStream<Frame>.Continuation) {
        self.displayID = displayID
        self.continuation = continuation
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        let t = CACurrentMediaTime()
        let token = delivery.withLock { $0 }
        guard token.stream == ObjectIdentifier(stream) else { return }
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
        continuation.yield(Frame(pixelBuffer: pb, displayID: displayID,
                                 isCurrent: { [weak self] in self?.delivery.withLock { $0 == token } ?? false }, sequence: seq, timestamp: t, dirtyRects: a.dirtyRects,
                                 contentRect: a.contentRect, scaleFactor: a.scaleFactor, contentScale: a.contentScale,
                                 displaySize: displaySize.withLock { $0 }))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop.withLock { $0 }?(stream, error)
    }
}
