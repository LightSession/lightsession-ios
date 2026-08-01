#if canImport(UIKit)
import UIKit

/// A bitmap to draw a window into, and the reason it is not `UIGraphicsImageRenderer`.
///
/// `UIGraphicsImageRendererFormat.default()` derives the bitmap from the screen's own configuration —
/// UIKit's header says as much of both the scale and the gamut. Every recent iPhone has a wide-colour
/// display, so what comes back is an extended-range context: sixteen bits per component and floating
/// point blending, for a picture whose very next step is a quality-0.4 JPEG at a third of the screen's
/// size. All of that range is discarded one line later.
///
/// This draws the same hierarchy into the cheapest bitmap that can hold the answer: eight bits per
/// component, device RGB, alpha ignored because a window is opaque. `drawHierarchy` takes no context
/// argument — it draws into the *current* UIKit context, which is what `UIGraphicsPushContext` is for,
/// and is why this is a context to push rather than a `CGContext` to pass around.
///
/// Why it is worth its own file: this runs on the main thread on every replay tick, and the main thread
/// owes the screen a frame. On a 120 Hz display that is 8.3 ms for the app's own work *and* ours, and a
/// capture that overruns it is a dropped frame the person using the app can see — as a stutter while
/// scrolling, which is exactly when the capture cadence is at its fastest.
enum BitmapRenderer {

    /// Made once. Creating a colour space is not free and this one never varies.
    private static let deviceRGB = CGColorSpaceCreateDeviceRGB()

    /// Draws `size` points at `scale` pixels per point, or `nil` if no context of that size can be made.
    static func image(
        size: CGSize,
        scale: CGFloat,
        draw: (CGContext) -> Void
    ) -> CGImage? {
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard width > 0, height > 0 else { return nil }

        guard let context = CGContext(
            // CoreGraphics owns the buffer on purpose. It picks a row stride it likes rather than the
            // tight one, it hands back zeroed pages — which under `noneSkipLast` read as opaque black,
            // so a draw that fails produces black instead of whatever was in that memory — and there is
            // nothing left to free.
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: deviceRGB,
            // Opaque: a window has nothing behind it. Skipping alpha rather than premultiplying it saves
            // the blend a channel it would only ever find at full strength.
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        // UIKit's y axis points down, CoreGraphics' points up. Translating before the scale keeps this
        // arithmetic in pixels, which is the space `height` is already in.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)

        UIGraphicsPushContext(context)
        draw(context)
        UIGraphicsPopContext()

        return context.makeImage()
    }
}
#endif
