import Foundation

/// Where an app's screen names come from.
///
/// iOS has the same problem Android has, with different names for it. A UIKit app announces its
/// screens: every `UIViewController` that comes on screen calls `viewDidAppear`, and that is an
/// observation the SDK can make on its own. A SwiftUI app announces nothing usable — its screens are
/// values in a `body`, and the view controllers `NavigationStack` creates underneath are private
/// types whose names change between releases. Reading those is how an integration rots.
///
/// So there are two sources, they are mutually exclusive per app, and picking the wrong one is not a
/// degraded experience but a wrong map: observe a SwiftUI app and every screen is the one hosting
/// controller, forever.
public enum ScreenNameSource: Equatable, Sendable {
    /// Names come from `UIViewController` subclasses as they appear. Nothing is asked of the app.
    case viewControllers

    /// Names come from the app, through `.lightSessionScreen(_:)` or `LightSession.setScreen(_:)`.
    ///
    /// The only workable source for SwiftUI, and the same contract the React Native package uses on
    /// Android — for the same reason: the platform genuinely cannot know.
    case reportedByHost
}

/// What the tracker should do for an app, decided once.
public struct ScreenSourcePlan: Equatable, Sendable {
    public let source: ScreenNameSource

    /// Swizzle `viewDidAppear`. False for a host-reporting app: the hook would fire for the hosting
    /// controller on every SwiftUI transition and report a screen the app has already named better.
    public let observeViewControllers: Bool

    /// Warn, once, if the app looks like SwiftUI and never reports a screen.
    ///
    /// Silence is the failure mode worth catching. An app that adopts SwiftUI and forgets the
    /// modifier still produces sessions, still produces captures, and produces exactly one screen —
    /// which looks like a working SDK to everyone who is not looking at the graph.
    public let adviseIfSilent: Bool

    public init(source: ScreenNameSource, observeViewControllers: Bool, adviseIfSilent: Bool) {
        // The two sources cannot both be live. This is an invariant rather than a comment because
        // the Android version of this decision spent nineteen commits reporting a screen twice from
        // two mechanisms, and nothing in the code said that was impossible.
        precondition(
            !(observeViewControllers && source == .reportedByHost),
            "a host-reporting app must not also be observed: that reports every screen twice"
        )
        self.source = source
        self.observeViewControllers = observeViewControllers
        self.adviseIfSilent = adviseIfSilent
    }
}

/// What to do with a controller the SDK just saw appear.
public enum ObservedControllerAction: Equatable, Sendable {
    /// It is a screen. Report it.
    case reportNow
    /// It is a hosting controller and the app has said nothing yet — so it may be about to.
    ///
    /// Reporting immediately is what produced a measured bug: SwiftUI's `onAppear` and the hosting
    /// controller's `viewDidAppear` fire in an order neither side promises, and the run that caught it
    /// recorded a screen named `SwiftUIHome` followed by an edge to `SwiftUIHostViewController` — a
    /// navigation the user never made, to a node that is a container rather than a place.
    case waitForHost
    /// The app names its screens, and this is the box they are drawn in.
    case drop
}

/// Whether a controller that just appeared should be reported, and when.
///
/// The interesting case is the third one, and it is why this is not simply a boolean: an app that adopted
/// SwiftUI without opting in must still be mapped — a silent recorder is the failure that takes longest
/// to notice — but it must not be mapped *twice*, once by the name the app gave and once by the container
/// it happens to live in.
public func actionForObservedController(
    isHostingController: Bool,
    hostHasReportedAScreen: Bool
) -> ObservedControllerAction {
    guard isHostingController else { return .reportNow }
    return hostHasReportedAScreen ? .drop : .waitForHost
}

/// The whole decision, as a function of two facts.
///
/// - Parameters:
///   - hostsSwiftUI: the window's root is a hosting controller — the app's screens are SwiftUI views.
///   - screensReportedByHost: the app said it will name its own screens, or already has.
///
/// A SwiftUI app that has not opted in is still observed, deliberately: one screen named after the
/// hosting controller is a worse map than a named one but a better map than none, and the advisory
/// tells the developer how to fix it. Reporting nothing at all would leave a silent SDK, which is
/// the state that took the longest to notice on Android.
public func planScreenSource(
    hostsSwiftUI: Bool,
    screensReportedByHost: Bool
) -> ScreenSourcePlan {
    if screensReportedByHost {
        return ScreenSourcePlan(
            source: .reportedByHost,
            observeViewControllers: false,
            adviseIfSilent: false
        )
    }
    return ScreenSourcePlan(
        source: .viewControllers,
        observeViewControllers: true,
        adviseIfSilent: hostsSwiftUI
    )
}
