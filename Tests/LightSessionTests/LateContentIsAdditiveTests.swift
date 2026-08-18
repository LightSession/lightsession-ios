import XCTest
@testable import LightSession

/// A recapture may only replace a stored one if it is still a picture of the same screen.
///
/// The late-content watch resends when the rectangle count grows, and growth on its own turned out
/// to be two different events wearing the same number. Content finishing its arrival grows the
/// count. So does a modal closing over a screen busier than itself — and the second one filed the
/// picture of a company list under the name of the sheet that had been covering it, replacing a
/// capture that was correct.
///
/// The difference is not in the count, it is in *which rectangles*. Late content keeps what was
/// already there and adds to it. A screen change keeps nothing.
///
/// Written as a table because the first attempt at this was a timing rule — cancel the watch when
/// the modal's controller disappears — and it lost the race in the real app, where SwiftUI updates
/// its binding after the dismissal and the watch ticks in the gap. What a capture *contains* is
/// knowable without knowing when anything happened.
final class LateContentIsAdditiveTests: XCTestCase {

    private func node(_ top: Int, _ kind: NodeKind = .text) -> SkeletonNode {
        SkeletonNode(left: 40, top: top, right: 1160, bottom: top + 60, kind: kind, color: nil, stroke: false)
    }

    private func frame(_ nodes: [SkeletonNode]) -> SkeletonFrame {
        SkeletonFrame(width: 1206, height: 2622, background: nil, nodes: nodes)
    }

    /// The case the watch exists for: a list that finishes loading keeps its heading and its first
    /// rows exactly where they were, and gains more underneath.
    func testContentArrivingLateIsAdditiveAndAllowed() {
        let baseline = frame([node(100), node(200), node(300)])
        let fresh = frame([node(100), node(200), node(300), node(400), node(500), node(600)])
        XCTAssertTrue(SkeletonBuilder.retainsMostOf(baseline, in: fresh))
    }

    /// The case that corrupted a stored capture: the sheet is gone and the screen behind it is
    /// bigger, so the count grew — and not one rectangle is shared.
    func testAModalClosingOverABusierScreenIsRefused() {
        let sheet = frame((0..<12).map { node(200 + $0 * 70) })
        let listBehind = frame((0..<40).map { node(60 + $0 * 61, .card) })
        XCTAssertFalse(
            SkeletonBuilder.retainsMostOf(sheet, in: listBehind),
            "more rectangles, none of them the sheet's: this is a different screen, not late content"
        )
    }

    /// Reflow is not a screen change. A row growing to two lines shifts everything under it, and
    /// demanding every rectangle survive would refuse the upgrades this watch is for.
    func testAReflowThatKeepsHalfIsStillAllowed() {
        let baseline = frame((0..<10).map { node(100 + $0 * 100) })
        // The top half stays put; the bottom half slides down by a row's height, plus new content.
        let moved = (5..<10).map { node(100 + $0 * 100 + 40) }
        let added = (10..<16).map { node(100 + $0 * 100) }
        let fresh = frame((0..<5).map { node(100 + $0 * 100) } + moved + added)
        XCTAssertTrue(SkeletonBuilder.retainsMostOf(baseline, in: fresh))
    }

    /// An empty baseline has nothing to keep, and a capture that had nothing is exactly the one most
    /// worth replacing.
    func testAnEmptyBaselineIsAlwaysReplaceable() {
        XCTAssertTrue(SkeletonBuilder.retainsMostOf(frame([]), in: frame([node(100)])))
    }

    /// Position is identity here, not colour: the same rectangle recoloured by a theme change is
    /// still the same rectangle.
    func testColourIsNotPartOfTheComparison() {
        let baseline = frame([node(100), node(200)])
        let recoloured = frame([
            SkeletonNode(left: 40, top: 100, right: 1160, bottom: 160, kind: .text, color: "#FFFFFF", stroke: false),
            SkeletonNode(left: 40, top: 200, right: 1160, bottom: 260, kind: .text, color: "#000000", stroke: false),
            node(300),
        ])
        XCTAssertTrue(SkeletonBuilder.retainsMostOf(baseline, in: recoloured))
    }

    // MARK: - Which screens the rule is asked of

    /// The bug the rule itself caused. A list settles on five placeholder cards, then fills in with
    /// dozens of real rows that share nothing with them by position or kind. Asked of every screen,
    /// `retainsMostOf` read that as a change of screen and froze the capture on the placeholder — in
    /// production, where the wait is long enough for a placeholder to settle in the first place.
    func testABareScreenMayReplaceItsPlaceholderWithSomethingUnrelated() {
        let placeholders = frame((0..<5).map { node(120 + $0 * 110, .unknown) })
        let loaded = frame((0..<40).map { node(60 + $0 * 61) })
        XCTAssertFalse(
            SkeletonBuilder.retainsMostOf(placeholders, in: loaded),
            "these two really do share nothing; the rule is right about that and wrong to be asked"
        )
        XCTAssertTrue(
            SkeletonBuilder.acceptsLateContent(screen: "dispatches", baseline: placeholders, fresh: loaded),
            "a bare screen has nothing over it to leave, so growth is the screen finishing"
        )
    }

    /// And the limit must not swallow the case the rule was written for: the same unrelated growth,
    /// under a composite name, is still a modal leaving.
    func testASubScreenStillRefusesTheScreenBehindIt() {
        let sheet = frame((0..<12).map { node(200 + $0 * 70) })
        let listBehind = frame((0..<40).map { node(60 + $0 * 61, .card) })
        XCTAssertFalse(
            SkeletonBuilder.acceptsLateContent(
                screen: "dispatches \(ScreenIdentity.subScreenSeparator) Trocar empresa",
                baseline: sheet,
                fresh: listBehind
            ),
            "a composite name can be revealed past, and this is what that looks like"
        )
    }

    /// A sub-screen loading its own content late is the reason this is a share and not a ban.
    func testASubScreenMayStillFillInItsOwnContent() {
        let empty = frame([node(200), node(300), node(400)])
        let filled = frame([node(200), node(300), node(400), node(500), node(600), node(700)])
        XCTAssertTrue(
            SkeletonBuilder.acceptsLateContent(
                screen: "dispatch/detail \(ScreenIdentity.subScreenSeparator) Sheet",
                baseline: empty,
                fresh: filled
            )
        )
    }
}
