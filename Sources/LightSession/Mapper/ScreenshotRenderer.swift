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

    /// The window, masked, as pixels. **Main thread**: it reads the view hierarchy.
    ///
    /// Split from the encoding on purpose. This half has to be on the main thread and has to be inside
    /// the frame the main thread owes the screen; the half that turns pixels into a JPEG touches no UIKit
    /// state and belongs anywhere else. Keeping them in one function meant the replay paid for the
    /// encoding out of the same budget as the drawing, on every tick.
    ///
    /// - Parameters:
    ///   - window: the window to render.
    ///   - snapshot: the hierarchy as already captured for the wireframe. Passed in rather than
    ///     re-walked so the mask cannot disagree with the wireframe about what a view is.
    ///   - policy: what to cover.
    ///   - scale: pixels per point. Defaults to the screen's own, which is what a screen-map capture wants.
    ///     A replay frame passes something smaller: it is watched in a small player, and full resolution
    ///     costs bytes nobody looks at.
    static func capture(
        window: UIWindow,
        snapshot: ViewSnapshot,
        policy: MaskPolicy,
        scale: CGFloat? = nil
    ) -> CGImage? {
        assert(Thread.isMainThread, "capturing reads the view hierarchy")
        let bounds = window.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        return BitmapRenderer.image(size: bounds.size, scale: scale ?? window.screen.scale) { cg in
            // `drawHierarchy` rather than `layer.render(in:)`: the layer path misses anything drawn by
            // the compositor rather than by CoreAnimation — visual-effect blurs come out as holes, and
            // a wireframe with holes in it looks like a rendering bug in the product.
            //
            // `afterScreenUpdates: false` on purpose. True forces a layout pass inside the app being
            // recorded, which can run the host's layout code at a moment it did not choose, and on
            // Android the equivalent — forcing a draw — was measurable in the app's own frame timing.
            window.drawHierarchy(in: bounds, afterScreenUpdates: false)

            cg.setFillColor(UIColor.systemGray3.cgColor)
            for rect in maskRects(in: snapshot, policy: policy, bounds: bounds) {
                cg.fill(rect)
            }
        }
    }

    /// `frame` with its palette colours replaced by the ones on screen, or `frame` unchanged.
    ///
    /// Draws the window exactly as `capture` does, **mask included**, and samples that rather than the
    /// raw screen. Sampling unmasked pixels would give a text block the colour of its paper instead of
    /// the mask's grey, which is prettier and is a second privacy decision to keep in step with
    /// `MaskPolicy` forever. Following the mask needs no such decision: the wireframe can never show a
    /// colour the screenshot does not already show. This is the choice the Android SDK made and the
    /// reasoning is its own.
    ///
    /// Degrades to `frame` at every failure — no context, no buffer, a window with no area. A wireframe
    /// in template colours is what shipped before this existed.
    ///
    /// - Important: geometry and pixels have to describe the same moment. Called from the settle
    ///   callback, which is where the layout has stopped changing; drawing earlier would colour a
    ///   settled wireframe from an unsettled frame.
    static func recolour(
        _ frame: SkeletonFrame,
        window: UIWindow,
        snapshot: ViewSnapshot,
        policy: MaskPolicy
    ) -> SkeletonFrame {
        assert(Thread.isMainThread, "sampling draws the view hierarchy")

        // The colours are only meaningless because the rectangles are coarse. If the walk ever starts
        // emitting one per character, sampling would paint the text back — so this refuses rather than
        // asks. See `Recolour.glyphSizedNodes`.
        let glyphs = Recolour.glyphSizedNodes(in: frame)
        if glyphs > 0 {
            LightSessionLog.debug(
                "\(glyphs) node(s) are glyph-sized; keeping palette colours, since a colour per "
                    + "character would reconstruct the text"
            )
            return frame
        }

        let bounds = window.bounds
        guard bounds.width > 0, bounds.height > 0 else { return frame }

        let sampled = BitmapRenderer.withPixels(
            size: bounds.size,
            scale: window.screen.scale,
            draw: { cg in
                window.drawHierarchy(in: bounds, afterScreenUpdates: false)
                cg.setFillColor(UIColor.systemGray3.cgColor)
                for rect in maskRects(in: snapshot, policy: policy, bounds: bounds) {
                    cg.fill(rect)
                }
            },
            sample: { pixels in Recolour.apply(frame, sampling: pixels) }
        )
        guard let sampled else {
            LightSessionLog.debug("no pixels to sample colours from; keeping the palette")
            return frame
        }
        return sampled
    }

    /// Pixels as a JPEG. Safe off the main thread: nothing here reads a view.
    ///
    /// - Parameter quality: not a quality decision but a size one — these are uploaded from a user's
    ///   device, on their data.
    static func encode(_ image: CGImage, quality: CGFloat) -> Data? {
        UIImage(cgImage: image).jpegData(compressionQuality: quality)
    }

    /// Both halves, for a caller with no reason to separate them.
    ///
    /// The screen map captures one frame per screen, from a settle callback that is already on the main
    /// thread and is not competing with anything. The replay, which captures continuously, uses the two
    /// halves directly.
    static func render(
        window: UIWindow,
        snapshot: ViewSnapshot,
        policy: MaskPolicy,
        quality: CGFloat = 0.6,
        scale: CGFloat? = nil
    ) -> Data? {
        guard let image = capture(window: window, snapshot: snapshot, policy: policy, scale: scale) else {
            return nil
        }
        return encode(image, quality: quality)
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
