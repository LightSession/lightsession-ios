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
///
/// ## What runs where
///
/// The main thread does the one thing that has to happen there — reading the view hierarchy and drawing it —
/// and nothing else. Encoding, deduplicating, batching and writing to disk all happen on [work].
///
/// That split is the point. The main thread owes the screen a frame; on a 120 Hz display the whole budget is
/// 8.3 ms, and the fast interval means the replay asks for its share ten times a second while a finger is
/// moving, which is precisely when the app is busiest and when a dropped frame is most visible. JPEG
/// encoding, hashing a few hundred kilobytes and writing a batch of files are all real work with no reason
/// to be in that budget.
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

    /// Everything after the pixels.
    ///
    /// Serial, and being serial is what makes it correct rather than merely fast: frames are handed over in
    /// capture order and a serial queue keeps them in it, which is what deduplication against the previous
    /// frame and a batch's own ordering both depend on. A concurrent queue would encode faster and produce a
    /// replay whose frames arrive shuffled.
    ///
    /// `utility` because a replay must never outbid the interface it is recording.
    private let work = DispatchQueue(label: "com.lightsession.replay.frames", qos: .utility)

    // MARK: - Owned by the main thread

    private var burst = CaptureCadence.Burst()
    private var sequence = 0
    private var timer: DispatchSourceTimer?
    private weak var window: UIWindow?
    private var isRunning = false

    // MARK: - Owned by `work`

    private var batcher = FrameBatcher()
    private var lastFrameHash: Int?
    /// Who the frames now buffered belong to, as read on the main thread when they were captured.
    ///
    /// Carried along rather than asked of the coordinator at flush time, for two reasons. The coordinator's
    /// state is read and written by the interaction path on the main thread and carries no lock, so reading
    /// it from here would be a race. And it is the more correct answer anyway: a batch belongs to the
    /// session that was current when its frames were taken, not to whatever is current when the write
    /// happens to occur.
    private var identity: BatchIdentity?

    /// The session a batch is attributed to.
    private struct BatchIdentity {
        let sessionId: String
        let userId: String
        let userType: UserType
    }

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
        //
        // Enqueued rather than run here. This callback arrives on the main thread before the identity
        // changes, and the frames already handed to `work` carry the identity they were captured with, so
        // the batch this writes still belongs to the session that is ending — while the main thread is not
        // held waiting for a disk write during a rotation.
        session.onRotation { [weak self] in
            guard let self else { return }
            self.work.async { self.flushOnWorkQueue(reason: .sessionRotated) }
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
        // Synchronous: see `flushNow`.
        work.sync { self.flushOnWorkQueue(reason: .stopped) }
    }

    func watch(window: UIWindow) {
        self.window = window
        // A new window is a new screen as far as the replay is concerned, so the next frame must be real
        // rather than deduplicated against the previous window's.
        work.async { self.lastFrameHash = nil }
    }

    /// Called on every touch, to open the fast interval.
    func touched() {
        burst = cadence.touched(burst, nowMillis: SessionCoordinator.nowMillis())
    }

    /// Writes what is buffered, and does not return until it is written.
    ///
    /// Synchronous on purpose, and the one place the caller waits for `work`. This is called as the app goes
    /// to the background and as recording stops, and "recorded" means the file exists — returning before the
    /// write would leave the batch racing the process being suspended. Anything already queued runs first,
    /// because the queue is serial, so no frame is left behind by flushing.
    func flushNow(reason: FrameBatcher.FlushReason) {
        work.sync { self.flushOnWorkQueue(reason: reason) }
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

    /// The main-thread half: read the hierarchy, draw it, hand the pixels over.
    private func capture(nowMillis: Int64) {
        // Checked here rather than by stopping the timer, so `startRecording` resumes without having to rebuild
        // the loop — and so a screen that changed while recording was off is captured as a *real* frame when it
        // comes back, not deduplicated against the last one from before the gap.
        guard Recording.shared.isEnabled else {
            work.async { self.lastFrameHash = nil }
            return
        }
        guard let window, window.bounds.width > 0 else { return }

        sequence += 1
        let sequence = self.sequence

        // The same renderer the screen map uses, so a view the wireframe calls text is a view this covers.
        // One classification, three outputs; the alternative is lists that drift, and the one that drifts is
        // the one that stops covering something.
        let snapshot = window.lightSessionContent
        guard let bitmap = ScreenshotRenderer.capture(
            window: window,
            snapshot: snapshot,
            policy: maskPolicy,
            scale: window.screen.scale * scale
        ) else {
            // A render that produced nothing is not a repeat — claiming it was would tell the player the
            // screen stayed as it was, which is a different lie from a missing frame.
            LightSessionLog.debug("frame \(sequence) could not be rendered")
            return
        }

        // Read on the thread that owns it, handed over by value.
        let identity = BatchIdentity(
            sessionId: session.sessionId,
            userId: session.userId,
            userType: session.userType
        )

        work.async {
            self.absorb(bitmap, sequence: sequence, timestampMillis: nowMillis, identity: identity)
        }
    }

    // MARK: - On `work`

    /// Encode, deduplicate, buffer — and flush if the buffer says so.
    private func absorb(
        _ bitmap: CGImage,
        sequence: Int,
        timestampMillis: Int64,
        identity: BatchIdentity
    ) {
        guard let jpeg = ScreenshotRenderer.encode(bitmap, quality: 0.4) else {
            LightSessionLog.debug("frame \(sequence) could not be encoded")
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
            //
            // Back to the main thread for the call itself: the coordinator is read and written by the
            // interaction path, which is main-thread only, and holds no lock.
            DispatchQueue.main.async { _ = self.session.markActive() }
        }

        self.identity = identity
        batcher.add(
            ReplayFrame(
                data: isRepeat ? ReplayFrame.repeatSignal : jpeg,
                isRepeat: isRepeat,
                sequence: sequence,
                timestampMillis: timestampMillis
            )
        )

        if batcher.shouldFlush {
            flushOnWorkQueue(reason: batcher.bufferedBytes >= batcher.flushAtBytes ? .size : .count)
        }
    }

    private func flushOnWorkQueue(reason: FrameBatcher.FlushReason) {
        guard !batcher.pending.isEmpty, let identity else { return }
        let frames = batcher.drain()
        let batchNumber = batcher.batchNumber
        let shed = batcher.shedCount

        guard let metadata = frameBatchMetadata(
            frames: frames,
            batchId: UUID().uuidString,
            sessionId: identity.sessionId,
            userId: identity.userId,
            userType: identity.userType,
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
