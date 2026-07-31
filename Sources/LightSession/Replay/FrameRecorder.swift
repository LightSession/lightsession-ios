#if canImport(UIKit)
import UIKit

/// Captures the screen on a timer and uploads it in batches.
///
/// Two things make this cheap enough to leave on, and both are worth stating because both are easy to leave
/// out and impossible to notice missing:
///
///  * **Two intervals.** A frame a second while nothing is happening, ten a second while a finger is down.
///    One rate cannot serve both: a fast one spends its whole budget on a static screen, a slow one turns a
///    swipe into a jump cut.
///  * **Repeats are four bytes.** A frame identical to the one before it is sent as `"RPTD"` rather than as
///    the same JPEG again, so a minute of an untouched screen costs sixteen bytes rather than a megabyte.
///
/// Where this differs from Android, and it is a real difference rather than a port that drifted: Android
/// knows a screen has not changed *before* rendering, because it watches draw callbacks and can skip the
/// capture entirely. iOS has no equivalent public hook, so this renders and then compares. The upload and
/// the storage are saved; the render is not. Measured cost is one `drawHierarchy` per second on an idle
/// screen, which is the price of not missing a change that leaves the layout alone — a label whose text was
/// replaced, an image that finished loading.
final class FrameRecorder {

    private let spool: BatchSpool
    private let drain: SpoolDrain
    private let cadence: CaptureCadence
    private let session: SessionCoordinator
    private let appVersion: String
    private let maskPolicy: ScreenshotRenderer.MaskPolicy
    /// How much smaller a replay frame is than the screen.
    ///
    /// A replay is watched in a small player, and full resolution costs bytes nobody looks at. A third is
    /// enough to read a layout and follow a gesture; it is not enough to read body text, which is a side
    /// effect worth having on top of the masking.
    private let scale: CGFloat = 1.0 / 3.0

    private var batcher = FrameBatcher()
    private var burst = CaptureCadence.Burst()
    private var sequence = 0
    private var lastFrameHash: Int?
    private var timer: DispatchSourceTimer?
    private weak var window: UIWindow?
    /// The snapshot the mask is built from. Read on the main thread with the frame.
    private var isRunning = false

    init(
        spool: BatchSpool,
        drain: SpoolDrain,
        session: SessionCoordinator,
        appVersion: String,
        cadence: CaptureCadence,
        maskPolicy: ScreenshotRenderer.MaskPolicy
    ) {
        self.spool = spool
        self.drain = drain
        self.session = session
        self.appVersion = appVersion
        self.cadence = cadence
        self.maskPolicy = maskPolicy

        // A rotation must not split a batch: the frames buffered now belong to the session that is ending.
        session.onRotation { [weak self] in
            self?.flush(reason: .sessionRotated)
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        scheduleNext(afterMillis: 200)
    }

    func stop() {
        isRunning = false
        timer?.cancel()
        timer = nil
        flush(reason: .stopped)
    }

    func watch(window: UIWindow) {
        self.window = window
        // A new window is a new screen as far as the replay is concerned, so the next frame must be real
        // rather than deduplicated against the previous window's.
        lastFrameHash = nil
    }

    /// Called on every touch, to open the fast interval.
    func touched() {
        burst = cadence.touched(burst, nowMillis: SessionCoordinator.nowMillis())
    }

    func flushNow(reason: FrameBatcher.FlushReason) {
        flush(reason: reason)
    }

    // MARK: - The loop

    private func scheduleNext(afterMillis: Int64) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(Int(afterMillis)))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer?.cancel()
        self.timer = timer
    }

    private func tick() {
        guard isRunning else { return }
        let now = SessionCoordinator.nowMillis()
        capture(nowMillis: now)
        scheduleNext(afterMillis: cadence.delay(burst, nowMillis: now))
    }

    private func capture(nowMillis: Int64) {
        // Checked here rather than by stopping the timer, so `startRecording` resumes without having to rebuild
        // the loop — and so a screen that changed while recording was off is captured as a *real* frame when it
        // comes back, not deduplicated against the last one from before the gap.
        guard Recording.shared.isEnabled else {
            lastFrameHash = nil
            return
        }
        guard let window, window.bounds.width > 0 else { return }

        sequence += 1
        guard let jpeg = render(window: window) else {
            // A render that produced nothing is not a repeat — claiming it was would tell the player the
            // screen stayed as it was, which is a different lie from a missing frame.
            LightSessionLog.debug("frame \(sequence) could not be rendered")
            return
        }

        // Hashed rather than compared byte by byte: the comparison runs on every tick and a hash is one pass
        // over the bytes instead of two. A collision would drop one real frame, and the next tick recovers.
        let hash = jpeg.hashValue
        let isRepeat = hash == lastFrameHash
        lastFrameHash = hash

        if !isRepeat {
            // Only a *changed* screen counts as the person being present. A repeat must not, or an app left
            // open on a table would keep its session alive forever and the server's idle timeout would never
            // mean anything.
            session.markActive()
        }

        batcher.add(
            ReplayFrame(
                data: isRepeat ? ReplayFrame.repeatSignal : jpeg,
                isRepeat: isRepeat,
                sequence: sequence,
                timestampMillis: nowMillis
            )
        )

        if batcher.shouldFlush {
            flush(reason: batcher.bufferedBytes >= batcher.flushAtBytes ? .size : .count)
        }
    }

    /// The window, masked and shrunk, as a JPEG.
    private func render(window: UIWindow) -> Data? {
        // The same renderer the screen map uses, so a view the wireframe calls text is a view this covers.
        // One classification, three outputs; the alternative is lists that drift, and the one that drifts is
        // the one that stops covering something.
        let snapshot = window.rootViewController?.view?.lightSessionSnapshot(in: window)
            ?? window.lightSessionSnapshot(in: window)
        return ScreenshotRenderer.render(
            window: window,
            snapshot: snapshot,
            policy: maskPolicy,
            quality: 0.4,
            scale: window.screen.scale * scale
        )
    }

    private func flush(reason: FrameBatcher.FlushReason) {
        guard !batcher.pending.isEmpty else { return }
        let frames = batcher.drain()
        let batchNumber = batcher.batchNumber
        let shed = batcher.shedCount

        guard let metadata = frameBatchMetadata(
            frames: frames,
            batchId: UUID().uuidString,
            sessionId: session.sessionId,
            userId: session.userId,
            userType: session.userType,
            appVersion: appVersion,
            batchNumber: batchNumber,
            reason: reason
        ) else { return }

        let real = frames.filter { !$0.isRepeat }.count
        // Written to disk, not uploaded. Recording is finished when the file exists; the request is the drain's
        // problem, and a failed one is retried rather than lost.
        do {
            try spool.write(frames: frames, metadata: metadata)
            LightSessionLog.debug(
                "spooled batch \(batchNumber): \(frames.count) frame(s), \(real) real (\(reason.rawValue))"
            )
            drain.drain()
        } catch {
            LightSessionLog.error("could not spool \(frames.count) frame(s): \(error.localizedDescription)")
        }

        if shed > 0 {
            // Loud, because silent truncation reads as "the recording was always like that" rather than
            // "frames were discarded here".
            LightSessionLog.error("\(shed) frame(s) discarded this session; the uploads are not keeping up")
        }
    }

    deinit {
        timer?.cancel()
    }
}
#endif
