//
//  ScreenTracker.swift
//  LightSession
//
//  Author: thisames
//

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
    /// The parts of the current screen in view, as three fixed layers: what the app declared, then a
    /// modal host over it, then an alert over both. Layers rather than one slot — with one slot an
    /// alert would replace the declared panel it was raised over, and the map would lose where the
    /// person actually was. Tabs have no layer here on purpose: a real iOS tab is its own view
    /// controller and already a whole screen.
    private var declaredSubScreen: String?
    /// React Native's `Modal`, which presents a controller of its own while the screen's name stays
    /// with the JavaScript route underneath. Below the alert: an alert raised from inside the modal
    /// belongs over it.
    private var modalHostSubScreen: String?
    private var modalSubScreen: String?
    /// The alert the modal layer belongs to, so only its own dismissal clears it.
    private weak var modalAlert: UIViewController?
    /// Same contract for the modal host: identity, so a late teardown cannot clear a successor.
    private weak var modalHost: UIViewController?
    /// What was last reported to the server, including any sub-screen. What flows are drawn between.
    private var lastReported: String?
    private var hostHasReported = false
    /// Bumped on every host report, so a pending container report can tell whether the app spoke
    /// while it was waiting. A boolean would not: the app may have reported *before* the wait began.
    private var hostReportCount = 0
    /// The last name the app itself gave a screen.
    ///
    /// Kept so a screen the app named can be *restored*, not just recorded. A sheet over it names
    /// itself and takes over as the current screen; when the sheet closes the platform says nothing,
    /// and re-reading the controller underneath finds nothing to read either — the app names that
    /// screen, the controller does not. Without this the SDK stays on the sheet: measured, the flow
    /// went `Login -> Esqueci minha senha -> Ativar conta` with no way back to `Login`, and the real
    /// screenshot of `Ativar conta` was a picture of the login screen.
    private var lastHostReported: String?
    private var adviceGiven = false
    /// The distinct titles auto-naming has accepted, which is what the limit is counted against.
    private var titlesSeen: Set<String> = []
    private var titleLimitReported = false
    /// Bumped whenever any screen is reported, by any source.
    ///
    /// Distinct from `hostReportCount`, which counts only what the *app* said. A SwiftUI screen's real
    /// name can now also arrive from a controller deeper in the tree — a `NavigationStack` inside a
    /// hosting controller is three or four nested controllers and only the innermost has the title,
    /// with the outer ones appearing first. This is what lets an outer one's pending fallback notice
    /// that the screen has since been named properly and stay quiet.
    private var screenReportCount = 0
    /// The name each hosting controller was given the first time it was seen.
    ///
    /// Weak keys, so remembering a name never keeps a screen alive.
    ///
    /// This is what stops a title that is really data from becoming a node per record. A doctor detail
    /// screen written as `.navigationTitle(doctor.name ?? "Médico")` is titled `Médico` when it appears
    /// and titled `Dr. Carlos Mendes` a moment later, once the request comes back — and `viewDidAppear`
    /// fires again every time the user returns to it or closes something over it. Measured on a real
    /// app: `Médico` at 18:32:54, `Dr. Carlos Mendes` at 18:33:35, `Dr. Marcos Silva` at 18:36:53, three
    /// nodes for one screen and one more waiting for every doctor in the database.
    ///
    /// The first title is also the right one, and not by luck: it is what the screen says before it
    /// knows anything, which is the only part of it that is about the screen rather than about a record.
    private let assignedNames = NSMapTable<UIViewController, NSString>.weakToStrongObjects()
    /// What each screen called itself before the transition, and therefore before its data arrived.
    ///
    /// The title has to be caught here or not at all. `viewDidAppear` fires when the push animation
    /// finishes — about 350 ms — and a detail screen fetching from a backend on the same machine has
    /// its answer in 50 ms, so by then `.navigationTitle(doctor.name ?? "Médico")` already says
    /// `Dr. Carlos Mendes`. Measured twice: the first attempt at this only read late and recorded
    /// three doctors as three screens.
    private let titlesOnEntry = NSMapTable<UIViewController, NSString>.weakToStrongObjects()
    /// Screens already reported for having a title that moves, so it is said once rather than per visit.
    private var driftReported: Set<String> = []
    /// The composite of the most recent capture, which is what a heatmap is anchored to.
    private var lastCaptureId: String?
    /// The screenshot waiting out its quiet period, if any.
    private var pendingScreenshot: DispatchWorkItem?
    /// The screenshot the current screen is owed, whether or not a timer is still running for it.
    ///
    /// Distinct from `pendingScreenshot`, and the distinction is the login bug. A touch cancels the
    /// work item — `pendingScreenshot` goes nil — but the screen is still owed its picture; the debt is
    /// only settled by a capture or by navigating on to another screen. A form touched from arrival to
    /// departure is nil-pending and owed the whole time, and departure is when the debt gets paid.
    ///
    /// Carries the settle-time snapshot for one reason: the route-change flavour of the departure
    /// capture runs when the view tree already belongs to the *next* screen, so reading the hierarchy
    /// then would mask the old pixels with the new screen's rectangles. The tree as it stood when the
    /// wireframe was built is the one that describes the pixels being captured.
    private var screenshotOwed: (screen: String, kind: ScreenIdentity.Kind, snapshot: ViewSnapshot)?
    /// Whether the screen was touched since the screenshot was scheduled.
    private var touchedSinceScheduled = false
    /// Edges whose request is out and has not come back.
    ///
    /// Needed once the cache stopped being written before the send: without it, walking A → B → A → B
    /// faster than the network answers sends the same edge twice, because neither attempt has landed
    /// yet and the cache is still empty. Cheap, and it empties itself.
    private var flowsInFlight: Set<Edge> = []

    /// One edge of the graph, for the in-flight set.
    private struct Edge: Hashable {
        let from: String
        let to: String
    }

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
        // Installed for the modal layer even when controllers must not name screens, and each handler
        // checks the *current* plan rather than the one that existed at install time — `refinePlan`
        // runs after the first window exists, and a decision wired in here would not follow it.
        if plan.observeViewControllers || plan.observeModalLayer {
            ViewControllerObserver.onAppear = { [weak self] controller in
                guard let self else { return }
                if self.plan.observeViewControllers {
                    self.observed(controller)
                } else if self.plan.observeModalLayer {
                    self.observedModalLayerOnly(controller)
                }
            }
            ViewControllerObserver.onWillAppear = { [weak self] controller in
                guard let self, self.plan.observeViewControllers else { return }
                self.rememberTitleOnEntry(of: controller)
            }
            ViewControllerObserver.onWillDisappear = { [weak self] controller in
                guard let self, self.plan.observeViewControllers else { return }
                self.screenIsLeaving(controller)
            }
            ViewControllerObserver.onDisappear = { [weak self] controller in
                guard let self else { return }
                // Both guard on identity, so calling them for every disappearance is the cheap path.
                self.alertLeft(controller)
                self.modalHostLeft(controller)
                // The re-read exists to recover a *controller-named* screen from under a closed
                // sheet. With the host naming screens there is nothing to re-read — `observed` would
                // run the naming path this plan forbids.
                if self.plan.observeViewControllers {
                    self.somethingLeftTheScreen()
                }
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
        // An alert first, before the roles: by class it is a container and would be dropped in
        // silence — which is what used to happen, while this file's own documentation claimed the
        // tracker named alerts `Parent › Alert`. Now it does, as the modal layer.
        if let alert = controller as? UIAlertController {
            alertAppeared(alert)
            return
        }

        let typeName = NSStringFromClass(type(of: controller))
        let name = ScreenIdentity.screenName(fromTypeName: typeName)
        let isHosting = controller.isLightSessionHostingController

        switch roleOfObservedController(
            isOnScreen: controller.isLightSessionOnScreen,
            isContainer: controller.isLightSessionContainer,
            isOwnedByApp: controller.isLightSessionOwnedByApp,
            isHostingController: isHosting
        ) {
        case .offscreen, .container:
            return

        case .systemFurniture:
            // Debug rather than info: on a screen with a text field this fires six times, and an SDK
            // that shouts about doing the right thing is an SDK whose log nobody reads.
            LightSessionLog.debug("\(name) belongs to the system, not to the app; not a screen")
            return

        case .unnamedSwiftUIHost:
            // Every SwiftUI screen in the app lands here, under one of a handful of mangled generic
            // names that stand for the same container — so the class name is no help and the screen
            // has to say what it is some other way. It usually already does; see `nameSwiftUIHost`.
            nameSwiftUIHost(controller, container: name)
            return

        case .screen:
            break
        }

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
                self.adviseSwiftUIIsUnnamed(host: name, mappedTo: name)
            }
        }
    }

    /// Names a SwiftUI screen the app has not named, from the screen itself.
    ///
    /// `.navigationTitle("Roteiro")` becomes an ordinary `navigationItem.title` on a hosting
    /// controller of its own, because `NavigationStack` runs on a real `UINavigationController`. So an
    /// app that wrote titles for its users — which is nearly every app, and was nineteen of one real
    /// app's twenty-one screens — has already named its screens for the SDK without knowing it.
    ///
    /// The title is read twice when it has to be. At `viewDidAppear` SwiftUI has not always set it
    /// yet, and reporting the placeholder then and the title a moment later would draw an edge
    /// between two names for one screen — a navigation the user never made, which is the exact bug
    /// the host-report grace exists to avoid. So nothing is reported until there is an answer: now if
    /// the title is there, after the same short grace if it is not.
    /// An alert opening is a part of the current screen coming into view — the same event a dialog
    /// window opening is on Android, where it has always been reported. It rides the modal layer:
    /// `Screen › alert-…`, its own node with its own wireframe and heatmap, stacked over whatever
    /// part was already declared.
    ///
    /// The name never reads the alert's text — see `ScreenIdentity.alertName` for what it reads
    /// instead and why per-user content cannot be an identity. That rule is what keeps this out of
    /// the trap the platform's unreadable names set elsewhere: an alert is UIKit, its *structure* is
    /// readable, and structure is all that is asked for.
    private func alertAppeared(_ alert: UIAlertController) {
        guard let screen = currentScreen else {
            LightSessionLog.debug("an alert appeared before any screen; not a part of anything yet")
            return
        }
        modalAlert = alert
        modalSubScreen = ScreenIdentity.alertName(
            identifier: alert.view.accessibilityIdentifier,
            styleRaw: alert.preferredStyle.rawValue,
            actionStyleRaws: alert.actions.map { $0.style.rawValue },
            textFieldCount: alert.textFields?.count ?? 0
        )
        report(screen: screen, kind: .uiKit, transition: "subscreen")
    }

    /// The modal layer when the host names the screens — the only role controllers play in that plan.
    ///
    /// Two shapes and nothing else. An alert, named by its structure exactly as in full observation.
    /// And React Native's `Modal`, which presents a `…ModalHostViewController` of its own while the
    /// route name stays with the screen underneath — the same fact a `Dialog` window is on Android,
    /// where it has always been reported. Matched by class-name suffix because both architectures
    /// spell it that way (`RCTModalHostViewController`, `RCTFabricModalHostViewController`) and the
    /// name is the *platform's*, not the app's — there is nothing app-specific to leak.
    ///
    /// Everything else that appears here is left alone on purpose: in this plan the app's word is the
    /// map, and a route presented as a sheet is already a screen with a name of its own.
    private func observedModalLayerOnly(_ controller: UIViewController) {
        if let alert = controller as? UIAlertController {
            alertAppeared(alert)
            return
        }
        guard NSStringFromClass(type(of: controller)).hasSuffix("ModalHostViewController") else { return }
        guard let screen = currentScreen else {
            LightSessionLog.debug("a modal appeared before any screen; not a part of anything yet")
            return
        }
        modalHost = controller
        // `Modal`, not the class name: the class is an implementation detail of the bridge, and every
        // RN modal would otherwise be a node named after it.
        modalHostSubScreen = "Modal"
        report(screen: screen, kind: .uiKit, transition: "subscreen")
    }

    /// Identity, not class, for the same reason as `alertLeft` — and independent of it: an alert
    /// closing over a still-open modal must not take the modal's layer with it.
    private func modalHostLeft(_ controller: UIViewController) {
        guard controller === modalHost else { return }
        modalHost = nil
        modalHostSubScreen = nil
        guard let screen = currentScreen else { return }
        report(screen: screen, kind: .uiKit, transition: "subscreen")
    }

    /// The other half: only the tracked alert's own dismissal clears the layer.
    ///
    /// Identity, not class — a second alert replacing the first must not have its layer wiped by the
    /// first one's late teardown. The recompose happens here, synchronously, rather than waiting for
    /// the deferred re-read: the re-read still runs and lands on the same name, which `report` drops
    /// as a repeat.
    private func alertLeft(_ controller: UIViewController) {
        guard controller === modalAlert else { return }
        modalAlert = nil
        modalSubScreen = nil
        guard let screen = currentScreen else { return }
        report(screen: screen, kind: .uiKit, transition: "subscreen")
    }

    /// Re-reads what is on screen after something goes away.
    ///
    /// The signal a sheet does not otherwise give. A SwiftUI sheet is a page sheet, so the screen it
    /// covers is never removed from the hierarchy and gets no appearance callback when the sheet
    /// closes. Measured before this existed: opening a sheet over `Screen A` and closing it left the
    /// SDK on `The Sheet` for the rest of the session, and the screenshot taken once the quiet period
    /// elapsed showed `Screen A` and was stored as the sheet's.
    ///
    /// Deliberately not filtered by *which* controller left. A pop and a push also produce a
    /// disappearance, and re-reading is harmless there: the top of the hierarchy is what it already
    /// was, and `report` drops a name that has not changed. Cheap for the same reason — a screen going
    /// away is a rare event next to a frame.
    private func somethingLeftTheScreen() {
        // After the run loop turn: during `viewDidDisappear` the hierarchy is still mid-transition and
        // the controller on its way out can still be the top one.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let window = UIApplication.shared.lightSessionKeyWindow,
                  let top = window.lightSessionTopController
            else { return }

            // The app's own word beats a re-read, and this is the check that makes the difference
            // between restoring a screen and resurrecting one.
            //
            // Logging out replaces the whole tree. The route changes, the app reports `Login`, and the
            // tabs are torn down — which fires `viewDidDisappear`, and the controller being torn down
            // is briefly still the top one. Re-reading it reported the screen the user had just left.
            // Measured on a real app, twice in one session, in the same second:
            //
            //     22:00:27  Perfil -> Login      the logout
            //     22:00:27  Login  -> Perfil     this handler undoing it
            //
            // Everything after was then attributed to `Perfil`, including a `Perfil -> Esqueci minha
            // senha` that no one could have walked.
            //
            // When what is current is exactly what the app last named, nothing has been covered and
            // there is nothing to restore. A sheet is the opposite case — the sheet's own name is
            // current, the app's is not — and that is where the re-read is wanted.
            if let named = self.lastHostReported, self.lastReported == named { return }

            self.observed(top)
        }
    }

    /// Notes what a screen calls itself on the way in, before anything it is fetching comes back.
    ///
    /// Kept for hosting controllers only. A UIKit screen is named after its class and has no use for
    /// this, and remembering a title for every controller in the app would be a map of the keyboard.
    private func rememberTitleOnEntry(of controller: UIViewController) {
        guard controller.isLightSessionHostingController,
              titlesOnEntry.object(forKey: controller) == nil,
              let title = controller.lightSessionTitle
        else { return }
        titlesOnEntry.setObject(title as NSString, forKey: controller)
    }

    private func nameSwiftUIHost(_ controller: UIViewController, container: String) {
        // Decided once. Re-reading on a later appearance is what turned one screen into a node per
        // record; see `assignedNames`.
        if let already = assignedNames.object(forKey: controller) as String? {
            noteTitleDrift(on: controller, named: already)
            enter(screen: already, kind: .swiftUI, transition: "appear")
            return
        }

        // The entry title first: it is what the screen said before it knew anything, which is the
        // only part of a title that is about the screen rather than about a record.
        if let title = titlesOnEntry.object(forKey: controller) as String?
            ?? controller.lightSessionTitle {
            enterSwiftUI(title: title, container: container, on: controller)
            return
        }

        let reports = screenReportCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak controller] in
            guard let self else { return }
            // Something named this screen while we waited — the app, or a controller further in that
            // did have a title. Either beats the placeholder, and reporting it now would draw an edge
            // between two names for one screen: a navigation the user never made.
            guard self.screenReportCount == reports else {
                LightSessionLog.debug("\(container): the screen was named while waiting; nothing to add")
                return
            }
            // Read again rather than reused: SwiftUI does not always have the title set by the time
            // `viewDidAppear` fires, and this wait is what it is for.
            guard let controller else { return }
            self.enterSwiftUI(
                title: self.titlesOnEntry.object(forKey: controller) as String?
                    ?? controller.lightSessionTitle,
                container: container,
                on: controller
            )
        }
    }

    /// Says, once per screen, that its title is not a screen name.
    ///
    /// Worth saying rather than silently doing the right thing: the developer sees `Médico` in the map
    /// and may be looking for the doctor's name. This tells them where it went and how to choose
    /// something else.
    private func noteTitleDrift(on controller: UIViewController, named assigned: String) {
        guard let now = controller.lightSessionTitle, now != assigned else { return }
        guard driftReported.insert(assigned).inserted else { return }
        LightSessionLog.info(
            "the screen mapped as \"\(assigned)\" is now titled \"\(now)\". A title that changes is "
                + "data rather than a screen name, and following it would add a node per record — so "
                + "the first one is kept. Use `.lightSessionScreen(\"Name\")` on that screen to "
                + "choose the name yourself."
        )
    }

    private func enterSwiftUI(title: String?, container: String, on controller: UIViewController) {
        switch nameForSwiftUIHost(
            title: title,
            alreadyNamed: titlesSeen.count,
            naming: config.swiftUITitleNaming
        ) {
        case .title(let name):
            titlesSeen.insert(name)
            assignedNames.setObject(name as NSString, forKey: controller)
            enter(screen: name, kind: .swiftUI, transition: "appear")

        case .tooManyTitles:
            // Said once, and it is worth saying loudly: past this point the map is being built from
            // something that is not a screen name, and every session adds more of it.
            if !titleLimitReported {
                titleLimitReported = true
                LightSessionLog.info(
                    """
                    \(titlesSeen.count) screens have been named from their navigation titles, which is \
                    more than an app usually has — a title built from data, like \
                    `.navigationTitle(doctor.name)`, is one node per record rather than one per screen. \
                    Titles are no longer being read. Name those screens with \
                    `.lightSessionScreen("Name")` and the rest will keep working.
                    """
                )
            }
            enter(screen: unnamedSwiftUIScreenName, kind: .swiftUI, transition: "appear")

        case .placeholder where controller.isLightSessionPresentedModally:
            // A sheet with no title is not an unnamed screen, it is not a screen. Reporting the
            // placeholder here put a node between a screen and itself: measured on the sample,
            // opening a sheet recorded `Message -> SwiftUI (unnamed)` and closing it recorded the
            // way back, two navigations the user never made. The screen underneath stays current,
            // which is what the user would say they were looking at.
            //
            // A sheet that *does* have a title is left alone and becomes a screen of its own. It has
            // a real name, and naming it is better than dropping it — though `lightSessionSubScreen`
            // still describes it more truthfully, as a part of the screen that opened it.
            LightSessionLog.debug("an untitled sheet over \(lastReported ?? "?") is not a screen")

        case .placeholder where hostHasReported:
            // No title, and the app names its own screens: this is the box they are drawn in, not a
            // screen. Checked here and not before reading the title, which is the mistake that shipped
            // once — an app naming its routes lost every screen the title would have named, because a
            // titled `NavigationStackHostingController` was being dropped along with the untitled ones.
            //
            // Checked outside the grace as well, because the app may have reported *before* the wait
            // began: `.lightSessionScreen(for:)` on a routed root fires at launch, and the pending
            // fallback put a placeholder node between `loading` and `login`.
            //
            // The container is not reported — but whatever the app last named still is. Re-stating it
            // is what brings a screen back after a sheet over it closes, and it costs nothing when the
            // screen never changed: `report` drops a name that is already current.
            if let restored = lastHostReported {
                enter(screen: restored, kind: config.reportedScreenKind, transition: "report")
            } else {
                LightSessionLog.debug("\(container) is the box the app's SwiftUI screens are drawn in; not a screen")
            }

        case .placeholder:
            adviseSwiftUIIsUnnamed(host: container, mappedTo: unnamedSwiftUIScreenName)
            enter(screen: unnamedSwiftUIScreenName, kind: .swiftUI, transition: "appear")
        }
    }

    /// Told to an app whose SwiftUI screens have no names, at the moment that has been established.
    ///
    /// Given here rather than on sight of a hosting controller, which is where it was first written and
    /// where it lied: an app that names its screens correctly was told to add the call it was already
    /// using. Advice that is wrong about what the app is doing teaches people to skip the SDK's output.
    ///
    /// Said once, and specifically. "Something may be wrong" is a message people learn to ignore; this
    /// one names the type it found, the single node everything is collapsing onto, and the call that
    /// fixes it.
    ///
    /// - Parameters:
    ///   - host: the hosting controller that was seen.
    ///   - mappedTo: the one node the app's screens are all landing on, which is the host's own name
    ///     when the app subclassed it and a placeholder when the class belongs to SwiftUI.
    private func adviseSwiftUIIsUnnamed(host: String, mappedTo node: String) {
        guard !adviceGiven else { return }
        adviceGiven = true
        LightSessionLog.info(
            """
            \(host) hosts SwiftUI, and the platform cannot name what is inside it — every SwiftUI screen \
            in this app is being mapped to the single node "\(node)". Add `.lightSessionScreen("Name")` \
            to each screen and set `screensReportedByHost: true`.
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
        lastHostReported = trimmed
        enter(screen: trimmed, kind: config.reportedScreenKind, transition: "report")
    }

    func setSubScreen(_ name: String) {
        // The same sanitising a read label gets on Android, because the declared string is the one
        // most likely to arrive built out of the data on display. Rejected loudly rather than
        // truncated: a truncated data-name is still a screen per record, just harder to notice.
        guard let label = ScreenIdentity.subScreenLabel(name) else {
            LightSessionLog.error("setSubScreen(\"\(name)\") is not a label; ignored")
            return
        }
        guard let screen = currentScreen else { return }
        declaredSubScreen = label
        report(screen: screen, kind: .uiKit, transition: "subscreen")
    }

    func clearSubScreen(_ name: String) {
        // Only the part that is actually showing may clear itself. Without this check a modal closing
        // late clears a different part that has since opened, and the graph records a screen the user
        // never returned to.
        guard declaredSubScreen == ScreenIdentity.subScreenLabel(name), let screen = currentScreen else { return }
        declaredSubScreen = nil
        report(screen: screen, kind: .uiKit, transition: "subscreen")
    }

    // MARK: - The sequence

    private func enter(screen name: String, kind: ScreenIdentity.Kind, transition: String) {
        // Entering a screen ends whatever part of the previous one was open. Keeping it would compose
        // the new screen with the old screen's modal.
        declaredSubScreen = nil
        modalHostSubScreen = nil
        modalHost = nil
        modalSubScreen = nil
        modalAlert = nil
        currentScreen = name
        report(screen: name, kind: kind, transition: transition)
    }

    private func report(
        screen: String,
        kind: ScreenIdentity.Kind,
        transition: String
    ) {
        let full = ScreenIdentity.compose(
            screen: screen,
            parts: [declaredSubScreen, modalHostSubScreen, modalSubScreen].compactMap { $0 }
        )
        // The same screen reported twice is the normal case, not an error: a navigator re-emits state on
        // every re-render, and `viewDidAppear` fires again when a modal above it closes.
        guard full != lastReported else { return }

        let previous = lastReported

        // The departure capture's second flavour, for the navigation UIKit cannot see. When a SwiftUI
        // app swaps its route, the host stays and no controller disappears — the only signal that the
        // old screen is leaving is this very report of the new one. It arrives from `onAppear`, in the
        // turn whose commit will draw the new screen: the window's last committed frame is still the
        // old one, so it can still be photographed. Only for `"report"` transitions — a report arriving
        // by `"appear"` fires at `viewDidAppear`, when the committed frame already shows the new screen
        // (or the sheet now covering the debtor), and a picture taken then would be filed under a
        // screen it does not show. Those had their chance in `screenIsLeaving`.
        if transition == "report",
           let owed = screenshotOwed, owed.screen == previous,
           Recording.shared.isEnabled,
           let window = UIApplication.shared.lightSessionKeyWindow {
            screenshotOwed = nil
            LightSessionLog.debug("screenshot of \(owed.screen) taken at route change: the quiet period never elapsed")
            captureScreenshot(screen: owed.screen, kind: owed.kind, window: window, describedBy: owed.snapshot)
        }

        lastReported = full
        screenReportCount += 1
        // Leaving cancels the screenshot the previous screen was waiting for: it would record a state nobody
        // navigated to, and it would be filed under a screen the person is no longer on. The debt goes
        // with it — by the time the next screen is reported, the departing one has had its last chance,
        // in `screenIsLeaving`.
        cancelPendingScreenshot()
        screenshotOwed = nil

        // Announced for every change, including the first, where `previous` is nil: a replay needs to know
        // which screen it opens on, and the flow below is deliberately not sent for that case because a
        // graph has no edge from nowhere.
        onScreenChange?(previous, full, kind, transition)

        if let previous, previous != full,
           !cache.hasFlow(from: previous, to: full),
           flowsInFlight.insert(Edge(from: previous, to: full)).inserted {
            sender.send(
                flow: FlowReport(
                    from: previous,
                    to: full,
                    transition: transition,
                    appVersionName: appVersionName,
                    appVersionCode: appVersionCode
                )
            ) { [weak self] result in
                guard let self else { return }
                self.flowsInFlight.remove(Edge(from: previous, to: full))
                switch result {
                case .success:
                    // Recorded only once it has landed, which is the same rule the wireframe follows
                    // and for the same reason its comment gives: caching an upload that did not land
                    // is how something goes missing permanently. This was the other way round, and an
                    // edge lost to a failed request was lost for the life of the install — the cache
                    // said it had been sent and nothing ever asked again.
                    self.cache.recordFlow(from: previous, to: full)
                case .failure(let error):
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
            signature: {
                // The window, so a modal's content counts towards "has this settled" too. A sheet
                // sliding in over an empty screen is content arriving — and a sheet still sliding is
                // geometry still moving.
                SkeletonBuilder.contentSignature(window.lightSessionContent)
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
        // From the window: a screen that *is* a modal lives outside the root view. See
        // `UIWindow.lightSessionContent`.
        let snapshot = window.lightSessionContent
        let scale = Double(window.screen.scale)
        guard let built = SkeletonBuilder.build(
            root: snapshot,
            scale: scale,
            background: window.lightSessionBackground
        ) else {
            LightSessionLog.debug("\(screen) has no drawable area; capture dropped")
            return
        }

        // Read the real colours off the screen, if asked to. Here rather than anywhere later because this
        // is the settle callback: the layout has stopped moving, so the geometry and the pixels describe
        // the same moment. It degrades to the palette on its own, so there is no failure to handle.
        let frame = config.sampleWireframeColours
            ? ScreenshotRenderer.recolour(
                built,
                window: window,
                snapshot: snapshot,
                policy: ScreenshotRenderer.MaskPolicy(text: config.maskText, images: config.maskImages)
            )
            : built

        let theme: Theme = window.traitCollection.userInterfaceStyle == .dark ? .dark : .light
        let compositeId = ScreenIdentity.compositeId(
            name: screen,
            appVersionName: appVersionName,
            appVersionCode: appVersionCode,
            width: frame.width,
            height: frame.height,
            theme: theme
        )
        // Logged where the wireframe is *built*, not where it is sent. A screen that comes out wrong
        // comes out wrong here, and on a run where the upload is failing this line is the only one that
        // says what was found: four fields and a button reporting two nodes points straight at the
        // reading, while "wireframe sent" says nothing at all.
        LightSessionLog.debug(
            "wireframe built: \(screen) \(frame.width)x\(frame.height) "
                + "\(frame.nodes.count) node(s) \(frame.nodeSummary)"
        )

        // Then every node, in order. Verbose-only, and worth the noise: a wireframe that comes out wrong
        // is almost always a *painting* problem rather than a reading one, and the order is the only
        // thing that shows it. The bug that earned this line built twenty-five nodes for a form and
        // rendered three colours, because the sheet's own background was emitted second-to-last and the
        // renderer paints in the order it receives — every field under a rectangle the size of the
        // screen. The summary above said "25 node(s)" and looked healthy. This said which one.
        for (index, node) in frame.nodes.enumerated() {
            LightSessionLog.debug(
                "  node[\(index)] \(node.kind.rawValue) \(node.left),\(node.top) "
                    + "\(node.right - node.left)x\(node.bottom - node.top) "
                    + "color=\(node.color ?? "-") stroke=\(node.stroke)"
            )
        }

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
                    LightSessionLog.debug("wireframe sent: \(screen)")
                case .failure(let error):
                    // Not cached on failure, so the next visit tries again. Caching an upload that did
                    // not land is how a screen goes missing permanently.
                    LightSessionLog.error("wireframe \(screen) failed: \(error.localizedDescription)")
                }
            }
        }

        guard config.captureRealScreens, !state.hasScreenshot else { return }
        scheduleScreenshot(screen: screen, kind: kind, window: window, settledAs: snapshot)
    }

    /// Schedules the upgrade from wireframe to a real screenshot.
    ///
    /// Waits [ScreenshotTiming.quietPeriod] with nobody touching the screen. A touch or a navigation cancels it
    /// outright — see `ScreenshotTiming.Cancellation.touched` for why cancelling beats postponing.
    ///
    /// The window is captured weakly and re-read at fire time rather than the snapshot being reused from the
    /// wireframe: the whole reason for waiting is that the screen is still arriving, so a mask built five
    /// seconds ago would describe a screen that no longer exists — and the mask is what keeps text off the wire.
    private func scheduleScreenshot(
        screen: String,
        kind: ScreenIdentity.Kind,
        window: UIWindow,
        settledAs snapshot: ViewSnapshot
    ) {
        cancelPendingScreenshot()
        touchedSinceScheduled = false
        screenshotOwed = (screen, kind, snapshot)

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
            self.screenshotOwed = nil
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

    /// The quiet period's last chance: a screen leaving with its screenshot still owed is captured now,
    /// before the transition's first frame replaces its pixels.
    ///
    /// This exists for the screens the quiet period can never photograph — the ones touched from
    /// arrival to departure, which is every form and above all the login. Measured before this existed:
    /// `Login` had no real screenshot in any session, because every keystroke cancelled the timer and
    /// the navigation away cancelled whatever was left. Departure is itself the quiet moment the rule
    /// waits for: the finger is up and nothing can change the screen again.
    ///
    /// Synchronous on purpose, and the moment matters more than it looks. This runs inside
    /// `viewWillDisappear`, when the outgoing view is still in the hierarchy and the window's last
    /// committed frame is still the departing screen — `drawHierarchy(afterScreenUpdates: false)` reads
    /// exactly that frame. One run-loop turn later the transition has drawn and the picture is of two
    /// screens mid-slide. That is also why this cannot share `somethingLeftTheScreen`'s deferred
    /// re-read: by `viewDidDisappear` there is nothing left to photograph.
    ///
    /// Filtered by role, which the timer path never needed: `viewWillDisappear` fires for containers
    /// (alongside the screen they hold), for alerts and for the keyboard's own controllers. A capture
    /// triggered by an alert closing would file a picture of the alert mid-dismissal as *the* screenshot
    /// of the screen under it. Only a controller that is itself a screen — or the host every SwiftUI
    /// screen lives in, which is what departs when a route changes — settles the debt.
    private func screenIsLeaving(_ controller: UIViewController) {
        guard let owed = screenshotOwed else { return }

        switch roleOfObservedController(
            isOnScreen: controller.isLightSessionOnScreen,
            isContainer: controller.isLightSessionContainer,
            isOwnedByApp: controller.isLightSessionOwnedByApp,
            isHostingController: controller.isLightSessionHostingController
        ) {
        case .screen, .unnamedSwiftUIHost:
            break
        case .offscreen, .container, .systemFurniture:
            return
        }

        if let reason = ScreenshotTiming.decideOnDeparture(
            owedFor: owed.screen,
            currentScreen: lastReported,
            isRecording: Recording.shared.isEnabled,
            isInteractive: controller.transitionCoordinator?.isInteractive == true
        ) {
            LightSessionLog.debug("departure screenshot of \(owed.screen) skipped: \(reason)")
            return
        }

        // A screen leaving under a standing cover is not photographed: the committed frame shows the
        // cover, and the cover is transient chrome — measured on the sample's alert route, where a
        // screen popped with its alert still up filed a picture of the dialog as *the* screenshot of
        // the screen. `isBeingPresented` is what separates that from the other way this state occurs:
        // when a full-screen modal is the very thing driving the departure, the cover's presentation
        // has only just begun, the committed frame is still the clean screen, and skipping would throw
        // away the one capture this exists to take.
        if let cover = controller.presentedViewController, !cover.isBeingPresented {
            LightSessionLog.debug(
                "departure screenshot of \(owed.screen) skipped: it is leaving under \(type(of: cover))"
            )
            return
        }

        // The controller's own window rather than the key one: a root swap has already made a new
        // controller the root by the time the old one's `viewWillDisappear` runs, but the departing
        // view is still attached and its window is the one whose last frame shows it.
        guard let window = controller.view.window else { return }

        screenshotOwed = nil
        cancelPendingScreenshot()
        LightSessionLog.debug("screenshot of \(owed.screen) taken on departure: the quiet period never elapsed")
        captureScreenshot(screen: owed.screen, kind: owed.kind, window: window, alsoMaskedBy: owed.snapshot)
    }

    /// Renders and uploads the screenshot, reading the screen as it is now.
    ///
    /// - Parameter describedBy: the tree that describes the pixels being captured, when reading the
    ///   hierarchy now would describe something else. `drawHierarchy(afterScreenUpdates: false)` renders
    ///   the last *committed* frame, and at a route change that frame is the departing screen while the
    ///   tree already belongs to the next one — masking one screen's pixels with another screen's
    ///   rectangles is how text goes out uncovered. Nil means the hierarchy is the truth, which it is
    ///   everywhere else.
    /// - Parameter alsoMaskedBy: a second tree whose text is covered as well. The departure capture
    ///   passes the settle-time tree here, and the reason is measured: popping a screen while it has
    ///   something presented over it tears the navigation title out of the model tree while the
    ///   committed pixels still show it — the current tree said the screen held no title, the picture
    ///   held one, and the title went out legible. The settle-time tree still knows that rectangle. A
    ///   union can only add covers, and a mask too many is the direction this SDK is allowed to err in.
    private func captureScreenshot(
        screen: String,
        kind: ScreenIdentity.Kind,
        window: UIWindow,
        describedBy: ViewSnapshot? = nil,
        alsoMaskedBy: ViewSnapshot? = nil
    ) {
        let snapshot = describedBy ?? window.lightSessionContent
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

        // The two halves separately, with only the one that reads views on the main thread. This runs
        // at two moments now, and one of them is the first frame of a transition — the reading is what
        // must happen there (the pixels are about to change), while the JPEG encode is pure arithmetic
        // that would spend those milliseconds blocking the very animation the person just started.
        let policy = ScreenshotRenderer.MaskPolicy(text: config.maskText, images: config.maskImages)
        guard let image = ScreenshotRenderer.capture(
            window: window, snapshot: snapshot, alsoMaskedBy: alsoMaskedBy, policy: policy
        ) else {
            LightSessionLog.debug("\(screen) could not be rendered")
            return
        }

        let appVersionName = self.appVersionName
        let appVersionCode = self.appVersionCode
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let jpeg = ScreenshotRenderer.encode(image, quality: 0.6) else { return }

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
            DispatchQueue.main.async {
                guard let self else { return }
                self.sender.replaceScreenshot(screen: withImage) { [weak self] result in
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
