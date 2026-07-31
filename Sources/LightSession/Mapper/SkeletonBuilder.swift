import Foundation

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
    public static func build(
        root: ViewSnapshot,
        scale: Double,
        background: Color?
    ) -> SkeletonFrame? {
        guard !root.frame.isEmpty else { return nil }

        var nodes: [SkeletonNode] = []
        nodes.reserveCapacity(64)
        // The root's own frame is the clip for everything: a view laid out beyond the window is not on
        // screen, and drawing it would put content outside the wireframe's own bounds.
        collect(node: root, clip: root.frame, scale: scale, insideWidget: false, into: &nodes)

        let pixels = root.frame.toPixels(scale: scale)
        return SkeletonFrame(
            width: pixels.right - pixels.left,
            height: pixels.bottom - pixels.top,
            background: background?.hex,
            nodes: nodes
        )
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
        guard isVisible(node) else { return 0 }
        let own: Int
        switch node.kind {
        case .text, .image, .input, .button, .webView, .card, .unknown:
            own = 1
        case .container:
            // A container is furniture. Counting it would make every window "settled" immediately.
            own = 0
        }
        return own + node.children.reduce(0) { $0 + contentCount($1) }
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
        into nodes: inout [SkeletonNode]
    ) {
        guard nodes.count < maxNodes else { return }
        guard isVisible(node) else { return }
        guard let visible = node.frame.clipped(to: clip) else { return }

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
                    // children, and the children are the screen.
                    stroke: node.kind == .container
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
