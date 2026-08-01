import XCTest
@testable import LightSession

/// The screen-source decision, walked exhaustively.
///
/// Two booleans is four cases, so "exhaustively" is literal here — and that is the reason this
/// decision is a function instead of branching inside the tracker. On Android the same logic lived
/// nested inside a lifecycle callback and got two of its four cases wrong for nineteen commits,
/// because there was nowhere to write this file.
final class ScreenSourceTests: XCTestCase {

    private let allCases: [(hostsSwiftUI: Bool, reported: Bool)] = [
        (false, false), (false, true), (true, false), (true, true),
    ]

    func testUIKitAppIsObserved() {
        let plan = planScreenSource(hostsSwiftUI: false, screensReportedByHost: false)
        XCTAssertEqual(plan.source, .viewControllers)
        XCTAssertTrue(plan.observeViewControllers)
        XCTAssertFalse(plan.adviseIfSilent, "a UIKit app has nothing to be advised about")
    }

    func testHostReportingAppIsNotObserved() {
        let plan = planScreenSource(hostsSwiftUI: true, screensReportedByHost: true)
        XCTAssertEqual(plan.source, .reportedByHost)
        XCTAssertFalse(
            plan.observeViewControllers,
            "observing as well would report the hosting controller over the name the app gave"
        )
    }

    /// A SwiftUI app that never opted in is still mapped, and told about it.
    ///
    /// The alternative — reporting nothing until the app cooperates — produces a recorder that looks
    /// installed and maps nothing, which is the failure that takes longest to notice.
    func testSwiftUIWithoutOptInIsObservedAndAdvised() {
        let plan = planScreenSource(hostsSwiftUI: true, screensReportedByHost: false)
        XCTAssertEqual(plan.source, .viewControllers)
        XCTAssertTrue(plan.observeViewControllers)
        XCTAssertTrue(plan.adviseIfSilent)
    }

    /// Opting in wins even when the root is not SwiftUI: a UIKit app is free to name its own screens,
    /// and having asked to, it must not also be observed.
    func testHostReportingWinsOverUIKitRoot() {
        let plan = planScreenSource(hostsSwiftUI: false, screensReportedByHost: true)
        XCTAssertEqual(plan.source, .reportedByHost)
        XCTAssertFalse(plan.observeViewControllers)
    }

    // MARK: - Invariants over the whole space

    func testExactlyOneSourceIsEverLive() {
        for c in allCases {
            let plan = planScreenSource(hostsSwiftUI: c.hostsSwiftUI, screensReportedByHost: c.reported)
            let observing = plan.observeViewControllers
            let reporting = plan.source == .reportedByHost
            XCTAssertNotEqual(
                observing, reporting,
                "case \(c) has \(observing ? "both" : "neither") source live"
            )
        }
    }

    func testAdviceOnlyWhenThereIsSomethingToAdvise() {
        for c in allCases {
            let plan = planScreenSource(hostsSwiftUI: c.hostsSwiftUI, screensReportedByHost: c.reported)
            if plan.adviseIfSilent {
                XCTAssertTrue(c.hostsSwiftUI, "advising a non-SwiftUI app would be noise: \(c)")
                XCTAssertFalse(c.reported, "advising an app that already reports is wrong: \(c)")
            }
        }
    }
}

/// What happens to a controller the SDK saw appear.
///
/// The middle case is the one that was measured wrong before it was written down: a run of the sample
/// recorded `SwiftUIHome` and then an edge to `SwiftUIHostViewController` — a navigation the user never
/// made, to a container rather than a place.
final class ObservedControllerTests: XCTestCase {

    func testAnOrdinaryControllerIsAScreen() {
        XCTAssertEqual(
            actionForObservedController(isHostingController: false, hostHasReportedAScreen: false),
            .reportNow
        )
        XCTAssertEqual(
            actionForObservedController(isHostingController: false, hostHasReportedAScreen: true),
            .reportNow,
            "a UIKit screen is still a screen in an app that also names SwiftUI ones"
        )
    }

    func testAHostingControllerIsNotAScreenOnceTheAppNamesItsOwn() {
        XCTAssertEqual(
            actionForObservedController(isHostingController: true, hostHasReportedAScreen: true),
            .drop
        )
    }

    /// Not dropped outright: an app that adopted SwiftUI and never opted in must still be mapped, because
    /// a recorder that maps nothing looks exactly like one that is working.
    func testAHostingControllerWaitsBeforeBeingReported() {
        XCTAssertEqual(
            actionForObservedController(isHostingController: true, hostHasReportedAScreen: false),
            .waitForHost
        )
    }
}

/// What a controller *is*, which is asked before what to do with it.
///
/// Written against a real session rather than from first principles. A SwiftUI app recorded fifteen
/// screens: eleven were UIKit's own keyboard and autofill machinery, three were SwiftUI's hosting
/// controllers under mangled generic names, and none were the app's. Each test below names the
/// controller from that run that it stands for.
final class ObservedControllerRoleTests: XCTestCase {

    private func role(
        onScreen: Bool = true,
        container: Bool = false,
        ownedByApp: Bool = true,
        hosting: Bool = false
    ) -> ObservedControllerRole {
        roleOfObservedController(
            isOnScreen: onScreen,
            isContainer: container,
            isOwnedByApp: ownedByApp,
            isHostingController: hosting
        )
    }

    func testTheAppsOwnControllerIsAScreen() {
        XCTAssertEqual(role(), .screen)
    }

    /// `UIPredictionViewController`, `_UICursorAccessoryViewController`,
    /// `_SFAppPasswordSavingViewController`: everything a tap on a text field brings with it.
    func testAControllerTheAppDoesNotOwnIsNotAScreen() {
        XCTAssertEqual(role(ownedByApp: false), .systemFurniture)
    }

    /// `_TtGC7SwiftUI19UIHostingController…` and its two siblings, which stand for the same container.
    func testSwiftUIsOwnHostingControllerIsCalledOutSeparately() {
        XCTAssertEqual(
            role(ownedByApp: false, hosting: true),
            .unnamedSwiftUIHost,
            "this is the case the developer can act on, so it must not be lost among the furniture"
        )
    }

    /// The sample's `SwiftUIHostViewController`, and every app that subclasses `UIHostingController` to
    /// set a title or lock an orientation.
    func testAnAppsOwnHostingControllerStaysWithTheOlderHandling() {
        XCTAssertEqual(
            role(hosting: true),
            .screen,
            "it has a name the app chose, so it goes to actionForObservedController as it always did"
        )
    }

    func testContainersAreFurnitureWhoeverOwnsThem() {
        XCTAssertEqual(role(container: true), .container)
        XCTAssertEqual(
            role(container: true, ownedByApp: false),
            .container,
            "an app's own UINavigationController subclass frames a screen rather than being one"
        )
    }

    func testNothingOffScreenIsAnything() {
        for owned in [true, false] {
            for hosting in [true, false] {
                XCTAssertEqual(
                    role(onScreen: false, ownedByApp: owned, hosting: hosting),
                    .offscreen,
                    "owned=\(owned) hosting=\(hosting)"
                )
            }
        }
    }

    /// The whole space, against the one property that matters: only the app's own code names a screen.
    func testOnlyTheAppsOwnCodeCanBecomeAScreen() {
        for onScreen in [true, false] {
            for container in [true, false] {
                for owned in [true, false] {
                    for hosting in [true, false] {
                        let r = roleOfObservedController(
                            isOnScreen: onScreen,
                            isContainer: container,
                            isOwnedByApp: owned,
                            isHostingController: hosting
                        )
                        if r == .screen {
                            XCTAssertTrue(onScreen)
                            XCTAssertFalse(container)
                            XCTAssertTrue(owned, "a screen was named from code the app does not own")
                        }
                    }
                }
            }
        }
    }
}

/// What a SwiftUI screen is called when the app has not called it anything.
///
/// The measurement behind this: a real app's twenty-one screens, of which nineteen already had a
/// `.navigationTitle` written for the user — "Roteiro", "Painel", "Cobertura" — and two did not.
/// Reading them is the difference between integrating in one line and integrating in one line per
/// screen. The two that did not, plus the two whose titles are built from a record, are what the rest
/// of these tests are about.
final class SwiftUIHostNamingTests: XCTestCase {

    private let naming = SwiftUITitleNaming(limit: 3)

    func testATitleIsTheName() {
        XCTAssertEqual(
            nameForSwiftUIHost(title: "Roteiro", alreadyNamed: 0, naming: naming),
            .title("Roteiro")
        )
    }

    func testNoTitleIsThePlaceholder() {
        XCTAssertEqual(
            nameForSwiftUIHost(title: nil, alreadyNamed: 0, naming: naming),
            .placeholder
        )
        XCTAssertEqual(
            nameForSwiftUIHost(title: "", alreadyNamed: 0, naming: naming),
            .placeholder,
            "an empty title says as little as no title"
        )
    }

    /// Turning it off has to go back to the old behaviour exactly, not to a quieter version of the new
    /// one: an app that switched this off because its titles are translated must not find some of them
    /// in the map anyway.
    func testTurningItOffReadsNoTitleAtAll() {
        XCTAssertEqual(
            nameForSwiftUIHost(title: "Roteiro", alreadyNamed: 0, naming: nil),
            .placeholder
        )
    }

    /// `.navigationTitle(doctor.name)` is a node per doctor. The limit is the backstop.
    func testTooManyDistinctTitlesStopsBeingBelieved() {
        XCTAssertEqual(
            nameForSwiftUIHost(title: "Dr. Ana", alreadyNamed: 2, naming: naming),
            .title("Dr. Ana"),
            "still under the limit"
        )
        XCTAssertEqual(
            nameForSwiftUIHost(title: "Dr. Bruno", alreadyNamed: 3, naming: naming),
            .tooManyTitles,
            "the limit counts titles already accepted, so at it the next new one is one too many"
        )
    }

    /// The screens named before the limit was hit keep their names. Falling back for *everything*
    /// would throw away the nineteen that were right to punish the two that were not.
    func testTheLimitOnlyAffectsWhatComesAfterIt() {
        let underTheLimit = nameForSwiftUIHost(title: "Painel", alreadyNamed: 1, naming: naming)
        XCTAssertEqual(underTheLimit, .title("Painel"))
    }

    func testAnAppWithoutTitlesIsUnaffectedByTheLimit() {
        XCTAssertEqual(
            nameForSwiftUIHost(title: nil, alreadyNamed: 99, naming: naming),
            .placeholder,
            "no title is no title, however many other screens have one"
        )
    }
}

/// Naming a screen from the value the app routes on.
///
/// The last resort and the best one, after ten attempts to read the answer out of SwiftUI's internals.
/// The app's own routing value is not a workaround for those failures — it is a better name than any of
/// them would have produced, because it is what the team calls the screen rather than what the framework
/// happens to be rendering.
final class RouteScreenNameTests: XCTestCase {

    private enum Route: Equatable {
        case loading
        case login
        case doctorDetail(String)
        case editDoctor(id: String, draft: Bool)
    }

    func testAPlainCaseIsItsOwnName() {
        XCTAssertEqual(screenName(forRoute: Route.login), "login")
        XCTAssertEqual(screenName(forRoute: Route.loading), "loading")
    }

    /// The payload is dropped, for the same reason a title built from a record is refused: one screen,
    /// not one node per doctor.
    func testAPayloadIsNotPartOfTheName() {
        XCTAssertEqual(screenName(forRoute: Route.doctorDetail("dr-carlos")), "doctorDetail")
        XCTAssertEqual(screenName(forRoute: Route.doctorDetail("dra-ana")), "doctorDetail")
        XCTAssertEqual(
            screenName(forRoute: Route.editDoctor(id: "x", draft: true)),
            "editDoctor",
            "a labelled payload is still a payload"
        )
    }

    /// Not every app routes on an enum.
    func testOtherValuesAreDescribedAsWritten() {
        XCTAssertEqual(screenName(forRoute: "Checkout"), "Checkout")
        XCTAssertEqual(screenName(forRoute: 7), "7")
    }

    /// Nothing is capitalised or tidied. A name the SDK invents is a name nobody can grep for in their
    /// own source.
    func testTheNameIsNotPrettified() {
        XCTAssertEqual(screenName(forRoute: Route.login), "login", "not Login")
    }

    func testEmptyIsNotAName() {
        XCTAssertNil(screenName(forRoute: "   "))
    }
}

/// Where a class's code has to live to count as the app's.
final class AppOwnershipPathTests: XCTestCase {

    private let app = "/Devices/1/Bundle/Application/ABC/PharmManager.app"

    func testTheAppItselfIsTheApp() {
        XCTAssertTrue(isPathInsideApp(app, appPath: app))
    }

    /// A modular codebase keeps its screens in frameworks, and they are still its screens.
    func testAnEmbeddedFrameworkIsTheApp() {
        XCTAssertTrue(isPathInsideApp(app + "/Frameworks/Feature.framework", appPath: app))
    }

    func testASystemFrameworkIsNot() {
        XCTAssertFalse(
            isPathInsideApp("/System/Library/PrivateFrameworks/UIKitCore.framework", appPath: app)
        )
        XCTAssertFalse(isPathInsideApp("/usr/lib", appPath: app))
    }

    /// The reason the separator is part of the prefix.
    func testANeighbourThatMerelyStartsTheSameWayIsNot() {
        XCTAssertFalse(isPathInsideApp(app + ".dSYM", appPath: app))
        XCTAssertFalse(isPathInsideApp(app + "Extras/Other.framework", appPath: app))
    }
}
