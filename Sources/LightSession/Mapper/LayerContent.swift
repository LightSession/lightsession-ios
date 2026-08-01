#if canImport(QuartzCore)
// The `@try/@catch` around `presentationLayer`, reached the same two ways as in `UIViewSnapshot`: as a module
// under SwiftPM, through the pod's umbrella header under CocoaPods.
#if canImport(LightSessionSafe)
import LightSessionSafe
#endif
import CoreGraphics
import QuartzCore

/// The content a walk of the view hierarchy cannot see.
///
/// The bug this exists for: **SwiftUI text came out legible in captures.** Every UIKit screen was masked
/// correctly and every SwiftUI screen was not, and the reason is that on a SwiftUI screen there is almost
/// nothing to walk. A hosting view for a stack of `Text`, a `Button`, an `Image` and a shape has exactly
/// one subview — the UIKit adaptor behind the text field — and its layer has six sublayers. The words are
/// not views. No check on a class, a superclass or an accessibility trait can find them, because there is
/// no object there to ask.
///
/// Measured on a simulator by printing both trees side by side:
///
/// ```
/// _UIHostingView<Demo>        subviews=1
///   CGDrawingLayer   viewBacked=false contents=true   171x27   <- Text("A SwiftUI screen")
///   CGDrawingLayer   viewBacked=false contents=true   350x65   <- the wrapped paragraph
///   CGDrawingLayer   viewBacked=false contents=true   102x21   <- the Button's label
///   CALayer          viewBacked=true                  358x22   <- the UITextField adaptor
///   ImageLayer       viewBacked=false contents=true    20x18   <- Image(systemName:)
///   CALayer          viewBacked=false contents=false  358x80   <- the shape, colour only
/// ```
///
/// So the rule is structural rather than a list of class names: **a layer that draws and is not backed by a
/// view is content nothing else in the walk describes.** A view-backed layer is skipped, because the view
/// that owns it is visited through the view hierarchy and describing it twice would double every mask.
///
/// ## Which way it errs
///
/// Text and images are both a rasterised `contents`, and nothing in the layer distinguishes them. Since one
/// of those is masked by default and the other is opt-in, the choice cannot be avoided: **anything that
/// draws is text unless it is positively recognised as an image.** If a future release renames its image
/// layer, the cost is a masked icon in a replay. Reversing that default would make the cost a legible
/// password, which is not a trade this SDK gets to make.
enum LayerContent {

    /// The smallest opacity still worth describing.
    static let minOpacity: Float = 0.05

    /// Nodes for everything drawn by layers under `layer` that no view stands for.
    ///
    /// - Parameter layer: a view's own layer. Its sublayers are examined; it is not.
    static func nodes(under layer: CALayer) -> [ViewSnapshot] {
        (layer.sublayers ?? []).flatMap { node(for: $0) }
    }

    /// This layer as a node, plus whatever is drawn below it — or nothing.
    private static func node(for layer: CALayer) -> [ViewSnapshot] {
        // A view's layer. The view is walked as a view, with its accessibility traits, its class and its
        // subviews; arriving at it again through the layer tree would describe the same rectangle twice.
        // Its own sublayers are its view's business for the same reason.
        if layer.delegate is UIViewLike { return [] }
        guard !layer.isHidden, layer.opacity >= minOpacity else { return [] }

        let below = nodes(under: layer)
        guard let kind = kind(of: layer) else {
            // Draws nothing itself. Still a parent: SwiftUI nests drawing layers under plain ones.
            return below
        }

        return [
            ViewSnapshot(
                frame: layer.lightSessionFrame(),
                kind: kind,
                alpha: Double(layer.opacity),
                color: layer.lightSessionBackgroundColor,
                clipsToBounds: layer.masksToBounds,
                declaresOpaque: layer.isOpaque,
                children: below
            )
        ]
    }

    /// What a layer draws, or `nil` if it draws nothing.
    ///
    /// Ordered so the certain answers come first and the guess comes last.
    static func kind(of layer: CALayer) -> NodeKind? {
        // The one text layer with a public class. No name matching needed, so it cannot rot.
        if layer is CATextLayer { return .text }

        if layer.contents != nil {
            // The only name check here, and it is aimed the safe way round: recognising an image relaxes the
            // mask, so a name that stops matching leaves an image masked rather than text exposed.
            return describesAnImage(layer) ? .image : .text
        }

        // No contents: a colour, a border, a shadow. Drawn, but not something to cover — and `unknown`
        // rather than `container` because it puts ink on the screen and the wireframe should show it.
        if layer.lightSessionBackgroundColor != nil { return .unknown }
        if layer.borderWidth > 0, layer.borderColor != nil { return .unknown }
        return nil
    }

    private static func describesAnImage(_ layer: CALayer) -> Bool {
        String(describing: type(of: layer)).localizedCaseInsensitiveContains("image")
    }
}

/// Anything that owns a layer and is walked separately.
///
/// A protocol rather than `is UIView`, so this file compiles where UIKit does not and the rule stays
/// testable on the platform the pure tests run on. `UIView` is conformed to it where UIKit exists.
protocol UIViewLike: AnyObject {}

extension CALayer {
    /// This layer's rectangle in the window, as it is **on screen right now**.
    ///
    /// Presented geometry, not model geometry, and that distinction is why this is not one line.
    /// `convert(bounds, to: window)` answers where the layer *will be* once any running animation ends. The
    /// pixels a capture contains are the presented state — mid-slide. Reading one while drawing the other is
    /// what put mask rectangles beside the words they were meant to cover: a stored frame of a push showed
    /// two screens side by side with grey blocks next to the text instead of over it.
    ///
    /// The arithmetic is `CALayer`'s own, and each line earns its place:
    ///
    ///  * The **position** is converted through the *presented* parent with `to: nil`, which means "the root
    ///    of the layer tree". An earlier attempt converted into `window.layer.presentation()` instead and
    ///    silently did nothing, because a window is not what animates — the container inside it is — so that
    ///    call returned nil and every frame fell back to the model. `to: nil` needs no target layer at all.
    ///  * A layer with **no presentation layer is not animating**, so its model values *are* its presented
    ///    ones. That is what makes it safe to take presented-if-available link by link rather than needing
    ///    the whole ancestry to be animating at once.
    ///  * `position` is where the **anchor point** sits, not the origin, so the anchor is subtracted.
    ///    Skipping that offsets every layer by half its size on the default anchor of (0.5, 0.5).
    ///  * `transform` is folded in, so a modal presentation — which scales the screen behind it — is measured
    ///    where it is drawn rather than where it would be at rest.
    func lightSessionFrame() -> Rect {
        let presented = LightSessionPresentationLayer(self) ?? self
        let size = presented.bounds.size
        let parent = superlayer.map { LightSessionPresentationLayer($0) ?? $0 }
        let position = parent?.convert(presented.position, to: nil) ?? presented.position

        var transform = CGAffineTransform.identity
        transform.tx = position.x
        transform.ty = position.y
        transform = CATransform3DGetAffineTransform(presented.transform).concatenating(transform)
        transform = transform.translatedBy(
            x: -size.width * presented.anchorPoint.x,
            y: -size.height * presented.anchorPoint.y
        )

        // The bounding box of the transformed rectangle. `Rect` is axis-aligned and so is the wire format, so
        // a rotated layer is described by the box around it — larger than the layer, which for a mask errs
        // safe.
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        return Rect(left: rect.minX, top: rect.minY, right: rect.maxX, bottom: rect.maxY)
    }

    /// The layer's background, when it is solid enough to be worth drawing.
    ///
    /// The same threshold the view path uses, for the same reason: a wireframe of every nearly-transparent
    /// layer is unreadable.
    var lightSessionBackgroundColor: Color? {
        guard let backgroundColor else { return nil }
        let components = backgroundColor.components ?? []
        let alpha = Double(backgroundColor.alpha)
        guard alpha > 0.05 else { return nil }
        switch components.count {
        case 2:  // grey + alpha
            let white = Double(components[0])
            return Color(red: white, green: white, blue: white, alpha: alpha)
        case 4...:
            return Color(
                red: Double(components[0]),
                green: Double(components[1]),
                blue: Double(components[2]),
                alpha: alpha
            )
        default:
            return nil
        }
    }
}
#endif
