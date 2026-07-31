#if canImport(UIKit)
import UIKit

/// Renders the real screen, with sensitive content covered before it leaves the device.
///
/// Two properties matter more than the picture quality:
///
///  * **Masking happens before encoding**, not on the server. A screenshot that leaves the device with
///    text in it has already left the device with text in it, whatever happens next.
///  * **The mask is derived from the same geometry as the wireframe**, so a view the wireframe calls
///    text is a view this covers. One classification, two outputs — the alternative is two lists that
///    drift, and the one that drifts is the one that stops covering something.
enum ScreenshotRenderer {

    /// What gets covered.
    struct MaskPolicy {
        var text: Bool
        var images: Bool

        /// Text on, images off.
        ///
        /// Text is where the sensitive content is. Images are where the icons and logos are, and
        /// covering them by default produces a screenshot of grey blocks that tells nobody anything —
        /// so that one is opt-in.
        static let `default` = MaskPolicy(text: true, images: false)
    }

    /// A JPEG of the window, masked, or `nil` if there was nothing to draw.
    ///
    /// - Parameters:
    ///   - window: the window to render.
    ///   - snapshot: the hierarchy as already captured for the wireframe. Passed in rather than
    ///     re-walked so the mask cannot disagree with the wireframe about what a view is.
    ///   - policy: what to cover.
    ///   - quality: JPEG quality. 0.6 is not a quality decision but a size one: these are uploaded
    ///     from a user's device, on their data.
    ///   - scale: pixels per point. Defaults to the screen's own, which is what a screen-map capture wants.
    ///     A replay frame passes something smaller: it is watched in a small player, and full resolution
    ///     costs bytes nobody looks at.
    static func render(
        window: UIWindow,
        snapshot: ViewSnapshot,
        policy: MaskPolicy,
        quality: CGFloat = 0.6,
        scale: CGFloat? = nil
    ) -> Data? {
        assert(Thread.isMainThread, "rendering reads the view hierarchy")
        let bounds = window.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale ?? window.screen.scale
        format.opaque = true

        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
            // `drawHierarchy` rather than `layer.render(in:)`: the layer path misses anything drawn by
            // the compositor rather than by CoreAnimation — visual-effect blurs come out as holes, and
            // a wireframe with holes in it looks like a rendering bug in the product.
            //
            // `afterScreenUpdates: false` on purpose. True forces a layout pass inside the app being
            // recorded, which can run the host's layout code at a moment it did not choose, and on
            // Android the equivalent — forcing a draw — was measurable in the app's own frame timing.
            window.drawHierarchy(in: bounds, afterScreenUpdates: false)

            let cg = context.cgContext
            cg.setFillColor(UIColor.systemGray3.cgColor)
            for rect in maskRects(in: snapshot, policy: policy, bounds: bounds) {
                cg.fill(rect)
            }
        }

        return image.jpegData(compressionQuality: quality)
    }

    /// The rectangles to cover, in the window's own coordinate space.
    ///
    /// Internal rather than private so a test can assert what a policy covers without rendering
    /// anything — the same reason the geometry lives in `ViewSnapshot` and not in `UIView`.
    static func maskRects(in node: ViewSnapshot, policy: MaskPolicy, bounds: CGRect) -> [CGRect] {
        var out: [CGRect] = []
        collectMasks(node, policy: policy, bounds: bounds, into: &out)
        return out
    }

    private static func collectMasks(
        _ node: ViewSnapshot,
        policy: MaskPolicy,
        bounds: CGRect,
        into out: inout [CGRect]
    ) {
        guard !node.isHidden, node.alpha > 0.05 else { return }

        let covered: Bool
        switch node.kind {
        // A field's contents are text, and are more likely than a label to be someone's name, address
        // or password. It follows the text policy because there is no case for covering labels and
        // leaving fields legible.
        case .text, .input:
            covered = policy.text
        case .image:
            covered = policy.images
        // Not covered: a button's own label is covered by the text node inside it if text masking is
        // on, and covering the whole control would erase the screen's structure.
        case .button, .container, .card, .webView, .unknown:
            covered = false
        }

        if covered {
            let rect = CGRect(
                x: node.frame.left,
                y: node.frame.top,
                width: node.frame.width,
                height: node.frame.height
            ).intersection(bounds)
            if !rect.isNull, rect.width > 0, rect.height > 0 {
                out.append(rect)
            }
        }

        // Children are walked even under a covered node: a covered image can contain a label, and the
        // grey block over the image is not a guarantee about the label — the two rectangles may not
        // coincide.
        for child in node.children {
            collectMasks(child, policy: policy, bounds: bounds, into: &out)
        }
    }
}
#endif
