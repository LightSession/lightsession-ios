#if canImport(QuartzCore)
// The `@try/@catch` around `presentationLayer`, reached the same two ways as in `UIViewSnapshot`: as a module
// under SwiftPM, through the pod's umbrella header under CocoaPods.
#if canImport(LightSessionSafe)
import LightSessionSafe
#endif
import CoreGraphics
import Foundation
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
    static func node(for layer: CALayer) -> [ViewSnapshot] {
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

        // An outline and nothing else — see `ViewSnapshot.drawsBorderOnly`. Its colour is the border's,
        // since it has no other, which is what lets the wireframe draw a field's edge as that edge.
        let outlineOnly = layer.lightSessionBackgroundColor == nil && layer.lightSessionBorderColor != nil

        return [
            ViewSnapshot(
                frame: layer.lightSessionFrame(),
                kind: kind,
                alpha: Double(layer.opacity),
                color: layer.lightSessionBackgroundColor ?? layer.lightSessionBorderColor,
                clipsToBounds: layer.masksToBounds,
                declaresOpaque: layer.isOpaque,
                drawsBorderOnly: outlineOnly,
                cornerRadii: layer.lightSessionCornerRadii,
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

        // SwiftUI's own text layer, by name — the exception to this file's structural rule, and a
        // deliberate one. On the iOS 27 beta, CGDrawingLayer draws its glyphs from a display callback
        // *without setting `contents`*, so the structural check below stops seeing it: every SwiftUI
        // text on that OS would fall out of the wireframe and, worse, out of the mask — a label the
        // screenshot shows and nothing covers. On today's iOS the layer still carries `contents` and
        // this line changes nothing; it exists so the mask does not spring a leak the day the beta
        // ships. Suffix match because the class name arrives mangled with a module prefix. Errs the
        // safe way round: a false match masks a rectangle as text rather than exposing one.
        if NSStringFromClass(type(of: layer)).hasSuffix("CGDrawingLayer") { return .text }

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

    /// The corners this layer declares, in visual order, or `nil` when it is square.
    ///
    /// ## Read, never assumed
    ///
    /// Rounding a dialog or a sheet by house style would look right for most apps and be
    /// confidently wrong for the one that squared its corners on purpose, and inventing UI a
    /// customer does not have is a failure this SDK has paid for before. So this reports what the
    /// app's own layer says and nothing else.
    ///
    /// ## What that leaves out, deliberately
    ///
    /// Measured in `ModalCornerProbeTest`: a `UIAlertController` declares 34 points on all four
    /// corners of its own view's layer, and a `.pageSheet` declares **nothing** — its rounding is
    /// applied by the presentation machinery outside the app's view. So an alert is reported round
    /// and a sheet is reported square.
    ///
    /// A sheet could be made to look right by hard-coding the system's radius, and that is the same
    /// mistake as rounding by default approached from the other side: a number Apple owns and
    /// changes between releases, applied to a shape the app never declared. A square outline is
    /// wrong by a corner; an invented one is wrong about whose UI it is.
    ///
    /// ## The mask
    ///
    /// `maskedCorners` names corners after the coordinate space — `MinXMinY` and friends — and this
    /// translates once, here, into the visual order the wire uses, so nothing downstream has to know
    /// `CACornerMask` exists. An unmasked corner is square even when `cornerRadius` is set, which is
    /// exactly how a bottom sheet rounds its top two.
    var lightSessionCornerRadii: [Double]? {
        let radius = Double(cornerRadius)
        guard radius > 0 else { return nil }
        let mask = maskedCorners
        let radii = [
            mask.contains(.layerMinXMinYCorner) ? radius : 0,  // top-left
            mask.contains(.layerMaxXMinYCorner) ? radius : 0,  // top-right
            mask.contains(.layerMaxXMaxYCorner) ? radius : 0,  // bottom-right
            mask.contains(.layerMinXMaxYCorner) ? radius : 0,  // bottom-left
        ]
        // A radius with every corner masked out is a square, and saying so with four zeroes would
        // put a field on the wire that means nothing.
        return radii.contains(where: { $0 > 0 }) ? radii : nil
    }

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
    var lightSessionBackgroundColor: Color? {
        backgroundColor.flatMap(Self.lightSessionColor)
    }

    /// The colour of the layer's border, when it has one wide enough to see.
    ///
    /// A border with no width is a colour nobody asked to be drawn, and reporting it would put an
    /// outline in the wireframe around every layer that happens to carry a default.
    var lightSessionBorderColor: Color? {
        guard borderWidth > 0 else { return nil }
        return borderColor.flatMap(Self.lightSessionColor)
    }

    /// A `CGColor` as the wire format's colour, or nil when it is too faint to be worth drawing.
    ///
    /// The same threshold both callers use, for the same reason: a wireframe of every nearly
    /// transparent layer is unreadable.
    static func lightSessionColor(_ color: CGColor) -> Color? {
        let components = color.components ?? []
        let alpha = Double(color.alpha)
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
