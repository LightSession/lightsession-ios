import XCTest
@testable import LightSession

/// The wireframe rules, stated as assertions instead of as a picture to squint at.
///
/// Every test here corresponds to something that went wrong on Android, where the equivalent code had
/// no unit tests and two regressions shipped in one afternoon: a plain coloured view stopped counting
/// as content, and a settle check that could never reach zero declared every window ready 4 ms too
/// early. Both are one line to state here.
final class SkeletonBuilderTests: XCTestCase {

    private func rect(_ l: Double, _ t: Double, _ r: Double, _ b: Double) -> Rect {
        Rect(left: l, top: t, right: r, bottom: b)
    }

    private let opaqueGrey = Color(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)

    // MARK: - contentCount

    /// The bug that cost Android a screen's wireframe entirely.
    ///
    /// A plain `UIView` with a background colour classifies as `UNKNOWN`, and a splash or a caret
    /// screen is made of nothing else. When `UNKNOWN` did not count, such a screen was "empty"
    /// forever: it waited out the settle timeout and uploaded a blank frame.
    func testUnknownCountsAsContent() {
        let node = ViewSnapshot(frame: rect(0, 0, 100, 100), kind: .unknown, color: opaqueGrey)
        XCTAssertEqual(SkeletonBuilder.contentCount(node), 1)
    }

    /// The other half: a window is never empty, so containers must not count.
    ///
    /// Counting any view made the settle condition trivially true — the root view, the safe-area
    /// container and the status-bar host are always there. On Android that produced a capture 4 ms
    /// before the app's JavaScript even started, and the resulting PNG was byte-identical to the blank
    /// one it replaced, which is why nobody noticed by looking.
    func testContainersDoNotCount() {
        let window = ViewSnapshot(
            frame: rect(0, 0, 390, 844),
            kind: .container,
            children: [
                ViewSnapshot(frame: rect(0, 0, 390, 844), kind: .container),
                ViewSnapshot(frame: rect(0, 0, 390, 47), kind: .container),
            ]
        )
        XCTAssertEqual(SkeletonBuilder.contentCount(window), 0, "furniture is not content")
    }

    func testContentIsCountedThroughContainers() {
        let window = ViewSnapshot(
            frame: rect(0, 0, 390, 844),
            kind: .container,
            children: [
                ViewSnapshot(
                    frame: rect(0, 0, 390, 844),
                    kind: .container,
                    children: [
                        ViewSnapshot(frame: rect(16, 60, 300, 90), kind: .text),
                        ViewSnapshot(frame: rect(16, 100, 300, 140), kind: .input),
                    ]
                )
            ]
        )
        XCTAssertEqual(SkeletonBuilder.contentCount(window), 2)
    }

    func testHiddenAndTransparentContentDoesNotCount() {
        let window = ViewSnapshot(
            frame: rect(0, 0, 390, 844),
            kind: .container,
            children: [
                ViewSnapshot(frame: rect(0, 0, 100, 20), kind: .text, isHidden: true),
                ViewSnapshot(frame: rect(0, 30, 100, 50), kind: .text, alpha: 0),
                ViewSnapshot(frame: rect(0, 60, 100, 80), kind: .text),
            ]
        )
        XCTAssertEqual(SkeletonBuilder.contentCount(window), 1)
    }

    // MARK: - contentSignature

    /// The React Native push, reduced to one assertion.
    ///
    /// A host-reported screen is named when the slide *starts*, and for the length of the slide both
    /// screens are in the tree — nothing joins, nothing leaves, everything moves. A count-based settle
    /// called that stable and photographed the middle of the animation: the stored wireframe of `List`
    /// had its rows squeezed into the right half of the frame. Movement must read as change.
    func testMovementChangesTheSignatureThoughTheCountHolds() {
        let sliding = ViewSnapshot(
            frame: rect(0, 0, 390, 844),
            kind: .container,
            children: [ViewSnapshot(frame: rect(200, 60, 380, 90), kind: .text)]
        )
        var landed = sliding
        landed.children[0].frame = rect(16, 60, 196, 90)

        let before = SkeletonBuilder.contentSignature(sliding)
        let after = SkeletonBuilder.contentSignature(landed)
        XCTAssertEqual(before.count, after.count, "the slide adds and removes nothing")
        XCTAssertNotEqual(before, after, "a moved view is a screen that has not settled")
    }

    /// The other direction: presented geometry carries sub-pixel noise even at rest, and a signature
    /// that never repeats never settles. Whole points are the identity.
    func testSubPixelJitterDoesNotChangeTheSignature() {
        let atRest = ViewSnapshot(
            frame: rect(0, 0, 390, 844),
            kind: .container,
            children: [ViewSnapshot(frame: rect(16, 60, 300, 90), kind: .text)]
        )
        var jittered = atRest
        jittered.children[0].frame = rect(16.2, 59.9, 300.1, 90.2)

        XCTAssertEqual(
            SkeletonBuilder.contentSignature(atRest),
            SkeletonBuilder.contentSignature(jittered)
        )
    }

    /// A container's own frame animates during a push while its children's window-space frames carry
    /// the movement. The container contributes nothing directly — same rule as the count — so this
    /// pins that its children are still walked.
    func testGeometryIsReadThroughContainers() {
        let tree = ViewSnapshot(
            frame: rect(0, 0, 390, 844),
            kind: .container,
            children: [
                ViewSnapshot(
                    frame: rect(0, 0, 390, 844),
                    kind: .container,
                    children: [ViewSnapshot(frame: rect(16, 60, 300, 90), kind: .text)]
                )
            ]
        )
        var moved = tree
        moved.children[0].children[0].frame = rect(116, 60, 400, 90)

        XCTAssertNotEqual(
            SkeletonBuilder.contentSignature(tree),
            SkeletonBuilder.contentSignature(moved)
        )
    }

    func testHiddenContentHasNoGeometryEither() {
        let shown = ViewSnapshot(
            frame: rect(0, 0, 390, 844),
            kind: .container,
            children: [
                ViewSnapshot(frame: rect(0, 60, 100, 80), kind: .text),
                ViewSnapshot(frame: rect(0, 0, 100, 20), kind: .text, isHidden: true),
            ]
        )
        var hiddenMoved = shown
        hiddenMoved.children[1].frame = rect(50, 0, 150, 20)

        XCTAssertEqual(
            SkeletonBuilder.contentSignature(shown),
            SkeletonBuilder.contentSignature(hiddenMoved),
            "what is not drawn cannot be mid-animation"
        )
    }

    // MARK: - build

    func testFrameDimensionsAreInPixels() {
        let root = ViewSnapshot(frame: rect(0, 0, 390, 844), kind: .container)
        let frame = SkeletonBuilder.build(root: root, scale: 3, background: nil)
        XCTAssertEqual(frame?.width, 1170)
        XCTAssertEqual(frame?.height, 2532)
    }

    func testEmptyRootProducesNothing() {
        let root = ViewSnapshot(frame: rect(0, 0, 0, 0), kind: .container)
        XCTAssertNil(SkeletonBuilder.build(root: root, scale: 3, background: nil))
    }

    func testNodesAreEmittedParentBeforeChild() {
        let root = ViewSnapshot(
            frame: rect(0, 0, 100, 100),
            kind: .container,
            color: opaqueGrey,
            children: [ViewSnapshot(frame: rect(10, 10, 90, 90), kind: .text)]
        )
        let nodes = SkeletonBuilder.build(root: root, scale: 1, background: nil)?.nodes ?? []
        XCTAssertEqual(nodes.map(\.kind), [.container, .text], "painting order is the only thing the flat list carries")
    }

    /// A container with no background of its own is not drawn.
    ///
    /// Emitting every one would bury the screen in nested outlines — a real screen is twenty layers of
    /// stack views deep, and none of those layers is something the user saw.
    func testInvisibleContainersAreNotEmitted() {
        let root = ViewSnapshot(
            frame: rect(0, 0, 100, 100),
            kind: .container,
            children: [
                ViewSnapshot(frame: rect(0, 0, 100, 100), kind: .container, children: [
                    ViewSnapshot(frame: rect(10, 10, 90, 40), kind: .text)
                ])
            ]
        )
        let nodes = SkeletonBuilder.build(root: root, scale: 1, background: nil)?.nodes ?? []
        XCTAssertEqual(nodes.map(\.kind), [.text])
    }

    func testContainersStrokeAndContentFills() {
        let root = ViewSnapshot(
            frame: rect(0, 0, 100, 100),
            kind: .container,
            color: opaqueGrey,
            children: [ViewSnapshot(frame: rect(0, 0, 50, 50), kind: .image)]
        )
        let nodes = SkeletonBuilder.build(root: root, scale: 1, background: nil)?.nodes ?? []
        XCTAssertEqual(nodes.first?.stroke, true)
        XCTAssertEqual(nodes.last?.stroke, false)
    }

    /// The four grey slabs that were a four-field form.
    ///
    /// SwiftUI draws a bordered field as a fill and then a rounded-rect *stroke* on top, the stroke
    /// being a layer with no background colour and a border. Emitted as a rectangle that draws, it was
    /// a solid block the size of the field, painted after it. The rendered wireframe of the sheet had
    /// four grey blocks and not one orange input, and the grey came to exactly four times 1114×160.
    func testABorderOnlyNodeStrokesInsteadOfFilling() {
        let root = ViewSnapshot(
            frame: rect(0, 0, 100, 100),
            kind: .unknown,
            color: opaqueGrey,
            drawsBorderOnly: true
        )
        let nodes = SkeletonBuilder.build(root: root, scale: 1, background: nil)?.nodes ?? []
        XCTAssertEqual(nodes.first?.stroke, true)
    }

    /// The other half of the same fix: an outline hides nothing.
    ///
    /// A border-only node carries the border's colour, since it has no other. Without this, the rule
    /// that discards what an opaque rectangle covers would read a field's edge as a solid cover and
    /// delete the field it is drawn around — the same content, lost a different way.
    func testABorderOnlyNodeIsNotAnOpaqueCover() {
        let outline = ViewSnapshot(
            frame: rect(0, 0, 100, 100),
            kind: .unknown,
            color: opaqueGrey,
            declaresOpaque: true,
            drawsBorderOnly: true
        )
        XCTAssertFalse(CoveredContent.isOpaqueCover(outline))

        var filled = outline
        filled.drawsBorderOnly = false
        XCTAssertTrue(CoveredContent.isOpaqueCover(filled), "a filled one still covers")
    }

    /// Content laid out past the window is not on screen.
    func testChildrenAreClippedToTheWindow() {
        let root = ViewSnapshot(
            frame: rect(0, 0, 100, 100),
            kind: .container,
            children: [ViewSnapshot(frame: rect(50, 50, 500, 500), kind: .image)]
        )
        let nodes = SkeletonBuilder.build(root: root, scale: 1, background: nil)?.nodes ?? []
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].right, 100)
        XCTAssertEqual(nodes[0].bottom, 100)
    }

    func testChildOutsideTheWindowIsDropped() {
        let root = ViewSnapshot(
            frame: rect(0, 0, 100, 100),
            kind: .container,
            children: [ViewSnapshot(frame: rect(200, 200, 300, 300), kind: .image)]
        )
        XCTAssertEqual(SkeletonBuilder.build(root: root, scale: 1, background: nil)?.nodes.count, 0)
    }

    /// A view that does not clip really does let its children draw outside it — a badge on a tab bar,
    /// a shadow, a popover arrow. Trimming them anyway erases parts of the screen that are visibly
    /// there, so the clip only tightens when the view says it clips.
    func testNonClippingParentDoesNotTrimItsChildren() {
        // The parent sits inset from the window, so "trimmed by the parent" and "trimmed by the
        // window" are different numbers. With the parent at the window's own origin they coincide,
        // which is how the first version of this test asserted a passing implementation was broken.
        let overflowing = ViewSnapshot(frame: rect(10, 10, 90, 90), kind: .image)
        func parent(clips: Bool) -> ViewSnapshot {
            ViewSnapshot(
                frame: rect(20, 20, 60, 60),
                kind: .container,
                clipsToBounds: clips,
                children: [overflowing]
            )
        }
        func rooted(_ child: ViewSnapshot) -> ViewSnapshot {
            ViewSnapshot(frame: rect(0, 0, 100, 100), kind: .container, children: [child])
        }

        let loose = SkeletonBuilder.build(root: rooted(parent(clips: false)), scale: 1, background: nil)?.nodes ?? []
        XCTAssertEqual(loose.first?.left, 10, "a non-clipping parent must not trim its child")
        XCTAssertEqual(loose.first?.right, 90)

        let tight = SkeletonBuilder.build(root: rooted(parent(clips: true)), scale: 1, background: nil)?.nodes ?? []
        XCTAssertEqual(tight.first?.left, 20, "a clipping parent must trim its child")
        XCTAssertEqual(tight.first?.right, 60)
    }

    /// Hairline separators are 0.33 points on a 3× screen. Rounding their edges to the nearest pixel
    /// collapses them, and a wireframe that loses its dividers reads as a different screen.
    func testHairlinesSurviveTheConversionToPixels() {
        let root = ViewSnapshot(
            frame: rect(0, 0, 100, 100),
            kind: .container,
            children: [ViewSnapshot(frame: rect(0, 50, 100, 50.33), kind: .unknown, color: opaqueGrey)]
        )
        let nodes = SkeletonBuilder.build(root: root, scale: 3, background: nil)?.nodes ?? []
        XCTAssertEqual(nodes.count, 1)
        XCTAssertGreaterThan(nodes[0].bottom - nodes[0].top, 0, "a hairline must not round away to nothing")
    }

    func testNodeCountIsCapped() {
        let many = (0..<(SkeletonBuilder.maxNodes + 500)).map {
            ViewSnapshot(frame: rect(0, Double($0), 10, Double($0) + 1), kind: .text)
        }
        let root = ViewSnapshot(frame: rect(0, 0, 100, 100_000), kind: .container, children: many)
        let nodes = SkeletonBuilder.build(root: root, scale: 1, background: nil)?.nodes ?? []
        XCTAssertEqual(nodes.count, SkeletonBuilder.maxNodes)
    }

    // MARK: - Wire encoding

    func testColourHexUsesAlphaFirst() {
        XCTAssertEqual(skeletonColorHex(red: 1, green: 0, blue: 0, alpha: 1), "#FF0000")
        // Alpha leads, which is Android's order and not CSS's `#RRGGBBAA`. Reading one as the other
        // swaps a colour's alpha with its red.
        XCTAssertEqual(skeletonColorHex(red: 1, green: 0, blue: 0, alpha: 0.5), "#80FF0000")
    }

    func testColourComponentsOutsideZeroToOneAreClamped() {
        // A colour in an extended-range space legitimately reports components past 1.
        XCTAssertEqual(skeletonColorHex(red: 1.4, green: -0.2, blue: 0, alpha: 1), "#FF0000")
    }

    func testJsonOmitsWhatTheServerDefaults() {
        let node = SkeletonNode(left: 1, top: 2, right: 3, bottom: 4, kind: .text)
        let json = node.jsonObject
        XCTAssertNil(json["stroke"], "false is the server's default; sending it is bytes per view per screen")
        XCTAssertNil(json["color"])
        XCTAssertEqual(json["kind"] as? String, "TEXT")
    }

    func testJsonIsSerialisableAndUsesTheServersKeys() throws {
        let frame = SkeletonFrame(
            width: 10,
            height: 20,
            background: "#FFFFFF",
            nodes: [SkeletonNode(left: 0, top: 0, right: 5, bottom: 5, kind: .container, stroke: true)]
        )
        let data = try JSONSerialization.data(withJSONObject: frame.jsonObject)
        let back = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(back["width"] as? Int, 10)
        XCTAssertEqual(back["background"] as? String, "#FFFFFF")
        let nodes = try XCTUnwrap(back["nodes"] as? [[String: Any]])
        XCTAssertEqual(nodes[0]["l"] as? Int, 0)
        XCTAssertEqual(nodes[0]["stroke"] as? Bool, true)
    }
}

/// Which views carry a colour on the wire.
///
/// Measured before it was written: the first real wireframe had three text fields in the app's own pale
/// grey next to a label in the palette's green, so the picture said nothing about which was which.
final class SkeletonColourTests: XCTestCase {

    private func rect(_ l: Double, _ t: Double, _ r: Double, _ b: Double) -> Rect {
        Rect(left: l, top: t, right: r, bottom: b)
    }
    private let appColour = Color(red: 0.9, green: 0.9, blue: 0.95, alpha: 1)

    func testClassifiedViewsLetTheServerPaletteSpeak() {
        for kind in [NodeKind.text, .input, .image, .button, .webView, .card] {
            let root = ViewSnapshot(
                frame: rect(0, 0, 100, 100),
                kind: .container,
                children: [ViewSnapshot(frame: rect(0, 0, 50, 20), kind: kind, color: appColour)]
            )
            let node = SkeletonBuilder.build(root: root, scale: 1, background: nil)?.nodes.first
            XCTAssertNil(node?.color, "\(kind) must not override the palette that encodes its kind")
        }
    }

    /// The two kinds whose colour is the only thing known about them.
    func testContainersAndUnknownsKeepTheirOwnColour() {
        for kind in [NodeKind.container, .unknown] {
            let root = ViewSnapshot(
                frame: rect(0, 0, 100, 100),
                kind: .container,
                children: [ViewSnapshot(frame: rect(0, 0, 50, 20), kind: kind, color: appColour)]
            )
            let node = SkeletonBuilder.build(root: root, scale: 1, background: nil)?.nodes.first
            XCTAssertEqual(node?.color, appColour.hex, "\(kind) carries no information except its colour")
        }
    }
}

/// What is drawn inside a recognised widget.
///
/// Measured, and only visible by looking at the picture: a `UITextField` places its own rounded-rect
/// background view on top of itself. That view is a plain `UIView` with a colour, so it was drawn as an
/// `UNKNOWN` in the app's grey — exactly covering the orange input beneath it. Three fields came out as
/// three grey slabs, and the PNG was byte-identical to the one from before the fix meant to change it.
final class WidgetChromeTests: XCTestCase {

    private func rect(_ l: Double, _ t: Double, _ r: Double, _ b: Double) -> Rect {
        Rect(left: l, top: t, right: r, bottom: b)
    }
    private let grey = Color(red: 0.9, green: 0.9, blue: 0.95, alpha: 1)

    private func field() -> ViewSnapshot {
        ViewSnapshot(
            frame: rect(0, 0, 100, 30),
            kind: .input,
            children: [
                // What UIKit puts inside a rounded-rect text field.
                ViewSnapshot(frame: rect(0, 0, 100, 30), kind: .unknown, color: grey),
            ]
        )
    }

    func testAWidgetsOwnChromeIsNotDrawnOverIt() {
        let root = ViewSnapshot(frame: rect(0, 0, 100, 100), kind: .container, children: [field()])
        let nodes = SkeletonBuilder.build(root: root, scale: 1, background: nil)?.nodes ?? []
        XCTAssertEqual(nodes.map(\.kind), [.input], "the field describes its own area; its backing view does not")
    }

    /// Still walked for real content: a label inside a button is text the user read.
    func testContentInsideAWidgetIsStillDrawn() {
        let button = ViewSnapshot(
            frame: rect(0, 0, 100, 40),
            kind: .button,
            children: [
                ViewSnapshot(frame: rect(0, 0, 100, 40), kind: .container, color: grey),
                ViewSnapshot(frame: rect(10, 10, 90, 30), kind: .text),
            ]
        )
        let root = ViewSnapshot(frame: rect(0, 0, 100, 100), kind: .container, children: [button])
        let nodes = SkeletonBuilder.build(root: root, scale: 1, background: nil)?.nodes ?? []
        XCTAssertEqual(nodes.map(\.kind), [.button, .text])
    }

    /// A plain coloured view that is *not* inside a widget is still content — a splash screen is nothing
    /// else, and this is the rule Android broke to lose a screen's wireframe entirely.
    func testAPlainColouredViewOutsideAWidgetIsStillDrawn() {
        let root = ViewSnapshot(
            frame: rect(0, 0, 100, 100),
            kind: .container,
            children: [ViewSnapshot(frame: rect(0, 0, 100, 100), kind: .unknown, color: grey)]
        )
        let nodes = SkeletonBuilder.build(root: root, scale: 1, background: nil)?.nodes ?? []
        XCTAssertEqual(nodes.map(\.kind), [.unknown])
    }
}

/// The late-content watch's question: "did content arrive, or did the screen merely redraw".
///
/// Geometry and kind only — recolouring samples the live screen, so colour can waver between two
/// captures of an identical layout, and a colour-only wobble resent on the watch path would spend
/// its budget photographing noise.
final class SameGeometryTests: XCTestCase {

    private func frame(_ nodes: [SkeletonNode]) -> SkeletonFrame {
        SkeletonFrame(width: 100, height: 200, background: nil, nodes: nodes)
    }

    private func node(
        _ left: Int, _ top: Int, _ right: Int, _ bottom: Int,
        kind: NodeKind = .text, color: String? = nil, stroke: Bool = false
    ) -> SkeletonNode {
        SkeletonNode(left: left, top: top, right: right, bottom: bottom,
                     kind: kind, color: color, stroke: stroke)
    }

    func testIdenticalLayoutsMatch() {
        let a = frame([node(0, 0, 10, 10), node(0, 20, 10, 30, kind: .button)])
        let b = frame([node(0, 0, 10, 10), node(0, 20, 10, 30, kind: .button)])
        XCTAssertTrue(SkeletonBuilder.sameGeometry(a, b))
    }

    func testColourIsIgnored() {
        let a = frame([node(0, 0, 10, 10, color: "#FF0000")])
        let b = frame([node(0, 0, 10, 10, color: "#00FF00")])
        XCTAssertTrue(
            SkeletonBuilder.sameGeometry(a, b),
            "a highlight fading between two captures is not content arriving"
        )
    }

    func testStrokeIsIgnored() {
        let a = frame([node(0, 0, 10, 10, stroke: true)])
        let b = frame([node(0, 0, 10, 10, stroke: false)])
        XCTAssertTrue(SkeletonBuilder.sameGeometry(a, b))
    }

    func testAMovedRectangleIsAChange() {
        let a = frame([node(0, 0, 10, 10)])
        let b = frame([node(0, 5, 10, 15)])
        XCTAssertFalse(SkeletonBuilder.sameGeometry(a, b))
    }

    func testADifferentKindIsAChange() {
        let a = frame([node(0, 0, 10, 10, kind: .text)])
        let b = frame([node(0, 0, 10, 10, kind: .image)])
        XCTAssertFalse(SkeletonBuilder.sameGeometry(a, b))
    }

    func testADifferentCountIsAChange() {
        let a = frame([node(0, 0, 10, 10)])
        let b = frame([node(0, 0, 10, 10), node(0, 20, 10, 30)])
        XCTAssertFalse(SkeletonBuilder.sameGeometry(a, b))
    }

    func testOrderMatters() {
        // Nodes are emitted in paint order; the same rectangles in a different order paint
        // differently, and that is a change worth resending.
        let a = frame([node(0, 0, 10, 10, kind: .text), node(20, 0, 30, 10, kind: .image)])
        let b = frame([node(20, 0, 30, 10, kind: .image), node(0, 0, 10, 10, kind: .text)])
        XCTAssertFalse(SkeletonBuilder.sameGeometry(a, b))
    }
}

/// Corners: read from what the app declared, carried to the wire, dropped when they would lie.
final class CornerRadiusTests: XCTestCase {

    private func rect(_ l: Double, _ t: Double, _ r: Double, _ b: Double) -> Rect {
        Rect(left: l, top: t, right: r, bottom: b)
    }

    func testARoundedNodeCarriesItsRadiiInPixels() {
        let root = ViewSnapshot(
            frame: rect(0, 0, 100, 100),
            kind: .container,
            children: [
                ViewSnapshot(
                    frame: rect(10, 10, 90, 60),
                    kind: .card,
                    color: Color(red: 0.5, green: 0.5, blue: 0.5, alpha: 1),
                    cornerRadii: [8, 8, 0, 0]
                )
            ]
        )
        let nodes = SkeletonBuilder.build(root: root, scale: 2, background: nil)?.nodes ?? []
        let card = nodes.first { $0.kind == .card }
        XCTAssertEqual(card?.cornerRadii, [16, 16, 0, 0], "points become device pixels, like every other measure")
    }

    func testASquareNodeSendsNothing() {
        let root = ViewSnapshot(
            frame: rect(0, 0, 100, 100),
            kind: .container,
            children: [ViewSnapshot(frame: rect(0, 0, 50, 50), kind: .text)]
        )
        let nodes = SkeletonBuilder.build(root: root, scale: 1, background: nil)?.nodes ?? []
        XCTAssertNil(
            nodes.first { $0.kind == .text }?.cornerRadii,
            "absent means square, and square is the common case"
        )
    }

    /// A node trimmed by a clipping ancestor is a piece of the app's shape, with edges the app
    /// never rounded. Rounding the offcut would carve a curve out of the middle of the screen.
    func testAClippedNodeLosesItsRadii() {
        let root = ViewSnapshot(
            frame: rect(0, 0, 100, 50),
            kind: .container,
            clipsToBounds: true,
            children: [
                ViewSnapshot(
                    frame: rect(0, 0, 100, 200),
                    kind: .card,
                    color: Color(red: 0.5, green: 0.5, blue: 0.5, alpha: 1),
                    cornerRadii: [12, 12, 12, 12]
                )
            ]
        )
        let nodes = SkeletonBuilder.build(root: root, scale: 1, background: nil)?.nodes ?? []
        XCTAssertNil(nodes.first { $0.kind == .card }?.cornerRadii)
    }

    func testTheWireOmitsRadUnlessThereAreCorners() {
        let square = SkeletonNode(left: 0, top: 0, right: 10, bottom: 10, kind: .text)
        XCTAssertNil(square.jsonObject["rad"])

        let round = SkeletonNode(
            left: 0, top: 0, right: 10, bottom: 10, kind: .card, cornerRadii: [4, 4, 0, 0]
        )
        XCTAssertEqual(round.jsonObject["rad"] as? [Int], [4, 4, 0, 0], "the name the server reads")
    }
}
