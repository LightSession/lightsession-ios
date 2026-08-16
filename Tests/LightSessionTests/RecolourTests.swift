import XCTest
@testable import LightSession

/// That a wireframe painted from the screen is both truthful and unable to say too much.
///
/// A port of the Android SDK's `RecolourTest`, case for case. The two platforms feed one screen map with
/// the same constants, and the only way to know they still agree is to ask them the same questions — a
/// drift in `dominance` or in the bucket arithmetic would otherwise show up as one platform's wireframes
/// looking subtly different from the other's, which is exactly the kind of thing nobody files a bug for.
///
/// Runs without a device because the sampling works on a pixel array, not a bitmap. Needing a simulator
/// to test a weighted average would have meant not testing it.
final class RecolourTests: XCTestCase {

    private let width = 200
    private let height = 400

    private let white: UInt32 = 0xFFFFFF
    private let card: UInt32 = 0xF2F4F7
    private let ink: UInt32 = 0x1A1A1A

    /// A frame of `width`×`height` pixels, painted by a closure given (x, y).
    private func pixels(_ paint: (Int, Int) -> UInt32) -> ArrayPixels {
        ArrayPixels(
            width: width,
            height: height,
            pixels: (0..<(width * height)).map { paint($0 % width, $0 / width) }
        )
    }

    private func frame(_ nodes: SkeletonNode...) -> SkeletonFrame {
        SkeletonFrame(width: width, height: height, background: "#FFFFFF", nodes: nodes)
    }

    private func node(
        _ left: Int, _ top: Int, _ right: Int, _ bottom: Int,
        kind: NodeKind = .text,
        stroke: Bool = false
    ) -> SkeletonNode {
        SkeletonNode(
            left: left, top: top, right: right, bottom: bottom,
            kind: kind, color: paletteGreen, stroke: stroke
        )
    }

    private let paletteGreen = "#4CAF50"

    /// The channels of a `#RRGGBB`, so an assertion can talk about one of them.
    private func channels(_ hex: String) -> (Int, Int, Int) {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
    }

    func testAFlatSurfaceComesBackAsItself() {
        let flat = pixels { _, _ in card }
        let out = Recolour.apply(frame(node(10, 10, 190, 200)), sampling: flat, maskingOn: false)

        // Quantised to 32 levels per channel, so within 8 of the original.
        let colour = try! XCTUnwrap(out.nodes.first?.color)
        let (red, green, blue) = channels(colour)
        XCTAssertEqual(red, 0xF2, accuracy: 8, "got \(colour)")
        XCTAssertEqual(green, 0xF4, accuracy: 8, "got \(colour)")
        XCTAssertEqual(blue, 0xF7, accuracy: 8, "got \(colour)")
    }

    /// The measurement the dominant-colour rule came from.
    ///
    /// Over a real card with text, the mean gave `#BFC1C3` — a grey belonging to neither the paper nor
    /// the ink — while the most common colour gave the card. Most of a text block is background.
    func testTextOnACardTakesTheCardsColourNotAGreyBetweenThem() {
        // Eight lines of ink, each 8px of every 40 — about a fifth of the block.
        let withText = pixels { _, y in y % 40 < 8 ? ink : card }
        let colour = try! XCTUnwrap(
            Recolour.apply(frame(node(0, 0, width, height)), sampling: withText, maskingOn: false).nodes.first?.color
        )
        let (red, green, blue) = channels(colour)
        XCTAssertTrue(
            red > 0xE0 && green > 0xE0 && blue > 0xE0,
            "the paper, not a smear: got \(colour)"
        )
    }

    /// No colour dominates a ramp, and the widest band of one is a few percent — so the most common
    /// colour would be whichever narrow stripe happened to win. The mean is the honest answer for
    /// something that has no single colour.
    func testAGradientFallsThroughToItsAverage() {
        let ramp = pixels { x, _ in
            let red = UInt32(x * 255 / width)
            return (red << 16) | (90 << 8) | (255 - red)
        }
        let colour = try! XCTUnwrap(
            Recolour.apply(frame(node(0, 0, width, height)), sampling: ramp, maskingOn: false).nodes.first?.color
        )
        let (red, green, blue) = channels(colour)
        XCTAssertTrue((88...92).contains(green), "green is flat across the ramp: got \(colour)")
        XCTAssertTrue((100...155).contains(red), "red should sit mid-ramp: got \(colour)")
        XCTAssertTrue((100...155).contains(blue), "blue should sit mid-ramp: got \(colour)")
    }

    /// A container is structure. Sampling its whole area would average its children and paint the border
    /// a colour belonging to none of them.
    func testAnOutlineKeepsItsPaletteColour() {
        let mixed = pixels { x, _ in x < width / 2 ? ink : white }
        let out = Recolour.apply(frame(node(0, 0, width, height, kind: .container, stroke: true)),
            sampling: mixed, maskingOn: false)
        XCTAssertEqual(out.nodes.first?.color, paletteGreen)
    }

    /// A capture taken at half scale is half the size of the geometry describing it. Getting this wrong
    /// colours the wireframe from the wrong parts of the screen and nothing says so.
    func testGeometryAndPixelsNeedNotBeTheSameSize() {
        let half = 2
        let small = ArrayPixels(
            width: width / half,
            height: height / half,
            pixels: (0..<((width / half) * (height / half))).map { index in
                // Left half of the *bitmap* is ink, so the left half of the frame must be too.
                index % (width / half) < width / half / 2 ? ink : card
            }
        )
        let out = Recolour.apply(frame(node(0, 0, width / 2, height), node(width / 2, 0, width, height)),
            sampling: small, maskingOn: false)
        XCTAssertLessThan(channels(out.nodes[0].color ?? "#FFFFFF").0, 0x40, "left half should be ink")
        XCTAssertGreaterThan(channels(out.nodes[1].color ?? "#000000").0, 0xE0, "right half should be card")
    }

    /// 2px tall, where the stride is 4.
    func testAHairlineThinnerThanTheStrideIsStillSampled() {
        let solid = pixels { _, _ in ink }
        let colour = try! XCTUnwrap(
            Recolour.apply(frame(node(0, 100, width, 102)), sampling: solid, maskingOn: false).nodes.first?.color
        )
        XCTAssertNotEqual(colour, paletteGreen, "must not fall back to the palette")
        XCTAssertLessThan(channels(colour).0, 0x40)
    }

    /// Wholly outside, and partially outside. Neither may read past the buffer.
    func testANodeOffTheEdgeClampsSafely() {
        let flat = pixels { _, _ in card }
        let out = Recolour.apply(frame(
                node(width + 50, height + 50, width + 100, height + 100),
                node(width - 10, height - 10, width + 100, height + 100)
            ),
            sampling: flat, maskingOn: false)
        // Whatever it answers, it answers — the assertion is that it returned at all rather than
        // reading off the end of the array.
        XCTAssertEqual(out.nodes.count, 2)
    }

    /// The tripwire that the privacy argument rests on.
    ///
    /// One colour for a paragraph is the colour of the paper. One colour per letter would spell the
    /// paragraph out in a mosaic, and nothing about the sampling would have changed — only what it was
    /// asked about. So the shape of the payload is what gets defended.
    func testGlyphSizedNodesAreCounted() {
        let tiny = frame(
            node(0, 0, 8, 8),
            node(0, 0, 8, 8),
            node(0, 0, width, height)
        )
        XCTAssertEqual(Recolour.glyphSizedNodes(in: tiny), 2)

        // A stroke is an outline, never sampled, so it is not part of the risk.
        let outlined = frame(node(0, 0, 8, 8, kind: .container, stroke: true))
        XCTAssertEqual(Recolour.glyphSizedNodes(in: outlined), 0)
    }

    /// A node that is thin on one axis only is a divider, not a character.
    func testAThinDividerIsNotGlyphSized() {
        XCTAssertEqual(Recolour.glyphSizedNodes(in: frame(node(0, 0, width, 2))), 0)
    }

    /// The constants the two platforms share. If one moves, the wireframes stop matching across a graph
    /// and the only symptom is that they look slightly different.
    func testTheConstantsMatchTheAndroidSdk() {
        XCTAssertEqual(Recolour.stride, 4)
        XCTAssertEqual(Recolour.dominance, 0.4)
        XCTAssertEqual(Recolour.minimumSafeSide, 12)
    }
}

/// The mask is ours, not the app's.
///
/// A port of the Android rule with the same shape of evidence behind it: an alert whose material is
/// mostly masked text adopted the mask's grey as its surface, and its own labels sat on it in the
/// same grey — one slab, no words. A node that *contains* redacted text is not grey; it contains
/// somebody else's redaction.
final class MaskPaintRuleTests: XCTestCase {

    private let width = 200
    private let height = 400

    private func pixels(_ value: UInt32) -> ArrayPixels {
        ArrayPixels(
            width: width,
            height: height,
            pixels: [UInt32](repeating: value, count: width * height)
        )
    }

    private func frame(_ nodes: SkeletonNode...) -> SkeletonFrame {
        SkeletonFrame(width: width, height: height, background: nil, nodes: nodes)
    }

    private func node(kind: NodeKind) -> SkeletonNode {
        SkeletonNode(left: 0, top: 0, right: 200, bottom: 400, kind: kind, color: "#4CAF50")
    }

    /// systemGray3's two variants, as pixels the sampler will read.
    private let maskLight: UInt32 = 0xC7C7CC  // (199, 199, 204)
    private let maskDark: UInt32 = 0x48484A   // (72, 72, 74)

    func testASurfaceThatSampledTheMaskKeepsItsOwnColour() {
        for mask in [maskLight, maskDark] {
            let out = Recolour.apply(
                frame(node(kind: .unknown)), sampling: pixels(mask), maskingOn: true
            )
            XCTAssertEqual(
                out.nodes.first?.color, "#4CAF50",
                "a container of redacted text is not grey; the sampled mask must not become a surface"
            )
        }
    }

    func testTextIsAllowedToBeTheMaskGrey() {
        let out = Recolour.apply(
            frame(node(kind: .text)), sampling: pixels(maskLight), maskingOn: true
        )
        XCTAssertNotEqual(
            out.nodes.first?.color, "#4CAF50",
            "grey is honestly what the screen shows where the masked thing itself is"
        )
    }

    func testWithMaskingOffAGenuinelyGreyCardStaysGrey() {
        let out = Recolour.apply(
            frame(node(kind: .unknown)), sampling: pixels(maskDark), maskingOn: false
        )
        XCTAssertNotEqual(
            out.nodes.first?.color, "#4CAF50",
            "with masking off nothing paints that grey but the app itself"
        )
    }

    /// The regression the alert found: recolouring rebuilt nodes without their corners.
    func testRecolouringKeepsTheCorners() {
        let rounded = SkeletonNode(
            left: 10, top: 10, right: 100, bottom: 100,
            kind: .card, color: nil, cornerRadii: [12, 12, 0, 0]
        )
        let out = Recolour.apply(
            SkeletonFrame(width: width, height: height, background: nil, nodes: [rounded]),
            sampling: pixels(0xF2F4F7),
            maskingOn: true
        )
        XCTAssertEqual(
            out.nodes.first?.cornerRadii, [12, 12, 0, 0],
            "recolouring has an opinion about colour and none about corners"
        )
    }
}

/// The scrim rule, confined to overlays.
final class ScrimRuleTests: XCTestCase {

    private func fill(_ kind: NodeKind, w: Int = 1206, h: Int = 2622) -> SkeletonNode {
        SkeletonNode(left: 0, top: 0, right: w, bottom: h, kind: kind)
    }

    func testAnOverlayDropsItsFullFrameFill() {
        let root = ViewSnapshot(
            frame: Rect(left: 0, top: 0, right: 100, bottom: 200),
            kind: .container,
            children: [
                // The scrim: a plain coloured view the size of everything.
                ViewSnapshot(
                    frame: Rect(left: 0, top: 0, right: 100, bottom: 200),
                    kind: .unknown,
                    color: Color(red: 0, green: 0, blue: 0, alpha: 0.4)
                ),
                ViewSnapshot(frame: Rect(left: 20, top: 80, right: 80, bottom: 120), kind: .text),
            ]
        )
        let overlay = SkeletonBuilder.build(root: root, scale: 1, background: nil, overlay: true)
        XCTAssertEqual(
            overlay?.nodes.filter { $0.kind == .unknown && !$0.stroke }.count, 0,
            "on an overlay a full-frame fill is the previous screen being dimmed, not the modal"
        )
        XCTAssertEqual(overlay?.nodes.filter { $0.kind == .text }.count, 1, "the modal's own text stays")

        let ordinary = SkeletonBuilder.build(root: root, scale: 1, background: nil, overlay: false)
        XCTAssertEqual(
            ordinary?.nodes.filter { $0.kind == .unknown && !$0.stroke }.count, 1,
            "on an ordinary screen a full-frame fill is usually the page's own background"
        )
    }

    func testAFullScreenImageIsContentNotChrome() {
        XCTAssertFalse(
            SkeletonBuilder.isFullFrameFill(fill(.image), width: 1206, height: 2622),
            "a photo viewer is a full-screen image on purpose"
        )
        XCTAssertTrue(SkeletonBuilder.isFullFrameFill(fill(.unknown), width: 1206, height: 2622))
    }

    func testContainsFullFrameFillSeesTheScrim() {
        let with = SkeletonFrame(
            width: 1206, height: 2622, background: nil,
            nodes: [fill(.unknown), fill(.text, w: 300, h: 60)]
        )
        let without = SkeletonFrame(
            width: 1206, height: 2622, background: nil,
            nodes: [fill(.text, w: 300, h: 60)]
        )
        XCTAssertTrue(SkeletonBuilder.containsFullFrameFill(with))
        XCTAssertFalse(
            SkeletonBuilder.containsFullFrameFill(without),
            "the watch uses this to tell content arriving apart from something opening on top"
        )
    }
}
