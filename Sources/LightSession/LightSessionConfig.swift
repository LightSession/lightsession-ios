import Foundation
import os.log

/// Everything the SDK needs, and nothing it can work out for itself.
public struct LightSessionConfig: Sendable {

    /// The project's key. Sent as `X-API-Key`.
    public var apiKey: String

    /// Base URL of the product API, no trailing slash. The screen map lives under it.
    public var apiURL: String

    /// Base URL of the **ingest** service, no trailing slash. Interaction batches go here.
    ///
    /// A second, genuinely different service — not a path under [apiURL]. On Android these are `apiUrl` and
    /// `ingestUrl` for the same reason, and pointing one at the other fails with a 404 on everything it
    /// carries. Optional here because an app that only wants the screen map does not need it; interactions
    /// are simply not recorded without it, and the log says so once.
    public var ingestURL: String?

    /// Record taps and swipes. On by default, and does nothing without [ingestURL].
    ///
    /// This is what a touch heatmap is drawn from. Turning it off stops the SDK from watching touches at
    /// all rather than merely discarding them.
    public var trackInteractions: Bool

    /// Record replay frames. On by default, and does nothing without [ingestURL].
    public var enableReplay: Bool

    /// Milliseconds between frames on a screen nobody is touching.
    public var captureIntervalMillis: Int64

    /// Milliseconds between frames while a finger is down.
    ///
    /// Faster on purpose. Touches arrive at 60–120 Hz and a static screen needs about one frame a second;
    /// one interval has to be wrong for one of them.
    public var interactionCaptureIntervalMillis: Int64

    /// How long a session survives with nothing happening.
    ///
    /// **Must match the ingest service's own idle timeout.** Rotate sooner and one visit becomes two rows;
    /// rotate later and events attach to a session the server has already sealed. 30 s is its default.
    public var sessionTimeoutMillis: Int64

    /// Whether the app names its own screens.
    ///
    /// **Required for SwiftUI, and not a preference.** A SwiftUI app's screens are values in a `body`,
    /// and the controllers `NavigationStack` creates under them are private types whose names change
    /// between releases — reading those is how an integration rots. So a SwiftUI app calls
    /// `.lightSessionScreen("Name")` and sets this, and a UIKit app leaves it alone and is observed.
    ///
    /// Setting it without ever reporting a screen is the one failure the SDK cannot recover from on its
    /// own, so it says so in the log rather than mapping nothing in silence.
    public var screensReportedByHost: Bool

    /// Whether a SwiftUI screen with no name of its own is named after its navigation title.
    ///
    /// On by default, because it is the difference between an app integrating in one line and an app
    /// integrating in one line per screen. A SwiftUI `.navigationTitle` becomes a real
    /// `navigationItem.title` on a hosting controller of its own, so an app that wrote titles for its
    /// users has already named its screens for the SDK — and named them better, in the words the user
    /// is reading rather than the ones a developer typed into a route table.
    ///
    /// Set it to nil to turn that off and go back to naming SwiftUI screens only through
    /// `.lightSessionScreen(_:)`. Worth doing when titles are translated and the map has to be one map
    /// across locales, or when they are built from data — see `SwiftUITitleNaming.limit`, which is the
    /// backstop for the second case rather than a cure.
    public var swiftUITitleNaming: SwiftUITitleNaming?


    /// What kind of screen a host-reported name describes.
    ///
    /// `setScreen(_:)` is one call with two callers — a SwiftUI app and a React Native app — and neither the
    /// call nor the SDK can tell which is on the other end. So the host says once, at startup, and every screen
    /// it names is recorded as that. The React Native package sets it; nothing else needs to.
    public var reportedScreenKind: ScreenIdentity.Kind

    /// Upgrade a screen's wireframe to a real screenshot once it settles.
    ///
    /// On by default because the wireframe is a shape and the screenshot is the screen. Both are kept
    /// server-side, in separate slots, so turning this off does not lose the wireframe.
    public var captureRealScreens: Bool

    /// Whether a wireframe's colours are read off the screen instead of coming from the palette.
    ///
    /// On by default, which matches the Android SDK — the two platforms feed one screen map, and a
    /// wireframe whose colours depend on which phone produced it is a graph nobody can read across.
    ///
    /// The trade is worth stating, because it is a real one. Sampled, a wireframe is a low-fidelity
    /// picture of the screen: a white text field comes back white. From the palette, it is a typed
    /// diagram: that field is orange because it is an input, and the colour is the only thing saying so.
    /// Turn this off to get the legend back. See `Recolour`.
    public var sampleWireframeColours: Bool

    /// Cover text before a capture leaves the device. **On by default**, and worth leaving on.
    public var maskText: Bool

    /// Cover images too. Off by default: it hides every icon and logo along with the photos.
    public var maskImages: Bool

    /// Capture uncaught Objective-C exceptions, and whatever the app hands to
    /// `LightSession.captureError`, attributed to the screen they happened on.
    ///
    /// On by default: the crashes most worth having are the ones from the first session after
    /// install, which is exactly when nobody has configured anything. What "uncaught" covers on
    /// this platform — and what it deliberately does not — is stated on `ErrorCapture`.
    public var captureErrors: Bool

    /// Capture the HTTP requests the app makes — method, host, collapsed path, status, duration and
    /// byte counts, attributed to the screen that was waiting.
    ///
    /// **Off by default, and the only flag here that is.** Everything else in this file describes
    /// what the SDK does to itself; this one puts our code in the path of the app's own traffic.
    /// The failure mode of being wrong about a wireframe is a bad picture. The failure mode of being
    /// wrong here is the customer's app, so nobody gets it without asking.
    ///
    /// Opt-in twice, in fact: turning this on arms the recording, but nothing is captured until the
    /// app also hands its `URLSession` a `LightSessionURLSessionDelegate` or calls
    /// `LightSession.recordRequest`. There is no global hook — `URLProtocol` would mean re-issuing
    /// every request the app makes through our code, and no measurement is worth that.
    ///
    /// Bodies and headers are never captured, on any setting. There is no field for them.
    public var captureNetwork: Bool

    /// What fraction of sessions have their network recorded. `1.0` — everything — by default.
    ///
    /// The unit is the **session**, not the request, and that is the whole design. A coin per
    /// request at a tenth turns a screen that fires six calls at once into one recorded call, and
    /// a reader then concludes the screen makes one request: a lie about the app's structure that
    /// no sample size repairs. It also punches holes in the session timeline, which is the one
    /// view this product has that a server-side tool does not. So a session is recorded whole or
    /// not at all, and sessions are drawn uniformly.
    ///
    /// **Failures are recorded regardless.** A rare failure at a tenth would otherwise be seen
    /// once in ten occurrences, and the rare one is the one somebody phones about. Those extras
    /// are sent marked as standing for no traffic, so they can be listed and watched without
    /// moving any rate or percentile — see `NetworkSampling`.
    ///
    /// Default `1.0` on purpose. Sampling makes every number an estimate, and a default that
    /// quietly estimated would have people quoting figures they did not know were approximate.
    /// Turning it down is a decision about cost, and it belongs to whoever is paying.
    public var networkSampleRate: Double

    public init(
        apiKey: String,
        apiURL: String,
        ingestURL: String? = nil,
        screensReportedByHost: Bool = false,
        swiftUITitleNaming: SwiftUITitleNaming? = SwiftUITitleNaming(),
        reportedScreenKind: ScreenIdentity.Kind = .swiftUI,
        captureRealScreens: Bool = true,
        sampleWireframeColours: Bool = true,
        maskText: Bool = true,
        maskImages: Bool = false,
        trackInteractions: Bool = true,
        enableReplay: Bool = true,
        captureIntervalMillis: Int64 = 1_000,
        interactionCaptureIntervalMillis: Int64 = 100,
        sessionTimeoutMillis: Int64 = SessionIdentity.defaultIdleTimeoutMillis,
        // Appended last, as this list demands: reordering defaulted parameters breaks positional
        // callers silently.
        captureErrors: Bool = true,
        captureNetwork: Bool = false,
        networkSampleRate: Double = 1.0
    ) {
        self.apiKey = apiKey
        self.apiURL = apiURL
        self.ingestURL = ingestURL
        self.screensReportedByHost = screensReportedByHost
        self.swiftUITitleNaming = swiftUITitleNaming
        self.reportedScreenKind = reportedScreenKind
        self.captureRealScreens = captureRealScreens
        self.sampleWireframeColours = sampleWireframeColours
        self.maskText = maskText
        self.maskImages = maskImages
        self.trackInteractions = trackInteractions
        self.enableReplay = enableReplay
        self.captureIntervalMillis = captureIntervalMillis
        self.interactionCaptureIntervalMillis = interactionCaptureIntervalMillis
        self.sessionTimeoutMillis = sessionTimeoutMillis
        self.captureErrors = captureErrors
        self.captureNetwork = captureNetwork
        self.networkSampleRate = networkSampleRate
    }
}

/// The SDK's log.
///
/// `print` behind one function rather than at thirty call sites, so it is one edit to route this into
/// `OSLog` or to silence it. Everything it prints is prefixed, because a library that writes
/// unattributed lines into an app's console is a library the app's developer comes to resent.
/// What the SDK says about itself, to both places a person might look.
///
/// `print` alone was the whole of this, and it goes to standard output — which exists only when the
/// app was launched from a terminal or from Xcode. An app the *user* opened, by tapping it, writes
/// into nothing. That is the normal case for anyone investigating a report from a real device or a
/// tester's simulator, and it made the SDK silent exactly when someone needed to hear it: a wireframe
/// came back wrong, the count that would have explained it was being logged, and there was no way to
/// read it without rebuilding and relaunching the app by hand.
///
/// So every line also goes to the unified log, where `log show --predicate 'subsystem == "…"'` finds
/// it after the fact, whoever started the app. `print` stays because a console attached to a running
/// sample is still the fastest way to watch a walk happen.
enum LightSessionLog {
    static var isVerbose = false

    private static let log = OSLog(subsystem: "com.lightsession.sdk", category: "LightSession")

    static func debug(_ message: @autoclosure () -> String) {
        guard isVerbose else { return }
        // Sent as `info`, not `debug`, and the reason is that `debug` does not survive. The unified log
        // discards that level unless someone has enabled it for the subsystem beforehand — which nobody
        // has done when they are reading a log to find out what went wrong. These lines are already
        // behind `verbose`, so a developer who turned it on has asked for them; making them
        // unreadable as well would be asking twice.
        emit(message(), type: .info, prefix: "")
    }

    static func info(_ message: @autoclosure () -> String) {
        emit(message(), type: .info, prefix: "")
    }

    static func error(_ message: @autoclosure () -> String) {
        emit(message(), type: .error, prefix: "error: ")
    }

    private static func emit(_ message: String, type: OSLogType, prefix: String) {
        print("[LightSession] \(prefix)\(message)")
        // `%{public}@` on purpose: the unified log redacts interpolated strings by default, and a line
        // that reads `<private>` is a line that helped nobody. Nothing here carries user content — the
        // SDK logs screen names and counts, and the text it captures never reaches a log.
        os_log("%{public}@", log: log, type: type, prefix + message)
    }
}
