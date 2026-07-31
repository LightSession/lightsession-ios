#if canImport(UIKit)
import UIKit

/// Turns touches into uploaded interaction events.
///
/// Does *not* own the session. It did when interactions were the only thing that needed one, and that had to
/// change the moment replay arrived: two owners is two ids, and the product then shows a replay with no
/// interactions beside a session with no video. `SessionCoordinator` owns it now and both read from there.
///
/// Everything here runs on the main thread. Touches arrive there, the screen name is read from there, and
/// the only work that leaves is the upload.
final class InteractionRecorder {

    private let spool: BatchSpool
    private let drain: SpoolDrain
    private let appVersion: String
    private let deviceInfo: [String: Any]
    private let appInfo: [String: Any]
    /// Where the current screen comes from. A closure rather than a reference to the tracker, so the two
    /// have no cycle and this can be exercised with a stub.
    private let currentScreen: () -> (name: String, captureId: String?)?

    private let session: SessionCoordinator
    private let onTouch: () -> Void
    private var batcher: BreadcrumbBatcher
    private var sequence = 0
    private let observer = TouchObserver()
    private var flushTimer: Timer?

    init(
        spool: BatchSpool,
        drain: SpoolDrain,
        session: SessionCoordinator,
        appVersion: String,
        deviceInfo: [String: Any],
        appInfo: [String: Any],
        currentScreen: @escaping () -> (name: String, captureId: String?)?,
        onTouch: @escaping () -> Void
    ) {
        self.spool = spool
        self.drain = drain
        self.session = session
        self.appVersion = appVersion
        self.deviceInfo = deviceInfo
        self.appInfo = appInfo
        self.currentScreen = currentScreen
        self.onTouch = onTouch
        self.batcher = BreadcrumbBatcher()

        observer.onGesture = { [weak self] gesture in
            self?.record(gesture)
        }
        // The observer already knew how to be inert; this is what it asks. A gesture in progress when recording
        // stops is dropped rather than half-recorded — see `TouchObserver.moved`.
        observer.isEnabled = { Recording.shared.isEnabled }
        // A rotation must not split a batch: what is buffered belongs to the session that is ending.
        session.onRotation { [weak self] in
            self?.flush()
        }
    }

    var sessionId: String { session.sessionId }

    func start() {
        // A timer as well as the count trigger, because the last few events of a session would otherwise
        // sit in memory until the next touch — and the last few are the ones before the person left, which
        // is usually the interesting part.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.flushIfDue()
        }
        RunLoop.main.add(timer, forMode: .common)
        flushTimer = timer
    }

    /// Follows the window the screen tracker is capturing.
    func watch(window: UIWindow) {
        observer.attach(to: window)
    }

    /// Sends whatever is buffered. Called when the app goes to the background, where the alternative is
    /// losing it.
    func flushNow() {
        flush()
    }

    // MARK: - Recording

    private func record(_ gesture: Gesture) {
        let now = Self.nowMillis()
        // A touch is activity, and the coordinator rotates the session if it had gone stale — flushing both
        // recorders under the old id first, which is why that lives there rather than here.
        session.markActive()
        // The replay's fast interval is opened by a touch. Told rather than watched: two observers of the
        // same touches would be two chances to disagree about whether one happened.
        onTouch()

        let screen = currentScreen()
        sequence += 1
        let event = InteractionEvent(
            gesture: gesture,
            // A touch can land before any screen has been reported — during a launch animation, say. Named
            // rather than dropped: where someone tapped is still true, and "unknown" is what Android calls
            // it too.
            screen: screen?.name ?? "unknown",
            screenId: screen?.captureId,
            sequence: sequence,
            userId: session.userId,
            userType: session.userType,
            appVersion: appVersion
        )
        batcher.add(event, nowMillis: now)
        LightSessionLog.debug(
            "\(gesture.kind.rawValue) on \(event.screen) (\(gesture.points.count) point(s))"
        )
        flushIfDue()
    }

    /// Records a screen change on the session's timeline.
    ///
    /// Shares the sequence counter with touches, and that is the point: the counter is what orders the batch,
    /// so a tap that happened between two screens is reconstructible as having happened between them.
    func record(
        navigationFrom from: String?,
        to: String,
        kind: ScreenIdentity.Kind,
        transition: String
    ) {
        guard Recording.shared.isEnabled else { return }
        let now = Self.nowMillis()
        session.markActive()
        sequence += 1
        batcher.add(
            NavigationEvent(
                // The first screen of a session has nothing before it. Named rather than omitted, because
                // the field is not optional on the wire and Android sends the same word for it.
                from: from ?? "unknown",
                to: to,
                screenKind: kind,
                transition: transition,
                sequence: sequence,
                timestampMillis: now,
                userId: session.userId,
                userType: session.userType,
                appVersion: appVersion
            ),
            nowMillis: now
        )
        LightSessionLog.debug("timeline: \(from ?? "—") -> \(to)")
        flushIfDue()
    }

    private func flushIfDue() {
        guard batcher.shouldFlush(nowMillis: Self.nowMillis()) else { return }
        flush()
    }

    private func flush() {
        let now = Self.nowMillis()
        guard !batcher.pending.isEmpty else { return }
        let events = batcher.drain(nowMillis: now)
        let batchNumber = batcher.batchNumber

        guard let fields = breadcrumbBatchFields(
            events: events,
            sessionId: session.sessionId,
            userId: session.userId,
            userType: session.userType,
            appVersion: appVersion,
            batchNumber: batchNumber,
            timestampMillis: now,
            deviceInfo: deviceInfo,
            appInfo: appInfo
        ) else {
            LightSessionLog.error("could not encode \(events.count) interaction(s); dropped")
            return
        }

        // Counted by kind rather than called "interactions" wholesale. The generic wording cost real time:
        // a run was read as proof that a tap had been captured when the batch held one navigation and no
        // touch at all.
        let taps = events.filter { $0 is InteractionEvent }.count
        let moves = events.count - taps

        // Written to disk, not uploaded. Recording is finished when the file exists, and the request becomes
        // the drain's problem — so a failed one is retried instead of lost, which is what it used to be.
        do {
            try spool.write(breadcrumbs: fields)
            LightSessionLog.debug(
                "spooled batch \(batchNumber): \(taps) touch(es), \(moves) screen change(s)"
            )
            drain.drain()
        } catch {
            LightSessionLog.error(
                "could not spool \(taps) touch(es) and \(moves) screen change(s): "
                    + error.localizedDescription
            )
        }
    }

    /// Whether recording is on. Wired to whatever the SDK's own switch is; today it is always on.
    var isEnabled: () -> Bool {
        get { observer.isEnabled }
        set { observer.isEnabled = newValue }
    }

    static func nowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    deinit {
        flushTimer?.invalidate()
        observer.detach()
    }
}
#endif
