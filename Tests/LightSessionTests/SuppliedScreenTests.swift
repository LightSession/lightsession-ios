import XCTest
@testable import LightSession

/// Which description a wireframe is drawn with, and how a layout is told apart from another.
final class SuppliedScreenTests: XCTestCase {

    private final class Host {}

    private let described = ViewSnapshot(
        frame: Rect(left: 0, top: 0, right: 390, bottom: 844),
        kind: .container,
        children: [ViewSnapshot(frame: Rect(left: 16, top: 100, right: 200, bottom: 124), kind: .text)]
    )

    override func tearDown() {
        // Process-wide state: a description left here would reach every later wireframe.
        SuppliedScreen.clear()
        super.tearDown()
    }

    func testNoDescriptionIsNoGraft() {
        XCTAssertNil(SuppliedScreen.graft(for: "home"))
    }

    func testADescriptionIsForTheScreenItNames() {
        let host = Host()
        SuppliedScreen.set(root: described, host: host, screenName: "home")
        let graft = SuppliedScreen.graft(for: "home")
        XCTAssertTrue(graft?.host === host)
        XCTAssertEqual(graft?.root, described)
        XCTAssertNil(
            SuppliedScreen.graft(for: "gallery"),
            "the screen just left, read while the one arrived at is drawn"
        )
    }

    func testADescriptionThatNamesNoScreenMakesNoClaim() {
        let host = Host()
        SuppliedScreen.set(root: described, host: host, screenName: nil)
        XCTAssertNotNil(SuppliedScreen.graft(for: "home"))
        XCTAssertNotNil(SuppliedScreen.graft(for: nil))
    }

    func testAnEmbedderThatWentAwayTakesItsDescriptionWithIt() {
        var host: Host? = Host()
        SuppliedScreen.set(root: described, host: host!, screenName: "home")
        host = nil
        XCTAssertNil(SuppliedScreen.graft(for: "home"))
    }

    func testClearForgetsIt() {
        let host = Host()
        SuppliedScreen.set(root: described, host: host, screenName: "home")
        SuppliedScreen.clear()
        XCTAssertNil(SuppliedScreen.graft(for: "home"))
    }

    // MARK: - Appearance

    /// A Flutter app with `ThemeMode.dark` draws dark on a device in light mode, and the trait — all
    /// the SDK read — said light: measured on a simulator, a screen dark to the pixel filed as Light.
    func testAnEmbedderDrawingDarkOnALightDeviceIsFiledDark() {
        XCTAssertEqual(Theme.filed(platformDark: false, embedderDark: nil), .light)
        XCTAssertEqual(Theme.filed(platformDark: true, embedderDark: nil), .dark)
        XCTAssertEqual(Theme.filed(platformDark: false, embedderDark: true), .dark)
        XCTAssertEqual(Theme.filed(platformDark: true, embedderDark: false), .light)
    }

    func testTheAppearanceStandsUntilItIsWithdrawn() {
        SuppliedScreen.setDark(true)
        XCTAssertEqual(SuppliedScreen.dark, true)
        SuppliedScreen.setDark(nil)
        XCTAssertNil(SuppliedScreen.dark, "nil follows the platform again")
        SuppliedScreen.setDark(true)
        SuppliedScreen.clear()
        XCTAssertNil(SuppliedScreen.dark, "an embedder going away takes its appearance with it")
    }

    // MARK: - Layout keys

    private func frame(_ nodes: [SkeletonNode]) -> SkeletonFrame {
        SkeletonFrame(width: 1170, height: 2532, background: nil, nodes: nodes)
    }

    private func node(_ top: Int, _ kind: NodeKind = .text, color: String? = nil) -> SkeletonNode {
        SkeletonNode(left: 48, top: top, right: 600, bottom: top + 72, kind: kind, color: color, stroke: false)
    }

    func testTheSameLayoutInOtherColoursIsTheSameLayout() {
        XCTAssertEqual(
            SkeletonBuilder.layoutKey(frame([node(300, .container, color: "#FFFFFF")])),
            SkeletonBuilder.layoutKey(frame([node(300, .container, color: "#000000")])),
            "a colour sampled a shade apart is not a new layout"
        )
    }

    func testARectangleMovedOrRetypedIsAnotherLayout() {
        let key = SkeletonBuilder.layoutKey(frame([node(300)]))
        XCTAssertNotEqual(key, SkeletonBuilder.layoutKey(frame([node(302)])))
        XCTAssertNotEqual(key, SkeletonBuilder.layoutKey(frame([node(300, .image)])))
        XCTAssertNotEqual(key, SkeletonBuilder.layoutKey(frame([node(300), node(400)])))
    }
}
