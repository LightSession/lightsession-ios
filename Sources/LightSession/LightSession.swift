#if canImport(UIKit)
import UIKit

/// The public API, and it is small on purpose.
///
/// A UIKit app needs one call:
///
/// ```swift
/// LightSession.start(.init(apiKey: "…", apiURL: "https://api.example.com"))
/// ```
///
/// Nothing else. `UIViewController.viewDidAppear` is hooked once, so every screen the app already has is
/// mapped without a line of code in it.
///
/// A SwiftUI app needs two, because the platform genuinely cannot name a SwiftUI screen — its screens are
/// values in a `body`, and the controllers `NavigationStack` builds under them are private types whose
/// names change between releases:
///
/// ```swift
/// LightSession.start(.init(apiKey: "…", apiURL: "…", screensReportedByHost: true))
/// // then, on each screen:
/// SomeView().lightSessionScreen("Home")
/// ```
public enum LightSession {

    private static var tracker: ScreenTracker?
    private static var interactions: InteractionRecorder?
    private static var replay: FrameRecorder?
    /// One session for the touches and the frames both. Two owners means two ids, and the product then
    /// shows a replay with no interactions beside a session with no video.
    private static var session: SessionCoordinator?
    private static var drain: SpoolDrain?

    /// Starts the mapper. Call once, as early as the app has a run loop.
    ///
    /// Calling it twice does nothing and says so: the second configuration would apply to some screens
    /// and not others, which is worse than being ignored.
    ///
    /// Safe to call from `application(_:didFinishLaunchingWithOptions:)` before any window exists. The
    /// first screen's capture finds the window then; there is nothing to capture before there is one.
    public static func start(_ config: LightSessionConfig, verbose: Bool = false) {
        // Not a background-thread concern that resolves itself: the hook has to be installed before the
        // first controller appears, and installing it from another thread races with that.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { start(config, verbose: verbose) }
            return
        }
        guard tracker == nil else {
            LightSessionLog.info("already started; this call is ignored")
            return
        }

        LightSessionLog.isVerbose = verbose

        let sender: DataSender
        do {
            sender = try HTTPDataSender(baseURL: config.apiURL, apiKey: config.apiKey)
        } catch {
            // The one failure worth refusing to start over: with no destination every capture would be
            // built, masked, encoded and thrown away, at the app's expense.
            LightSessionLog.error("not started: \(error.localizedDescription)")
            return
        }

        let info = Bundle.main.infoDictionary
        let versionName = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        // `CFBundleVersion` is a string that is conventionally a number, and conventionally is not
        // always. A build called "1.2.3" is not an integer, and the server's field is one.
        let versionCode = Int((info?["CFBundleVersion"] as? String) ?? "") ?? 0

        let cache = CaptureCache(
            storage: UserDefaultsCacheStorage(),
            appVersion: "\(versionName)-\(versionCode)"
        )

        let tracker = ScreenTracker(
            config: config,
            sender: sender,
            cache: cache,
            appVersionName: versionName,
            appVersionCode: versionCode
        )
        self.tracker = tracker

        startRecording(config, appVersion: versionName, tracker: tracker)
        tracker.start()

        LightSessionLog.info(
            "started for \(versionName) (\(versionCode)); screens "
                + (config.screensReportedByHost ? "reported by the app" : "observed")
        )
    }

    /// Starts the session-scoped recorders — touches and replay — if the app asked for them.
    ///
    /// Both or neither, as far as the session goes: they share one `SessionCoordinator`, because
    /// `session_id` is the only thing on the wire that says a tap and a frame belong to the same visit.
    ///
    /// Separate from the screen map, which needs no session and goes to a different service. An app that
    /// wants only the map is a supported configuration rather than a mistake.
    private static func startRecording(
        _ config: LightSessionConfig,
        appVersion: String,
        tracker: ScreenTracker
    ) {
        guard config.trackInteractions || config.enableReplay else { return }
        guard let ingestURL = config.ingestURL, !ingestURL.isEmpty else {
            // Said once, and not as an error: this is a legitimate setup. It is also the exact shape of a
            // mistake — both flags default to on — so silence would leave someone waiting for a replay that
            // was never going to arrive.
            LightSessionLog.info("no ingestURL, so no replay and no interactions; screens still are mapped")
            return
        }

        let session = SessionCoordinator(
            anonymousId: anonymousId(),
            idleTimeoutMillis: config.sessionTimeoutMillis
        )
        self.session = session

        let policy = ScreenshotRenderer.MaskPolicy(text: config.maskText, images: config.maskImages)

        // One spool and one drain for both streams. Two would upload in two orders, and breadcrumbs going
        // before frames is a property of the whole queue rather than of either recorder.
        let spool: BatchSpool
        let drain: SpoolDrain
        do {
            spool = try BatchSpool(root: try BatchSpool.defaultRoot())
            drain = SpoolDrain(
                spool: spool,
                breadcrumbs: try HTTPBreadcrumbSender(ingestURL: ingestURL, apiKey: config.apiKey),
                frames: try HTTPFrameSender(ingestURL: ingestURL, apiKey: config.apiKey)
            )
        } catch {
            LightSessionLog.error("no session recording: \(error.localizedDescription)")
            return
        }
        self.drain = drain

        if config.enableReplay {
            do {
                let recorder = FrameRecorder(
                    spool: spool,
                    drain: drain,
                    session: session,
                    appVersion: appVersion,
                    cadence: CaptureCadence(
                        idleMillis: config.captureIntervalMillis,
                        burstMillis: config.interactionCaptureIntervalMillis
                    ),
                    maskPolicy: policy
                )
                replay = recorder
                recorder.start()
            } catch {
                LightSessionLog.error("replay not recorded: \(error.localizedDescription)")
            }
        }

        if config.trackInteractions {
            do {
                let recorder = InteractionRecorder(
                    spool: spool,
                    drain: drain,
                    session: session,
                    appVersion: appVersion,
                    deviceInfo: deviceInfo(),
                    appInfo: appInfo(),
                    currentScreen: { [weak tracker] in tracker?.currentScreenForInteraction },
                    // A touch does two things, and both are wired here rather than each part watching
                    // touches for itself: it opens the replay's fast interval, and it cancels the screenshot
                    // the current screen was waiting out its quiet period for.
                    onTouch: {
                        replay?.touched()
                        tracker.screenTouched()
                    }
                )
                interactions = recorder
                recorder.start()
            } catch {
                LightSessionLog.error("interactions not recorded: \(error.localizedDescription)")
            }
        }

        // The tracker hands over the window it captured, rather than each recorder finding one for itself:
        // two answers to "which window" is how a heatmap ends up plotted over a capture of something else.
        tracker.onWindow = { window in
            interactions?.watch(window: window)
            replay?.watch(window: window)
        }
        // Screen changes go on the session's timeline as well as into the graph. Without this a replay has
        // every frame and no marker saying where one screen ended and the next began.
        tracker.onScreenChange = { from, to, kind, transition in
            interactions?.record(navigationFrom: from, to: to, kind: kind, transition: transition)
        }

        // Started last, so anything left on disk by a previous run goes out as soon as the app is up. That
        // is the whole point of the spool: a session recorded on the underground arrives when the train does.
        drain.start()

        observeAppLifecycle(session)
        LightSessionLog.info("recording session \(session.sessionId)")
    }

    /// Sends what is buffered when the app leaves, and rotates the session if it was away long enough.
    ///
    /// Backgrounding is the last chance to upload: without this the final frames and taps of a visit — the
    /// ones just before someone gave up — are exactly the ones that go missing.
    private static func observeAppLifecycle(_ session: SessionCoordinator) {
        let centre = NotificationCenter.default
        centre.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            session.markBackgrounded()
            uploadWhatIsLeft()
        }
        centre.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            // Time in the background is idle time — the server's reaper does not care why nothing arrived.
            session.markForegrounded()
        }
    }

    /// Flushes and uploads with the process kept alive until the uploads answer.
    ///
    /// The background task is the whole point, and it is what was missing. Writing the batch to disk is fast and
    /// always worked; the upload is a network request, and a request started as the app leaves is a request the
    /// system suspends a moment later, half-sent. The batch survived on disk and went out on the *next* launch —
    /// so a person who recorded a session and closed the app saw no replay until they opened the app again.
    /// Measured twice, on two recordings: every frame present in the spool, nothing on the server.
    ///
    /// Ordering matters here. The task is begun before the flush rather than after, because the flush itself
    /// encodes and writes a batch, and that work wants the same protection as the request that follows it.
    private static func uploadWhatIsLeft() {
        let application = UIApplication.shared
        var identifier = UIBackgroundTaskIdentifier.invalid
        // Captured by reference, so it sees the identifier assigned below rather than `.invalid`. Guarded because
        // whichever of the two paths arrives first — the drain finishing or the system running out of patience —
        // must be the only one to end the task.
        let finish = {
            guard identifier != .invalid else { return }
            application.endBackgroundTask(identifier)
            identifier = .invalid
        }
        identifier = application.beginBackgroundTask(withName: "LightSession upload", expirationHandler: finish)

        interactions?.flushNow()
        replay?.flushNow(reason: .background)

        guard identifier != .invalid else {
            // No time granted — the app is being suspended now, or already is. The spool keeps what the flush
            // wrote and the next launch drains it, which is the behaviour this method exists to improve on
            // rather than the failure it replaces.
            drain?.drain()
            return
        }
        drain?.drain(completion: finish)
    }

    /// A stable id for this install, so a returning person is recognisable across sessions.
    ///
    /// `UserDefaults` rather than the keychain or the vendor id: it is not an identity claim, it is a way to
    /// group one install's sessions, and it should disappear when the app does.
    private static func anonymousId() -> String {
        let key = "com.lightsession.anonymousId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    private static func deviceInfo() -> [String: Any] {
        let screen = UIScreen.main
        let device = UIDevice.current
        return [
            // Pixels, matching the captures and the interaction coordinates. Sending points here and pixels
            // there would put the two in different spaces with nothing to say which.
            "screenWidth": Int(screen.bounds.width * screen.scale),
            "screenHeight": Int(screen.bounds.height * screen.scale),
            "density": Double(screen.scale),
            "osVersion": device.systemVersion,
            "deviceModel": device.model,
            "manufacturer": "Apple",
            "platform": "ios",
        ]
    }

    private static func appInfo() -> [String: Any] {
        let info = Bundle.main.infoDictionary
        return [
            "version": info?["CFBundleShortVersionString"] as? String ?? "0.0.0",
            "versionCode": Int((info?["CFBundleVersion"] as? String) ?? "") ?? 0,
            "packageName": Bundle.main.bundleIdentifier ?? "unknown",
            "platform": "ios",
        ]
    }

    /// Attributes everything recorded on this install to one person.
    public static func identify(userId: String) {
        onMain { session?.identify(userId: userId) }
    }

    /// The counterpart to `identify(userId:)`. Call before signing out, not after.
    ///
    /// Buffered work is flushed under the old identity first, by the coordinator: relabelling it with the
    /// next person's id would be wrong in the direction that matters.
    public static func reset() {
        onMain { session?.reset() }
    }

    /// The session everything is being recorded under, if recording is on.
    public static var currentSessionId: String? { session?.sessionId }

    /// Reports the screen the app is on.
    ///
    /// Required for SwiftUI, available to anyone. Safe to call with the screen already showing: a repeat
    /// is dropped, which is what makes it safe to wire to something that re-emits on every render.
    public static func setScreen(_ name: String) {
        onMain { tracker?.reported(screen: name) }
    }

    /// Declares part of the current screen as a place of its own — a modal, a tab, a wizard step.
    ///
    /// Named `Parent › Part`, the same as Android, because both write into one graph.
    public static func setSubScreen(_ name: String) {
        onMain { tracker?.setSubScreen(name) }
    }

    /// Clears a part declared with `setSubScreen(_:)`.
    ///
    /// Takes the name rather than clearing whatever is current: a modal that closes late would otherwise
    /// clear a part that has since opened.
    public static func clearSubScreen(_ name: String) {
        onMain { tracker?.clearSubScreen(name) }
    }

    /// Resumes recording after [stopRecording].
    ///
    /// Safe to call when already recording, and safe to call before `start(_:)`: the switch is the SDK's, not a
    /// session's, so an app that turns recording on during launch does not have to order that against startup.
    public static func startRecording() {
        if Recording.shared.start() {
            LightSessionLog.info("recording resumed")
        }
    }

    /// Stops recording frames, touches and screen changes.
    ///
    /// What is already buffered still goes out — it describes something that happened while recording was on,
    /// and discarding it would lose the moments just before someone turned it off, which are usually why they
    /// did. What stops is the collecting.
    public static func stopRecording() {
        if Recording.shared.stop() {
            LightSessionLog.info("recording stopped")
            onMain {
                interactions?.flushNow()
                replay?.flushNow(reason: .stopped)
                drain?.drain()
            }
        }
    }

    /// Whether anything is being recorded.
    ///
    /// Both halves are required, and conflating them was the first version: `isStarted` alone answers "was the
    /// SDK configured", which stays true after `stopRecording()` and is a different question from the one asked.
    public static var isRecording: Bool { isStarted && Recording.shared.isEnabled }

    /// Whether `start(_:)` has run.
    public static var isStarted: Bool { tracker != nil }

    /// Everything here reads or writes the view hierarchy, so everything here is main-thread work.
    ///
    /// Hopped rather than asserted: `setScreen` is the call an app is most likely to make from wherever
    /// its navigation state changed, and that is not always the main thread. On Android the equivalent
    /// crossing threw from `LifecycleRegistry`, which surfaced as a red screen on launch.
    private static func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}
#endif
