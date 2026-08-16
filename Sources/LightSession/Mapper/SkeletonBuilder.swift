import Foundation

/// What a window is showing, reduced to two facts: how much is drawn, and where.
///
/// `Equatable` is the API. The settle detector keeps the previous one and asks whether anything
/// changed — a new view arriving changes `count`, a slide in progress changes `geometry`, and a
/// screen at rest changes neither.
public struct ContentSignature: Equatable, Sendable {
    /// Views that put ink on the screen.
    public let count: Int
    /// A hash of those views' frames, in whole points.
    public let geometry: Int64
}

/// Turns a view hierarchy into the geometry the server draws.
///
/// Pure, and takes a [ViewSnapshot] rather than a `UIView`, so every rule below is stated where a
/// test can reach it. The rules are short and each one is a screen that came out wrong somewhere.
public enum SkeletonBuilder {

    /// Rectangles this will emit before it stops.
    ///
    /// A dense screen produces a few hundred. Ten thousand means a runaway traversal, and the ten
    /// thousandth rectangle is not what makes the wireframe legible. The server enforces its own cap;
    /// this one exists so the device does not build a payload it will be refused for sending.
    public static let maxNodes = 4000

    /// A view smaller than this in either direction is not drawn.
    ///
    /// Hairlines are the reason this is not zero-width-only: iOS is full of 0.33-point separators and
    /// 1-point borders, and they matter to how a screen reads. So the threshold is *below* a hairline
    /// rather than above it — small enough to keep dividers, large enough to drop the degenerate
    /// frames that layout produces mid-pass.
    public static let minSideInPoints: Double = 0.2

    /// The smallest alpha still considered visible.
    public static let minAlpha: Double = 0.05

    /// Builds a frame, or `nil` if the root has no area.
    ///
    /// - Parameters:
    ///   - root: the window's root view, its frame in window coordinates.
    ///   - scale: points to pixels — `UIScreen.scale`. The wire format is pixels because the
    ///     screenshot path is pixels, and one screen must not be two sizes depending on which
    ///     capture arrived first.
    ///   - background: the window's own background, drawn under everything.
    /// - Parameter overlay: this capture is of a modal sub-screen — a dialog, a sheet — and the
    ///   scrim rule applies. See [isFullFrameFill(_:width:height:)] for what it drops and why it is
    ///   confined to overlays.
    public static func build(
        root: ViewSnapshot,
        scale: Double,
        background: Color?,
        overlay: Bool = false
    ) -> SkeletonFrame? {
        guard !root.frame.isEmpty else { return nil }

        var nodes: [SkeletonNode] = []
        nodes.reserveCapacity(64)
        let capture = root.frame.toPixels(scale: scale)
        let captureBounds = Rect(
            left: Double(capture.left), top: Double(capture.top),
            right: Double(capture.right), bottom: Double(capture.bottom)
        )
        // The root's own frame is the clip for everything: a view laid out beyond the window is not on
        // screen, and drawing it would put content outside the wireframe's own bounds.
        collect(node: root, clip: root.frame, scale: scale, insideWidget: false,
                captureBounds: captureBounds, into: &nodes)

        let pixels = root.frame.toPixels(scale: scale)
        let width = pixels.right - pixels.left
        let height = pixels.bottom - pixels.top
        if overlay {
            nodes.removeAll { isFullFrameFill($0, width: width, height: height) }
        }
        return SkeletonFrame(
            width: width,
            height: height,
            background: background?.hex,
            nodes: nodes
        )
    }

    /// A filled node the size of the whole capture, which on an overlay is the scrim.
    ///
    /// Measured on a real alert: the dimming view arrives as a full-window *filled* `UNKNOWN`,
    /// painted after the page's nodes and before the alert's — so the wireframe was the page buried
    /// under a slab, with the alert's own labels invisible on top of it in a near-identical grey.
    /// The scrim is not part of the modal; it is the previous screen being dimmed.
    ///
    /// Confined to overlay captures, exactly as the Android SDK confines it: on an ordinary screen a
    /// full-frame fill is usually the page's own background, which is a real surface and correct to
    /// keep. And confined to kinds that carry no meaning of their own — a full-screen *image* is a
    /// photo viewer, not chrome.
    public static func isFullFrameFill(_ node: SkeletonNode, width: Int, height: Int) -> Bool {
        guard !node.stroke, node.kind == .unknown || node.kind == .container else { return false }
        let area = Double(max(0, node.right - node.left)) * Double(max(0, node.bottom - node.top))
        let whole = Double(width) * Double(height)
        return whole > 0 && area / whole >= 0.98
    }

    /// Whether a frame carries a scrim-shaped node — the sign that a modal was on screen when it
    /// was read. Used by the late-content watch to tell "the content arrived" apart from "something
    /// opened on top", which look identical to a signature and could not be less alike as reasons
    /// to replace a screen's wireframe.
    public static func containsFullFrameFill(_ frame: SkeletonFrame) -> Bool {
        frame.nodes.contains { isFullFrameFill($0, width: frame.width, height: frame.height) }
    }

    /// How many views in this tree actually draw something.
    ///
    /// The settle detector's stop condition. A window is never empty — it has a root view, a safe-area
    /// container, and on iOS a status-bar host — so "does the hierarchy exist" is always true and
    /// useless. This counts leaves that put ink on the screen.
    ///
    /// `UNKNOWN` counts. That is the whole point and it is the exact bug that cost Android a
    /// regression: a plain view with a background colour classifies as `UNKNOWN`, and a splash screen
    /// is made of nothing else. Excluding it meant such a screen was declared empty forever, waited
    /// out its timeout, and uploaded a blank frame.
    public static func contentCount(_ node: ViewSnapshot) -> Int {
        contentSignature(node).count
    }

    /// What is drawn *and where it is* — the settle detector's whole stop condition.
    ///
    /// The count alone is not enough, and the miss was measured, not imagined. During a
    /// react-native-screens push both screens are already in the hierarchy and nothing joins or leaves
    /// for the length of the slide — the views only *move*. A count-based settle held stable three
    /// frames into a 350-millisecond animation and photographed the middle of it: the stored wireframe
    /// of `List` had its rows squeezed into the right half of the frame, with the departing screen
    /// still occupying the left. UIKit-named screens never hit this because their report arrives at
    /// `viewDidAppear`, after the slide; a host-reported screen is named at the *start* of one.
    ///
    /// So the signature folds in each drawing view's frame, rounded to whole points — presented
    /// geometry carries sub-pixel noise even at rest, and a hash that never repeats never settles.
    /// A screen that genuinely never holds still (a spinner) changes its signature every frame and is
    /// caught by the detector's timeout, exactly as before.
    public static func contentSignature(_ node: ViewSnapshot) -> ContentSignature {
        var count = 0
        var geometry: Int64 = 17
        fold(node, into: &count, &geometry)
        return ContentSignature(count: count, geometry: geometry)
    }

    /// Whether two frames draw the same layout — geometry and kind only, colour and stroke ignored.
    ///
    /// This is the late-content watch's question: "did content arrive, or did the screen merely
    /// redraw". Recolouring samples the live screen, so colour can waver between two captures of an
    /// identical layout — a highlight fading, a cursor blinking — and a colour-only wobble is not
    /// content arriving. Resending on it would spend the watch's budget photographing noise.
    ///
    /// Order-sensitive on purpose: nodes are emitted in paint order, and two frames whose rectangles
    /// match as *sets* but not as sequences paint differently.
    public static func sameGeometry(_ a: SkeletonFrame, _ b: SkeletonFrame) -> Bool {
        guard a.nodes.count == b.nodes.count else { return false }
        return zip(a.nodes, b.nodes).allSatisfy { x, y in
            x.left == y.left && x.top == y.top && x.right == y.right
                && x.bottom == y.bottom && x.kind == y.kind
        }
    }

    /// Whether `fresh` is still a picture of the same screen `baseline` was — the test the
    /// late-content watch applies before it replaces one capture with another.
    ///
    /// Late content is **additive**. A list that finishes loading keeps its heading, its search box
    /// and whatever rows it already had, exactly where they were, and gains more below. So a
    /// recapture that grew is only believable as late content if most of what it replaces is still
    /// in it.
    ///
    /// Growth alone is not enough, and trusting it cost a stored capture. A sheet closing over a
    /// busier screen also grows: the screen behind has more rectangles than the sheet did, so
    /// "content arrived" and "the modal left" look identical by count. Measured on a real company
    /// switcher — a correct capture of the sheet, 57 rectangles, was replaced by 89 rectangles of the
    /// list behind it, filed under the sheet's name. Not one of the sheet's rectangles survived into
    /// that recapture, which is the difference this reads.
    ///
    /// Deliberately not a timing rule. The first attempt at this raced the platform — cancel the
    /// watch the moment the modal's controller disappears — and lost in the real app, because
    /// SwiftUI updates its binding after the dismissal and the watch ticks in between. What a capture
    /// *contains* is knowable without knowing when anything happened.
    public static func retainsMostOf(_ baseline: SkeletonFrame, in fresh: SkeletonFrame) -> Bool {
        guard !baseline.nodes.isEmpty else { return true }
        var survivors: Set<Key> = []
        for node in fresh.nodes { survivors.insert(Key(node)) }
        let kept = baseline.nodes.reduce(into: 0) { total, node in
            if survivors.contains(Key(node)) { total += 1 }
        }
        // Half, not all: a screen may legitimately reflow when content lands — a row growing to two
        // lines pushes everything under it — and demanding every rectangle survive would refuse the
        // upgrades this watch exists to make.
        return Double(kept) >= Double(baseline.nodes.count) * 0.5
    }

    /// A node's identity for the comparison above: where it is and what it is, not what colour.
    private struct Key: Hashable {
        let left: Int, top: Int, right: Int, bottom: Int
        let kind: NodeKind

        init(_ node: SkeletonNode) {
            left = node.left
            top = node.top
            right = node.right
            bottom = node.bottom
            kind = node.kind
        }
    }

    private static func fold(_ node: ViewSnapshot, into count: inout Int, _ geometry: inout Int64) {
        guard isVisible(node) else { return }
        switch node.kind {
        case .text, .image, .input, .button, .webView, .card, .unknown:
            count += 1
            for side in [node.frame.left, node.frame.top, node.frame.right, node.frame.bottom] {
                geometry = geometry &* 31 &+ Int64(side.rounded())
            }
        case .container:
            // A container is furniture. Counting it would make every window "settled" immediately —
            // and its movement shows through its children's absolute frames, so it has no geometry of
            // its own to add either.
            break
        }
        for child in node.children {
            fold(child, into: &count, &geometry)
        }
    }

    // MARK: - Internals

    /// What colour to send for a view, and mostly the answer is none.
    ///
    /// A wireframe is readable because kinds are colour-coded — text one colour, fields another — and the
    /// server already has that palette. Sending the app's own colour for a classified view overrides it
    /// with something less informative, and the first measured wireframe showed exactly that: three text
    /// fields came out in the app's pale grey while the label beside them came out in the palette's green,
    /// so nothing in the picture said which was which.
    ///
    /// The exceptions are the two kinds whose colour *is* the only thing known about them. A container is
    /// drawn at all only because it has a background, and an `unknown` is a plain view whose colour is its
    /// entire content — a splash screen, a colour block, a divider.
    private static func wireColor(for node: ViewSnapshot) -> String? {
        switch node.kind {
        case .container, .unknown:
            return node.color?.hex
        case .text, .input, .image, .button, .webView, .card:
            return nil
        }
    }

    private static func isVisible(_ node: ViewSnapshot) -> Bool {
        !node.isHidden
            && node.alpha >= minAlpha
            && node.frame.width >= minSideInPoints
            && node.frame.height >= minSideInPoints
    }

    private static func collect(
        node: ViewSnapshot,
        clip: Rect,
        scale: Double,
        insideWidget: Bool,
        captureBounds: Rect,
        into nodes: inout [SkeletonNode]
    ) {
        guard nodes.count < maxNodes else { return }
        guard isVisible(node) else { return }
        guard let visible = node.frame.clipped(to: clip) else { return }

        // What an opaque view hides is not part of this screen, whoever put it there.
        //
        // The same rule the mask uses, and it is here for the same reason: during a navigation transition both
        // view controllers' views are in the window, so a wireframe of the screen being entered was drawing the
        // rectangles of the screen being left. One rule, two outputs — see `CoveredContent`.
        if CoveredContent.isOpaqueCover(node) {
            let px = visible.toPixels(scale: scale)
            let cover = Rect(
                left: Double(px.left), top: Double(px.top),
                right: Double(px.right), bottom: Double(px.bottom)
            )
            CoveredContent.discardCovered(&nodes, by: cover, captureBounds: captureBounds) { node in
                Rect(
                    left: Double(node.left), top: Double(node.top),
                    right: Double(node.right), bottom: Double(node.bottom)
                )
            }
        }

        // A container is emitted as an outline, and only when it has a background worth showing. An
        // empty container that draws nothing is not a thing the user saw, and filling the screen with
        // nested outlines is how a wireframe becomes unreadable.
        //
        // Inside a widget, neither a container nor an unknown is emitted at all: it is the widget's own
        // chrome, and the widget has already described that area. This was measured, and the picture was
        // the only way to see it — a `UITextField` is drawn on top by its own rounded-rect background
        // view, which is a plain `UIView` with a colour. The field underneath was correctly an input and
        // completely invisible, so the wireframe showed three grey slabs where three fields were, and the
        // rendered PNG was byte-identical to the version before the fix that was supposed to change it.
        let emits: Bool
        switch node.kind {
        case .container:
            emits = !insideWidget && node.color != nil
        case .unknown:
            emits = !insideWidget
        default:
            emits = true
        }

        if emits {
            let pixels = visible.toPixels(scale: scale)
            nodes.append(
                SkeletonNode(
                    left: pixels.left,
                    top: pixels.top,
                    right: pixels.right,
                    bottom: pixels.bottom,
                    kind: node.kind,
                    color: wireColor(for: node),
                    // Containers outline; everything else fills. A filled container hides its
                    // children, and the children are the screen. A layer that draws only a border is
                    // the same case arriving by another route — see `ViewSnapshot.drawsBorderOnly`.
                    stroke: node.kind == .container || node.drawsBorderOnly,
                    // Only when the *whole* rectangle survived clipping. A radius describes the
                    // corners of the shape the app declared, and a node trimmed by an ancestor is a
                    // piece of that shape with edges the app never rounded — rounding the offcut
                    // would carve a curve out of the middle of the screen.
                    cornerRadii: visible == node.frame
                        ? node.cornerRadii?.map { Int(($0 * scale).rounded()) }
                        : nil
                )
            )
        }

        // Pre-order, so a parent is painted before the children that sit on top of it.
        //
        // Children are clipped to this view only when it says it clips. A `UIView` with
        // `clipsToBounds == false` genuinely lets its children draw outside — shadows, badges, a
        // popover's arrow — and trimming them anyway would erase parts of the screen that are visibly
        // there.
        let childClip = node.clipsToBounds ? visible : clip
        // Once inside a widget, always inside: a field's background view may itself have subviews.
        let childrenAreInsideWidget = insideWidget || isWidget(node.kind)
        for child in node.children {
            collect(
                node: child,
                clip: childClip,
                scale: scale,
                insideWidget: childrenAreInsideWidget,
                captureBounds: captureBounds,
                into: &nodes
            )
        }
    }

    /// A view the SDK recognised as a specific control, as opposed to one it only knows the shape of.
    ///
    /// The distinction matters for what is drawn *inside* it: a recognised widget describes its own area,
    /// so the plain views making up its chrome are noise at best and, when they have a background, cover
    /// the widget entirely.
    private static func isWidget(_ kind: NodeKind) -> Bool {
        switch kind {
        case .text, .input, .image, .button, .webView, .card:
            return true
        case .container, .unknown:
            return false
        }
    }
}
