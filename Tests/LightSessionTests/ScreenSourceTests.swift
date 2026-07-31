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
