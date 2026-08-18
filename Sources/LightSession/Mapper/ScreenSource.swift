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

    /// Swizzle `viewDidAppear` to *name screens*. False for a host-reporting app: the hook would fire
    /// for the hosting controller on every SwiftUI transition and report a screen the app has already
    /// named better.
    public let observeViewControllers: Bool

    /// Watch appearing controllers for the modal layer — alerts, and React Native's modal host — even
    /// when they must not be used to name screens.
    ///
    /// A separate fact from `observeViewControllers`, and conflating them was a measured hole: with
    /// the host naming the screens, nothing was watching controllers at all, so `Alert.alert` and RN's
    /// `Modal` — real UIKit presentations both — never became `Screen › …` parts. Android never had
    /// this hole because its dialog detection reads windows, not the screen-name source.
    ///
    /// True in every plan. Who names the screens says nothing about whether a window can be covered.
    public let observeModalLayer: Bool

    /// Warn, once, if the app looks like SwiftUI and never reports a screen.
    ///
    /// Silence is the failure mode worth catching. An app that adopts SwiftUI and forgets the
    /// modifier still produces sessions, still produces captures, and produces exactly one screen —
    /// which looks like a working SDK to everyone who is not looking at the graph.
    public let adviseIfSilent: Bool

    public init(
        source: ScreenNameSource,
        observeViewControllers: Bool,
        observeModalLayer: Bool,
        adviseIfSilent: Bool
    ) {
        // The two sources cannot both be live. This is an invariant rather than a comment because
        // the Android version of this decision spent nineteen commits reporting a screen twice from
        // two mechanisms, and nothing in the code said that was impossible.
        precondition(
            !(observeViewControllers && source == .reportedByHost),
            "a host-reporting app must not also be observed: that reports every screen twice"
        )
        self.source = source
        self.observeViewControllers = observeViewControllers
        self.observeModalLayer = observeModalLayer
        self.adviseIfSilent = adviseIfSilent
    }
}

/// What a controller that just appeared actually is.
///
/// Asked before anything is named, because most of what `viewDidAppear` delivers is not a screen and
/// naming it is not a smaller version of the right answer — it is a different app's map. A run against a
/// real SwiftUI app produced fifteen screens, eleven of them UIKit's own: the keyboard, its prediction
/// bar, its dock, the input assistant, the cursor accessory, Safari's password autofill. Every one of
/// them appeared because the user tapped a text field.
public enum ObservedControllerRole: Equatable, Sendable {
    /// A place in the app, named after its class.
    case screen

    /// A navigation, tab, split or page controller, or an alert. Its child is the screen.
    case container

    /// A controller the app does not own: it came out of a system framework.
    ///
    /// The test is the bundle its class was loaded from, not its name. A name list would have to
    /// enumerate `UIPredictionViewController`, `UISystemInputAssistantViewController`,
    /// `_UICursorAccessoryViewController` and whatever iOS 27 renames them to; the bundle is a fact
    /// about where the code came from and needs no maintenance.
    case systemFurniture

    /// A hosting controller belonging to SwiftUI itself.
    ///
    /// Distinguished from `systemFurniture` because it means something specific and actionable: the
    /// app's screens are *inside* this, and the app has not named them.
    case unnamedSwiftUIHost

    /// Not on screen. `viewDidAppear` fires for a controller whose window has already gone.
    case offscreen
}

/// What a controller is, as a function of four facts about it.
///
/// Order is the content of this function:
///
///  * **Off screen first**, because nothing else about a controller matters if the user cannot see it.
///  * **Container next**, and before ownership, so an app's own `UINavigationController` subclass is
///    still furniture rather than a place.
///  * **Ownership before the SwiftUI test**, so an app that subclasses `UIHostingController` — which is
///    routine, and which the sample does — keeps the older handling that waits for the app to name the
///    screen and reports the container if it never does. Only SwiftUI's *own* hosting controllers, whose
///    names are mangled generics that change between releases, fall through to the case below.
public func roleOfObservedController(
    isOnScreen: Bool,
    isContainer: Bool,
    isOwnedByApp: Bool,
    isHostingController: Bool
) -> ObservedControllerRole {
    guard isOnScreen else { return .offscreen }
    if isContainer { return .container }
    if isOwnedByApp { return .screen }
    if isHostingController { return .unnamedSwiftUIHost }
    return .systemFurniture
}

/// Whether code at `bundlePath` is the app itself or something the app ships inside it.
///
/// Kept here, away from `Bundle`, so the one thing that can go wrong about it can be tested: the
/// separator has to be part of the prefix. Without it `MyApp.app.dSYM` sits inside `MyApp.app`, and a
/// framework's `.app`-prefixed neighbour would be treated as the app's own code.
public func isPathInsideApp(_ bundlePath: String, appPath: String) -> Bool {
    bundlePath == appPath || bundlePath.hasPrefix(appPath + "/")
}

/// What to call a SwiftUI screen the app has not named.
///
/// The title, when there is one. `NavigationStack` runs on a real `UINavigationController`, so
/// `.navigationTitle("Roteiro")` ends up as an ordinary `navigationItem.title` on a hosting controller
/// of its own — measured, not assumed: pushing a screen moved the title from `Inbox` to `Message` on
/// both the bar and the controller. That makes it a screen name the SDK can read from an app that
/// changed nothing, and a better one than the app would have typed: it is the word the user is
/// looking at.
///
/// **Only where the class name is worthless.** A UIKit screen keeps its class name, which is stable,
/// unlocalised and unique. A title is none of those, and swapping one for the other everywhere would
/// trade a good identity for a pretty one.
///
/// Two ways this goes wrong, and both are real in apps already written:
///
///  * **A localised title is a localised node.** Translate the app and the map grows a second copy of
///    every screen. Nothing here can fix that; `.lightSessionScreen` can.
///  * **A title built from data is unbounded.** `.navigationTitle(doctor.name)` is a node per doctor,
///    and a screen map with nine hundred nodes is not a screen map. That is what [limit] is for.
public struct SwiftUITitleNaming: Equatable, Sendable {
    /// How many distinct auto-named screens are allowed before the SDK stops trusting titles.
    ///
    /// Not a guess at how many screens an app has — a real one can have well over a hundred — but at
    /// the point where "these are screens" stops being the likelier explanation than "this title is
    /// built from a record". Past it, auto-naming turns itself off and says so; the screens already
    /// mapped keep their names, because deleting them would lose the ones that were right.
    public var limit: Int

    public init(limit: Int = 150) {
        self.limit = limit
    }
}

/// What to name a SwiftUI hosting controller, given its title and what has been named so far.
public enum SwiftUIHostName: Equatable, Sendable {
    /// Use this name, read from the screen itself.
    case title(String)
    /// No title to read. The placeholder, and the advice that goes with it.
    case placeholder
    /// There was a title, and there have been too many distinct ones to keep believing them.
    case tooManyTitles
}

/// Decides what an unnamed SwiftUI screen is called.
///
/// - Parameters:
///   - title: the controller's title, already trimmed, or nil.
///   - alreadyNamed: how many distinct titles have been accepted so far.
///   - naming: the limit, or nil to never read titles at all.
public func nameForSwiftUIHost(
    title: String?,
    alreadyNamed: Int,
    naming: SwiftUITitleNaming?
) -> SwiftUIHostName {
    guard let naming, let title, !title.isEmpty else { return .placeholder }
    // `>=` rather than `>`: the count is of titles already accepted, so at the limit the next new one
    // is the one too many.
    guard alreadyNamed < naming.limit else { return .tooManyTitles }
    return .title(title)
}

// MARK: - The screen a SwiftUI app cannot name by itself
//
// Read this before trying again. It is not a list of opinions; every line was measured on a device,
// and most of the dead ends took two attempts because the first instrument was wrong.
//
// ## The problem
//
// A root that swaps its content — `WindowGroup { RootView() }` with `switch session.route` inside —
// shows Splash, then Login, then the signed-in app. To UIKit those are not three screens. They are one
// hosting controller whose content changed. Measured, with object identity printed on both sides:
//
//     before:  UIHostingController<RootView>#5604
//              route: splash -> login
//     after:   UIHostingController<RootView>#5604
//     viewWillAppear: none · viewDidAppear: none · no callback of any kind
//
// So there is no moment to hang a name on, and no name to hang.
//
// ## What was tried, and where each one ends
//
//  1. **The class's generic parameter.** `UIHostingController<LoginView>` really does carry the type,
//     and it is read where it survives. SwiftUI erases it in both cases that matter: a `NavigationStack`
//     hands destinations over as `AnyView`, and a `WindowGroup` root arrives as
//     `ModifiedContent<AnyView, RootModifier>`.
//
//  2. **`rootView` through `Mirror`.** Absent: a `NavigationStackHostingController` has two stored
//     properties, `navigationColumnContext` and `pendingContent`, and no root view at all.
//
//  3. **`pendingContent`.** Nil once the content is installed.
//
//  4. **An exhaustive walk of the object graph** from the controller, its view and its ancestors.
//     Finds the *root* view type and nothing else — the pushed destination is in none of the 1,357
//     nodes reachable.
//
//  5. **Objective-C ivars instead of `Mirror`.** This one gets furthest and is worth knowing about: it
//     reaches SwiftUI's live navigation state at
//     `_delegate.navigationAuthority.host.navigationState.stackStateByKey`, with `pathLength` and a
//     position-to-controller map. The pushed values, though, come back empty — `_value` on the binding
//     is a cache, and the live path is behind `StoredLocation` → `GraphHost` → `AGAttribute(17944)`.
//
//  6. **`_UIHostingView._viewDebugData()`**, the entry point Xcode's view debugger uses. It is in the
//     public interface and it links and runs: it returns **zero nodes in 0.0 ms**. Capture is gated by
//     internal state with no exported setter.
//
//  7. **The Objective-C protocol behind that**, `XcodeViewDebugDataProvider`, with the selectors
//     `makeViewDebugData` and `_childDebugData`. The hosting view conforms and responds;
//     `makeViewDebugData` returns **two bytes**, an empty payload. Xcode enables capture from outside
//     the process, through the debug server.
//
//  8. **Named reflection paths into the hosting controller**, the technique other tools in this space
//     use — `host`, `_rootView`, `storage`, `view`, `content`. The root path works. On this OS the
//     NavigationStack paths resolve to nothing, because that class has no `host` and no `_rootView`.
//
//  9. **Evaluating `body` ourselves.** The closest miss. Swift's implicit existential opening lets an
//     SDK read `.body` at a concrete type it cannot name, and the walk correctly resolved
//     `Group` → `_ConditionalContent` → `SplashScreenDemo`. It is still wrong: the root view the
//     controller holds is the original value, with `@State._location == nil`, so the body replays the
//     seed. After switching to login it still answered Splash. A confidently wrong name is worse than
//     none.
//
// 10. **The view graph itself**, at `host._base`. It holds `viewGraph.rootViewType` — the root type,
//     again — and the same unbound seed copy. Zero `_ConditionalContent` values in 1,118 nodes.
//
// ## Why they all end in the same place
//
// What SwiftUI renders is decided by state kept in AttributeGraph, a C++ engine whose nodes are
// addressed by numeric ids rather than by fields any reflection can enumerate.
//
// **An earlier version of this paragraph went on to say that reading it would mean calling
// undocumented C internals "by id", and that was measured wrong.** AttributeGraph exports a bulk
// description — `AGGraphDescription`, with an `include-values` option, the facility Apple's own
// tooling reads — so one attribute handle is enough and no per-id navigation is needed. Resolved
// through `dlsym` (the SDK ships no `.tbd` to link against) and reached by a walk that reads
// Objective-C ivars as well as `Mirror`, it works: on iOS 26.2 the attribute
// `UnwrapConditional<ViewDescriptor, _ConditionalContent<…>, X>` names the live branch in `X`, and a
// run against a real app returned `ManagerRootView` and `NewDoctorView` correctly.
//
// It is still not the answer, for reasons that are now numbers rather than principle:
//
//  * **Cost.** Measured in a real app, the description reached **16.3 MB** and **5.5 seconds** on the
//    main thread, growing through the session as the graph accumulates. A three-view toy reported
//    62 KB and 7 ms, which is why a toy could not have settled this.
//  * **It names Apple's furniture.** The graph holds SwiftUI's own views beside the app's, and nothing
//    in the dump says which is which — the same run reported `NavigationStackRepresentableRoot` for
//    three different screens. A list of known framework names cannot fix that: `FloatingToolbar` and
//    `FloatingBarContainer` did not exist before iOS 26.
//  * **Private symbols in somebody else's app.** The App Store review risk lands on the customer.
//
// So the wall is real, but it is a *cost and ownership* wall, not an *unreachability* wall. Anyone
// coming back should know the information is there and what it costs to take.
//
// ## What to try if you come back to this
//
//  * A public API from Apple that names the rendered view. None exists as of iOS 26.
//  * A compiler plugin or macro the app opts into, which would see the concrete types at build time.
//    This trades one line of runtime annotation for a build-time dependency; worth measuring, not
//    obviously better.
//  * Detecting the *change* without naming it, with a structural fingerprint of the skeleton — the
//    shape standing in for the name, `Screen a3f9c1`. Explored and parked, and the reasoning is worth
//    keeping because the first version of this bullet dismissed it for the wrong reason: it compared
//    a fingerprint against an *annotated* screen, and an app that annotates does not need this. The
//    real baseline is what an unannotated app gets today — one node called `SwiftUI (unnamed)` holding
//    every screen — and against that, distinguishable nodes with their own wireframes win easily.
//
//    Built and tested as a pure function, it survived every trap this codebase has paid for before:
//    row counts, text lengths, sampled colours and device scale all left the id alone (repeated
//    sibling shapes collapse, and geometry is excluded — the Android dialog fingerprint measured that
//    a text node's width *is* its content), while order, nesting and widget mix still separated
//    screens.
//
//    What killed it is not any of that. **Shape is not identity over time.** Edit a layout — add a
//    banner — and the fingerprint changes, so `analyze` in the server's `graph.rs` finds the old id
//    missing from the current build and reports the screen as *dead*, while the new shape arrives as a
//    new screen. The map would announce a deletion every time somebody touched a layout, and any name
//    a person had attached would be lost. Bumping the app version does not help: it makes the split
//    legible without making it right.
//
//    If it is ever picked up again, the missing piece is not a cleverer hash — it is matching a new
//    shape against known ones by *similarity*, server side, with a person confirming the merge.
//
// Until one of those lands, the app tells us — and the app's own routing value is not a consolation
// prize. It is the better name: `.login` is what the team calls that screen, and it survives renaming
// the view that draws it.

/// The screen name for a value an app routes on.
///
/// The last thing tried, after everything else, and the only one that is not archaeology. Ten attempts
/// went looking for *which view is on screen* — through the hosting controller's generic parameter, its
/// `rootView`, an exhaustive walk of the object graph, the Objective-C ivars that reach SwiftUI's
/// navigation state, the debug data Xcode's view debugger reads, and finally evaluating `body` to follow
/// the live branch of a `switch`. Every one of them ends at the same wall: what SwiftUI renders is
/// decided by state that lives in AttributeGraph, a C++ engine addressed by numeric ids, and a root that
/// swaps `Splash` for `Login` emits no UIKit event at all.
///
/// The app knows, though — not in a view, in its own model. `switch session.route` is the answer written
/// by the people who wrote the app, and it is a better name than any view type: it is the concept, not
/// the rendering of it.
///
/// So the name is taken from the routing value:
///
///  * an **enum with a payload** gives its case name and drops the payload. `.doctorDetail(id)` is one
///    screen, not one per doctor — the same reason a title built from a record is refused elsewhere.
///  * anything else is described as written.
///
/// Nothing is capitalised or prettified. An app that routes on `.login` gets `login`, because a name the
/// SDK invents is a name nobody can search for in their own source.
public func screenName(forRoute value: Any) -> String? {
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .enum, let label = mirror.children.first?.label {
        return label.trimmed()
    }
    return String(describing: value).trimmed()
}

private extension String {
    func trimmed() -> String? {
        let clean = trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}

/// The one node an unnamed SwiftUI app is mapped to.
///
/// Not the hosting controller's class name, which is what produced the bug this exists to answer: a
/// SwiftUI screen is drawn by whichever of `UIHostingController`, `PresentationHostingController` or
/// `NavigationStackHostingController` happens to hold it, so one app walking through four screens
/// recorded seven navigations between three names that stood for the same thing.
///
/// Mapped to *something* rather than to nothing, deliberately. An SDK that records a session with no
/// screen on it looks installed and is not, and that is the failure that takes longest to notice. One
/// node that says what is wrong is worth more than silence, and the name is written to be read as a
/// problem by whoever opens the dashboard.
public let unnamedSwiftUIScreenName = "SwiftUI (unnamed)"

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
            observeModalLayer: true,
            adviseIfSilent: false
        )
    }
    return ScreenSourcePlan(
        source: .viewControllers,
        observeViewControllers: true,
        observeModalLayer: true,
        adviseIfSilent: hostsSwiftUI
    )
}

/// How a modal presents, as the wire and the reader care about it.
///
/// Mirrors the cases of `UIModalPresentationStyle` that change the answer, and nothing else. An enum
/// rather than the raw integer so a test states what it means, and so this file stays free of UIKit.
public enum ModalShape: Equatable, Sendable {
    /// `.pageSheet` or `.formSheet` — a card over the screen.
    case sheet
    /// Anything else presented: full screen, a cover, a custom transition.
    case other
}

/// What the app declared about a presentation, which is all there is to tell two of them apart.
///
/// Read rather than assumed: two different SwiftUI `.sheet`s on one screen arrive as the same class
/// with the same `modalPresentationStyle`, so neither identifies which sheet this is. The detents and
/// the rest of the sheet's configuration do, and — being declared rather than derived from content —
/// they are the same on the first frame as on the last, and the same on every launch.
public struct ModalPresentation: Equatable, Sendable {
    /// `UIModalPresentationStyle.rawValue`.
    public let styleRaw: Int
    /// `UISheetPresentationController.Detent.Identifier` raw values, in the order the app gave them.
    public let detentIdentifiers: [String]
    public let prefersGrabberVisible: Bool
    /// Points, or `nil` when the app left it to the system.
    public let cornerRadius: Double?

    public init(
        styleRaw: Int,
        detentIdentifiers: [String] = [],
        prefersGrabberVisible: Bool = false,
        cornerRadius: Double? = nil
    ) {
        self.styleRaw = styleRaw
        self.detentIdentifiers = detentIdentifiers
        self.prefersGrabberVisible = prefersGrabberVisible
        self.cornerRadius = cornerRadius
    }

    /// A card over the screen, or something else. `.pageSheet` is 1 and `.formSheet` is 2.
    public var shape: ModalShape {
        styleRaw == 1 || styleRaw == 2 ? .sheet : .other
    }
}

/// What to call a modal layer that appeared while the app names its own screens, or `nil` when this
/// controller is not one.
///
/// ## Why this is a pure function
///
/// Its first version read `UIViewController` directly and shipped a regression that no test could
/// have caught, because there was no test: a *pushed* screen was reported as a modal. Everything the
/// decision needs is four facts, so the decision takes four facts — the same reasoning
/// `actionForObservedController` above already states, which this should have followed the first
/// time.
///
/// ## What `isPresentedItself` has to mean
///
/// Not "has a presenting view controller". `presentingViewController` is non-nil for *anything
/// inside* a presented stack — UIKit answers with the presenter of the farthest presented ancestor —
/// so a screen pushed inside a presented navigation controller reports one, and a keyboard host
/// nested in someone else's presentation reports one too. The caller must ask the exact question
/// instead: does the presenter's `presentedViewController` point back at *this* controller. That
/// identity holds only for the controller that was actually presented.
///
/// ## Why the window has to match
///
/// `isPresentedItself` is necessary and not sufficient. The system presents things of its own into
/// windows the app does not own, and those presentations are real — the identity check passes
/// honestly. Measured in a real app: submitting a login form makes iOS offer to save the password,
/// and that offer arrives as `UIKeyboardHiddenViewController_Save` presenting
/// `_SFAppPasswordSavingViewController`, inside `UITextEffectsWindow`, one screen *after* the form.
/// It became a node called `Modal` hanging off an MFA screen that presents nothing at all.
///
/// The picture it carried gave the same answer from the other side: its content is a
/// `SFPasswordSavingRemoteViewController`, drawn by another process, so walking the app's window
/// found only the screen underneath — the phantom's wireframe was a copy of its own parent.
///
/// A modal layer is a layer *over this screen*. A controller in another window is over a different
/// window, and whether the person is looking at it is not something this SDK gets to claim.
///
/// ## Why "already named" ends it
///
/// One presentation is one layer, and two mechanisms notice the same sheet. A SwiftUI `.sheet`
/// carrying `.lightSessionSubScreen("Trocar empresa")` calls `setSubScreen` from the content's
/// `onAppear`, and a moment later its hosting controller's `viewDidAppear` arrives here. Measured in
/// a real app, both fired and composed into `dispatches › Trocar empresa › Sheet`: a depth the app
/// does not have, with the name the developer chose demoted to a parent of a word invented for the
/// same sheet.
///
/// Alerts do not come through here — they get a layer of their own — so an alert raised *over* a
/// named part still stacks, which is a second thing on screen and should say so.
///
/// ## The name
///
/// An `accessibilityIdentifier` if the app set one — the developer naming the thing, fixed by
/// definition. Otherwise a hash of the presentation's declared configuration, never anything the
/// modal *says*: a sheet titled with a record's name would mint a node per record, which is the trap
/// `alertName` exists to avoid. See `ScreenIdentity.modalName` for why a word for the shape was not
/// enough — two un-named sheets on one screen shared it, and one silently replaced the other.
public func modalLayerName(
    className: String,
    isPresentedItself: Bool,
    isInScreenWindow: Bool,
    isAlreadyNamedByApp: Bool,
    presentation: ModalPresentation,
    identifier: String?
) -> String? {
    // Both guards come before the bridge's own host, and for the same reason: they are about whether
    // there is a layer to name at all, not about what to call it.
    guard isInScreenWindow else { return nil }
    guard !isAlreadyNamedByApp else { return nil }
    // React Native's bridge presents its own host; it is a modal whatever the presentation says.
    if className.hasSuffix("ModalHostViewController") { return "Modal" }
    guard isPresentedItself else { return nil }
    // Named by what the app declared about the presentation, not by a word for its shape — see
    // `ScreenIdentity.modalName`. A single word carried nothing about *which* presentation it was, so
    // two un-named sheets on one screen became one node.
    return ScreenIdentity.modalName(
        identifier: identifier,
        isSheet: presentation.shape == .sheet,
        styleRaw: presentation.styleRaw,
        detentIdentifiers: presentation.detentIdentifiers,
        prefersGrabberVisible: presentation.prefersGrabberVisible,
        cornerRadius: presentation.cornerRadius
    )
}
