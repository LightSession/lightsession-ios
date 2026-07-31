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

    /// What gets covered. The rule itself lives in `MaskGeometry`, where a test can reach it.
    typealias MaskPolicy = MaskGeometry.Policy

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
    /// A conversion and nothing else: `MaskGeometry` decides *what* is covered, including what an opaque view
    /// hides. That used to be decided here, where no test could reach it, and it was wrong — a capture of one
    /// screen carried the previous screen's mask rectangles.
    static func maskRects(in node: ViewSnapshot, policy: MaskPolicy, bounds: CGRect) -> [CGRect] {
        let area = Rect(
            left: bounds.minX, top: bounds.minY, right: bounds.maxX, bottom: bounds.maxY
        )
        return MaskGeometry.rects(in: node, policy: policy, bounds: area).compactMap { rect in
            let cg = CGRect(x: rect.left, y: rect.top, width: rect.width, height: rect.height)
                .intersection(bounds)
            return (cg.isNull || cg.width <= 0 || cg.height <= 0) ? nil : cg
        }
    }
}
#endif
