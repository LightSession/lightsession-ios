#if canImport(UIKit)
import UIKit

/// Turns "a screen appeared" into what the server stores.
///
/// The sequence, for every screen, is the same:
///
///  1. a name arrives — observed from a `UIViewController`, or reported by the app;
///  2. the flow from the previous screen is recorded, once per edge;
///  3. the screen is left alone until it stops changing (see `ScreenSettle`);
///  4. its geometry is uploaded as a wireframe;
///  5. if enabled, a real screenshot replaces the image, masked before it leaves the device.
///
/// Step 3 is the one that is easy to skip and expensive to skip. `viewDidAppear` is not when a screen is
/// finished: capturing there produced blank wireframes on Android, and the first attempt at fixing it
/// settled 4 ms earlier than the broken version and produced a byte-identical blank image.
final class ScreenTracker {

    private let config: LightSessionConfig
    private let sender: DataSender
    private let cache: CaptureCache
    private let settle = ScreenSettle()
    private let appVersionName: String
    private let appVersionCode: Int

    private var plan: ScreenSourcePlan
    /// The screen the app is on, as a bare name — no sub-screen.
    private var currentScreen: String?
    /// The part of the current screen that is a place of its own, if any.
    private var currentSubScreen: String?
    /// What was last reported to the server, including any sub-screen. What flows are drawn between.
    private var lastReported: String?
    private var hostHasReported = false
    /// Bumped on every host report, so a pending container report can tell whether the app spoke
    /// while it was waiting. A boolean would not: the app may have reported *before* the wait began.
    private var hostReportCount = 0
    private var adviceGiven = false
    /// The composite of the most recent capture, which is what a heatmap is anchored to.
    private var lastCaptureId: String?
    /// The screenshot waiting out its quiet period, if any.
    private var pendingScreenshot: DispatchWorkItem?
    /// Whether the screen was touched since the screenshot was scheduled.
    private var touchedSinceScheduled = false

    init(
        config: LightSessionConfig,
        sender: DataSender,
        cache: CaptureCache,
        appVersionName: String,
        appVersionCode: Int
    ) {
        self.config = config
        self.sender = sender
        self.cache = cache
        self.appVersionName = appVersionName
        self.appVersionCode = appVersionCode
        // Provisional: whether the app hosts SwiftUI cannot be known until there is a window, and there
        // is no window yet when the SDK starts from `application(_:didFinishLaunching…)`. Revisited on
        // the first screen.
        self.plan = planScreenSource(
            hostsSwiftUI: false,
            screensReportedByHost: config.screensReportedByHost
        )
    }

    /// The screen an interaction should be filed under, and the capture a heatmap draws over.
    ///
    /// The capture id is the composite, and it is what the server's heatmap route anchors to — so it is
    /// only known once a capture has been uploaded for this screen at this size and appearance. Before
    /// then the name is still true and the anchor is not, which is why they are returned together and the
    /// second one is optional.
    var currentScreenForInteraction: (name: String, captureId: String?)? {
        guard let lastReported else { return nil }
        return (lastReported, lastCaptureId)
    }

    /// Called with the window each capture used, so whoever watches touches follows the same window.
    var onWindow: ((UIWindow) -> Void)?

    /// Called when the screen changes, for the session's own timeline.
    ///
    /// Separate from the flow this class already sends. The flow goes to the product API and answers "which
    /// screens lead where" across every session; this answers "when did the screen change in *this* one",
    /// which is what puts a marker on a replay. A run of 168 frames arrived with `navigation_count = 0`
    /// before this existed.
    var onScreenChange: ((_ from: String?, _ to: String, _ kind: ScreenIdentity.Kind, _ transition: String) -> Void)?

    // MARK: - Starting

    func start() {
        if plan.observeViewControllers {
            ViewControllerObserver.onAppear = { [weak self] controller in
                self?.observed(controller)
            }
            ViewControllerObserver.install()
        }

        // A SwiftUI app that set the flag and then never calls the modifier maps nothing, and looks
        // installed while doing it. Five seconds is long enough for a first screen to render and short
        // enough that the developer is still looking at the console.
        if config.screensReportedByHost {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, !self.hostHasReported else { return }
                LightSessionLog.info(
                    """
                    no screen has been reported. `screensReportedByHost` is on, so the SDK is waiting \
                    for the app: add `.lightSessionScreen("Name")` to each screen, or call \
                    `LightSession.setScreen(_:)`. Until then no screen will be mapped.
                    """
                )
            }
        }
    }

    // MARK: - Screen sources

    private func observed(_ controller: UIViewController) {
        let typeName = NSStringFromClass(type(of: controller))
        let name = ScreenIdentity.screenName(fromTypeName: typeName)
        let isHosting = controller.isLightSessionHostingController

        switch actionForObservedController(
            isHostingController: isHosting,
            hostHasReportedAScreen: hostHasReported
        ) {
        case .reportNow:
            enter(screen: name, kind: .uiKit, transition: "appear")

        case .drop:
            LightSessionLog.debug("\(name) is the box the app's SwiftUI screens are drawn in; not a screen")

        case .waitForHost:
            // A grace, because `onAppear` and `viewDidAppear` fire in an order neither side promises. If
            // the app names this screen within it, this report never happens; if it does not, the
            // container is reported so the app is still mapped rather than silently skipped.
            //
            // The same shape the Android SDK uses for a Compose Activity, and for the same reason: the
            // screen's real name arrives just after the platform's callback does.
            let generation = hostReportCount
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.hostReportCount == generation else {
                    LightSessionLog.debug("\(name): the app named this screen; the container is not reported")
                    return
                }
                self.enter(screen: name, kind: .uiKit, transition: "appear")
                self.adviseSwiftUIIsUnnamed(name)
            }
        }
    }

    /// Told to an app whose SwiftUI screens have no names, at the moment that has been established.
    ///
    /// Given here rather than on sight of a hosting controller, which is where it was first written and
    /// where it lied: an app that names its screens correctly was told to add the call it was already
    /// using. Advice that is wrong about what the app is doing teaches people to skip the SDK's output.
    ///
    /// Said once, and specifically. "Something may be wrong" is a message people learn to ignore; this
    /// one names the type it found and the call that fixes it.
    private func adviseSwiftUIIsUnnamed(_ name: String) {
        guard !adviceGiven else { return }
        adviceGiven = true
        LightSessionLog.info(
            """
            \(name) hosts SwiftUI, and it is the only screen the platform can name — every SwiftUI screen \
            in it maps to this one node. Add `.lightSessionScreen("Name")` to each screen and set \
            `screensReportedByHost: true`.
            """
        )
    }

    func reported(screen name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            LightSessionLog.error("setScreen was called with an empty name; ignored")
            return
        }
        hostHasReported = true
        hostReportCount += 1
        enter(screen: trimmed, kind: config.reportedScreenKind, transition: "report")
    }

    func setSubScreen(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let screen = currentScreen else { return }
        currentSubScreen = trimmed
        report(screen: screen, subScreen: trimmed, kind: .uiKit, transition: "subscreen")
    }

    func clearSubScreen(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only the part that is actually showing may clear itself. Without this check a modal closing
        // late clears a different part that has since opened, and the graph records a screen the user
        // never returned to.
        guard currentSubScreen == trimmed, let screen = currentScreen else { return }
        currentSubScreen = nil
        report(screen: screen, subScreen: nil, kind: .uiKit, transition: "subscreen")
    }

    // MARK: - The sequence

    private func enter(screen name: String, kind: ScreenIdentity.Kind, transition: String) {
        // Entering a screen ends whatever part of the previous one was open. Keeping it would compose
        // the new screen with the old screen's modal.
        currentSubScreen = nil
        currentScreen = name
        report(screen: name, subScreen: nil, kind: kind, transition: transition)
    }

    private func report(
        screen: String,
        subScreen: String?,
        kind: ScreenIdentity.Kind,
        transition: String
    ) {
        let full = ScreenIdentity.compose(screen: screen, subScreen: subScreen)
        // The same screen reported twice is the normal case, not an error: a navigator re-emits state on
        // every re-render, and `viewDidAppear` fires again when a modal above it closes.
        guard full != lastReported else { return }

        let previous = lastReported
        lastReported = full
        // Leaving cancels the screenshot the previous screen was waiting for: it would record a state nobody
        // navigated to, and it would be filed under a screen the person is no longer on.
        cancelPendingScreenshot()

        // Announced for every change, including the first, where `previous` is nil: a replay needs to know
        // which screen it opens on, and the flow below is deliberately not sent for that case because a
        // graph has no edge from nowhere.
        onScreenChange?(previous, full, kind, transition)

        if let previous, previous != full, !cache.hasFlow(from: previous, to: full) {
            cache.recordFlow(from: previous, to: full)
            sender.send(
                flow: FlowReport(
                    from: previous,
                    to: full,
                    transition: transition,
                    appVersionName: appVersionName,
                    appVersionCode: appVersionCode
                )
            ) { result in
                if case .failure(let error) = result {
                    LightSessionLog.error("flow \(previous) -> \(full) failed: \(error.localizedDescription)")
                }
            }
        }

        capture(screen: full, kind: kind)
    }

    /// Waits for the screen to settle, then uploads it.
    private func capture(screen: String, kind: ScreenIdentity.Kind) {
        guard let window = UIApplication.shared.lightSessionKeyWindow else {
            // Not an error worth shouting about: this happens between a scene connecting and its window
            // becoming key, and the next screen will be captured normally.
            LightSessionLog.debug("no key window yet; \(screen) not captured")
            return
        }

        // The plan depends on what the window actually hosts, which is only knowable now.
        refinePlan(for: window)
        // Whoever watches touches follows this window, not one it found for itself. Two answers to "which
        // window" is how a heatmap ends up plotted against a capture of something else.
        onWindow?(window)

        settle.await(
            contentCount: {
                guard let root = window.rootViewController?.view else { return 0 }
                return SkeletonBuilder.contentCount(root.lightSessionSnapshot(in: window))
            },
            onSettled: { [weak self] settled in
                guard let self else { return }
                // Deliberately captured either way. A screen that never stops changing — a spinner, a
                // video — would otherwise never be captured at all, and a wireframe taken mid-animation
                // is worth more than no wireframe.
                if !settled {
                    LightSessionLog.debug("\(screen) never settled; capturing anyway")
                }
                // The name is checked again because settling takes frames, and the user can leave in
                // that time. Uploading now would file the new screen's content under the old name.
                guard self.lastReported == screen else {
                    LightSessionLog.debug("\(screen) left before it settled; capture dropped")
                    return
                }
                self.upload(screen: screen, kind: kind, window: window)
            }
        )
    }

    private func refinePlan(for window: UIWindow) {
        guard let root = window.rootViewController else { return }
        let hostsSwiftUI = root.isLightSessionHostingController
        plan = planScreenSource(
            hostsSwiftUI: hostsSwiftUI,
            screensReportedByHost: config.screensReportedByHost
        )
    }

    private func upload(screen: String, kind: ScreenIdentity.Kind, window: UIWindow) {
        guard let root = window.rootViewController?.view else { return }

        let snapshot = root.lightSessionSnapshot(in: window)
        let scale = Double(window.screen.scale)
        guard let frame = SkeletonBuilder.build(
            root: snapshot,
            scale: scale,
            background: window.lightSessionBackground
        ) else {
            LightSessionLog.debug("\(screen) has no drawable area; capture dropped")
            return
        }

        let theme: Theme = window.traitCollection.userInterfaceStyle == .dark ? .dark : .light
        let compositeId = ScreenIdentity.compositeId(
            name: screen,
            appVersionName: appVersionName,
            appVersionCode: appVersionCode,
            width: frame.width,
            height: frame.height,
            theme: theme
        )
        let state = cache.state(forCapture: compositeId)
        // Set before the upload rather than after it: this is what a heatmap anchors to, and the capture
        // exists server-side under this id whether or not *this* run was the one that sent it. Waiting for
        // a success would leave every interaction unanchored on a screen the cache had already covered.
        lastCaptureId = compositeId

        let report = ScreenReport(
            compositeId: compositeId,
            name: screen,
            kind: kind,
            skeleton: frame,
            imageBase64: nil,
            width: frame.width,
            height: frame.height,
            theme: theme,
            appVersionName: appVersionName,
            appVersionCode: appVersionCode
        )

        if state.hasWireframe {
            LightSessionLog.debug("\(screen) already has a wireframe")
        } else {
            sender.send(screen: report) { [weak self] result in
                switch result {
                case .success:
                    self?.cache.recordWireframe(forCapture: compositeId)
                    LightSessionLog.debug("wireframe sent: \(screen) (\(frame.width)x\(frame.height))")
                case .failure(let error):
                    // Not cached on failure, so the next visit tries again. Caching an upload that did
                    // not land is how a screen goes missing permanently.
                    LightSessionLog.error("wireframe \(screen) failed: \(error.localizedDescription)")
                }
            }
        }

        guard config.captureRealScreens, !state.hasScreenshot else { return }
        scheduleScreenshot(screen: screen, kind: kind, window: window)
    }

    /// Schedules the upgrade from wireframe to a real screenshot.
    ///
    /// Waits [ScreenshotTiming.quietPeriod] with nobody touching the screen. A touch or a navigation cancels it
    /// outright — see `ScreenshotTiming.Cancellation.touched` for why cancelling beats postponing.
    ///
    /// The window is captured weakly and re-read at fire time rather than the snapshot being reused from the
    /// wireframe: the whole reason for waiting is that the screen is still arriving, so a mask built five
    /// seconds ago would describe a screen that no longer exists — and the mask is what keeps text off the wire.
    private func scheduleScreenshot(screen: String, kind: ScreenIdentity.Kind, window: UIWindow) {
        cancelPendingScreenshot()
        touchedSinceScheduled = false

        let work = DispatchWorkItem { [weak self, weak window] in
            guard let self else { return }
            self.pendingScreenshot = nil

            if let reason = ScreenshotTiming.decide(
                scheduledFor: screen,
                currentScreen: self.lastReported,
                wasTouched: self.touchedSinceScheduled,
                isRecording: Recording.shared.isEnabled
            ) {
                LightSessionLog.debug("screenshot of \(screen) cancelled: \(reason)")
                return
            }
            guard let window else { return }
            self.captureScreenshot(screen: screen, kind: kind, window: window)
        }
        pendingScreenshot = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ScreenshotTiming.quietPeriod, execute: work)
    }

    /// Called on every touch. Cancels a pending screenshot rather than deferring it.
    func screenTouched() {
        guard pendingScreenshot != nil else { return }
        touchedSinceScheduled = true
        cancelPendingScreenshot()
        LightSessionLog.debug("screenshot cancelled: the screen was touched")
    }

    private func cancelPendingScreenshot() {
        pendingScreenshot?.cancel()
        pendingScreenshot = nil
    }

    /// Renders and uploads the screenshot, reading the screen as it is now.
    private func captureScreenshot(screen: String, kind: ScreenIdentity.Kind, window: UIWindow) {
        guard let root = window.rootViewController?.view else { return }
        let snapshot = root.lightSessionSnapshot(in: window)
        guard let frame = SkeletonBuilder.build(
            root: snapshot,
            scale: Double(window.screen.scale),
            background: window.lightSessionBackground
        ) else { return }

        let theme: Theme = window.traitCollection.userInterfaceStyle == .dark ? .dark : .light
        // Recomputed rather than carried from the wireframe: the device can have rotated during the wait, and a
        // screenshot at a different size is a different capture — filing it under the old id would put a
        // landscape picture in a portrait slot.
        let compositeId = ScreenIdentity.compositeId(
            name: screen,
            appVersionName: appVersionName,
            appVersionCode: appVersionCode,
            width: frame.width,
            height: frame.height,
            theme: theme
        )
        guard !cache.state(forCapture: compositeId).hasScreenshot else { return }

        let policy = ScreenshotRenderer.MaskPolicy(text: config.maskText, images: config.maskImages)
        guard let jpeg = ScreenshotRenderer.render(window: window, snapshot: snapshot, policy: policy) else {
            LightSessionLog.debug("\(screen) could not be rendered")
            return
        }

        let withImage = ScreenReport(
            compositeId: compositeId,
            name: screen,
            kind: kind,
            skeleton: nil,
            imageBase64: jpeg.base64EncodedString(),
            width: frame.width,
            height: frame.height,
            theme: theme,
            appVersionName: appVersionName,
            appVersionCode: appVersionCode
        )
        sender.replaceScreenshot(screen: withImage) { [weak self] result in
            switch result {
            case .success:
                self?.cache.recordScreenshot(forCapture: compositeId)
                LightSessionLog.debug("screenshot sent: \(screen) (\(jpeg.count) bytes)")
            case .failure(let error):
                LightSessionLog.error("screenshot \(screen) failed: \(error.localizedDescription)")
            }
        }
    }
}

extension UIApplication {
    /// The window the user is looking at.
    ///
    /// Walked through connected scenes rather than through the deprecated `windows` property, and the
    /// key window is preferred over the first one: an app showing a keyboard or an alert has more than
    /// one window, and the first is not necessarily the one on screen.
    var lightSessionKeyWindow: UIWindow? {
        let scenes = connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.filter { $0.activationState == .foregroundActive }
        let candidates = active.isEmpty ? scenes : active
        for scene in candidates {
            if let key = scene.keyWindow { return key }
            if let visible = scene.windows.first(where: { !$0.isHidden && $0.rootViewController != nil }) {
                return visible
            }
        }
        return nil
    }
}
#endif
