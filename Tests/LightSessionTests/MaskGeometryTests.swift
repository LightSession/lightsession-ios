import XCTest
@testable import LightSession

/// What gets covered, and what stops being covered once something opaque is on top of it.
///
/// The first test here is the bug as reported: the mask of one screen drawn over the next. It was visible in the
/// product — grey blocks where screen B has no text, while screen B's own text stayed legible — and it could not be
/// caught before this file existed, because the decision lived inside the UIKit renderer where no test could reach.
final class MaskGeometryTests: XCTestCase {

    private let window = Rect(left: 0, top: 0, right: 390, bottom: 844)

    private func rect(_ l: Double, _ t: Double, _ r: Double, _ b: Double) -> Rect {
        Rect(left: l, top: t, right: r, bottom: b)
    }

    /// An opaque background, the way a pushed screen's root view is.
    private func opaqueScreen(_ frame: Rect, children: [ViewSnapshot]) -> ViewSnapshot {
        ViewSnapshot(
            frame: frame,
            kind: .container,
            color: Color(red: 1, green: 1, blue: 1, alpha: 1),
            declaresOpaque: true,
            children: children
        )
    }

    private func label(_ frame: Rect) -> ViewSnapshot {
        ViewSnapshot(frame: frame, kind: .text)
    }

    // MARK: - The reported bug

    /// Mid-transition both view controllers' views are in the window. Only the top one is on screen.
    func testTheScreenBeingLeftContributesNoMasks() {
        let leaving = opaqueScreen(window, children: [label(rect(20, 100, 370, 130))])
        let arriving = opaqueScreen(window, children: [label(rect(20, 400, 370, 430))])
        let root = ViewSnapshot(frame: window, kind: .container, children: [leaving, arriving])

        let rects = MaskGeometry.rects(in: root, policy: .default, bounds: window)
        XCTAssertEqual(rects.count, 1, "only the screen on top may contribute")
        XCTAssertEqual(rects.first?.top, 400, "and it is the arriving screen's label, not the leaving one's")
    }

    /// The ordering is what makes it work: an opaque cover clears what came *before* it in paint order.
    func testAnOpaqueCoverClearsOnlyWhatIsBeneathIt() {
        let root = ViewSnapshot(
            frame: window,
            kind: .container,
            children: [
                label(rect(0, 0, 100, 20)),          // beneath — hidden
                opaqueScreen(window, children: []),  // the cover
                label(rect(0, 500, 100, 520)),       // above — visible
            ]
        )
        let rects = MaskGeometry.rects(in: root, policy: .default, bounds: window)
        XCTAssertEqual(rects.map(\.top), [500])
    }

    /// A sheet or a card covers part of the screen. What it hides goes; what it does not, stays.
    func testAPartialCoverClearsOnlyWhatItContains() {
        let card = ViewSnapshot(
            frame: rect(0, 300, 390, 600),
            kind: .container,
            color: Color(red: 1, green: 1, blue: 1, alpha: 1),
            declaresOpaque: true
        )
        let root = ViewSnapshot(
            frame: window,
            kind: .container,
            children: [
                label(rect(20, 350, 200, 380)),  // inside the card's area — hidden
                label(rect(20, 100, 200, 130)),  // above the card — visible
                card,
            ]
        )
        let rects = MaskGeometry.rects(in: root, policy: .default, bounds: window)
        XCTAssertEqual(rects.map(\.top), [100])
    }

    /// Erring the safe way. A partly-covered mask is not trimmed — it keeps its whole rectangle. A mask slightly
    /// too large hides what was already hidden; trimming could expose text.
    func testAMaskStraddlingACoverIsKeptWhole() {
        let card = ViewSnapshot(
            frame: rect(0, 300, 390, 600),
            kind: .container,
            color: Color(red: 1, green: 1, blue: 1, alpha: 1),
            declaresOpaque: true
        )
        let root = ViewSnapshot(
            frame: window,
            kind: .container,
            children: [label(rect(20, 280, 200, 320)), card]  // crosses the card's top edge
        )
        let rects = MaskGeometry.rects(in: root, policy: .default, bounds: window)
        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects.first?.top, 280)
    }

    // MARK: - What counts as a cover

    /// A translucent overlay does not hide what is behind it, so it must not clear anything.
    func testATranslucentViewIsNotACover() {
        let scrim = ViewSnapshot(
            frame: window,
            kind: .container,
            alpha: 0.5,
            color: Color(red: 0, green: 0, blue: 0, alpha: 1),
            declaresOpaque: true
        )
        let root = ViewSnapshot(frame: window, kind: .container, children: [label(rect(0, 0, 100, 20)), scrim])
        XCTAssertEqual(MaskGeometry.rects(in: root, policy: .default, bounds: window).count, 1)
    }

    /// Nor does a view whose background is see-through, however opaque it claims to be.
    func testAClearBackgroundIsNotACover() {
        let empty = ViewSnapshot(frame: window, kind: .container, color: nil, declaresOpaque: true)
        let root = ViewSnapshot(frame: window, kind: .container, children: [label(rect(0, 0, 100, 20)), empty])
        XCTAssertEqual(MaskGeometry.rects(in: root, policy: .default, bounds: window).count, 1)
    }

    /// Nor one that has a solid colour but tells UIKit things show through it.
    func testAViewThatDeniesBeingOpaqueIsNotACover() {
        let painted = ViewSnapshot(
            frame: window,
            kind: .container,
            color: Color(red: 1, green: 1, blue: 1, alpha: 1),
            declaresOpaque: false
        )
        let root = ViewSnapshot(frame: window, kind: .container, children: [label(rect(0, 0, 100, 20)), painted])
        XCTAssertEqual(MaskGeometry.rects(in: root, policy: .default, bounds: window).count, 1)
    }

    /// A pushed view's frame comes out of a layout pass and lands on fractional points, so "covers the window" has
    /// to tolerate rounding. Equality would answer no on exactly the case this rule exists for.
    func testAlmostExactlyCoveringStillCounts() {
        let screen = opaqueScreen(rect(0, 0.5, 390, 843.5), children: [])
        let root = ViewSnapshot(frame: window, kind: .container, children: [label(rect(0, 0, 100, 20)), screen])
        XCTAssertTrue(MaskGeometry.rects(in: root, policy: .default, bounds: window).isEmpty)
    }

    // MARK: - The policy itself

    func testTextAndFieldsFollowTheTextPolicy() {
        XCTAssertTrue(MaskGeometry.isCovered(.text, by: .default))
        XCTAssertTrue(MaskGeometry.isCovered(.input, by: .default))
        XCTAssertFalse(MaskGeometry.isCovered(.image, by: .default), "icons and logos are opt-in")
    }

    func testAControlIsNotCoveredButItsLabelIs() {
        let button = ViewSnapshot(frame: rect(0, 0, 200, 44), kind: .button, children: [label(rect(10, 10, 190, 34))])
        let root = ViewSnapshot(frame: window, kind: .container, children: [button])
        let rects = MaskGeometry.rects(in: root, policy: .default, bounds: window)
        XCTAssertEqual(rects.count, 1, "the control keeps its shape; the words inside it do not")
        XCTAssertEqual(rects.first?.top, 10)
    }

    func testHiddenTextIsNotMasked() {
        let root = ViewSnapshot(
            frame: window,
            kind: .container,
            children: [
                ViewSnapshot(frame: rect(0, 0, 100, 20), kind: .text, isHidden: true),
                ViewSnapshot(frame: rect(0, 30, 100, 50), kind: .text, alpha: 0),
            ]
        )
        XCTAssertTrue(MaskGeometry.rects(in: root, policy: .default, bounds: window).isEmpty)
    }

    func testMasksAreClippedToTheCapture() {
        let root = ViewSnapshot(frame: window, kind: .container, children: [label(rect(300, 800, 900, 900))])
        let rects = MaskGeometry.rects(in: root, policy: .default, bounds: window)
        XCTAssertEqual(rects.first?.right, 390)
        XCTAssertEqual(rects.first?.bottom, 844)
    }
}
