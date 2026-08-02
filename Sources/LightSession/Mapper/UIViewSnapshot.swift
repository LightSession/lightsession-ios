#if canImport(UIKit)
// Two builds reach the same Objective-C function two different ways. SwiftPM needs one target per
// language, so there it is a module of its own and has to be imported. CocoaPods builds one
// mixed-language module instead, and there the header arrives through the pod's umbrella — the
// module does not exist, and importing it would fail to compile.
#if canImport(LightSessionSafe)
import LightSessionSafe
#endif
import UIKit
import WebKit

/// The one place that knows about UIKit classes.
///
/// Classification is by **superclass** first, and that carries most of the work: a `UILabel` subclass from a
/// design system, a third-party button, UIKit's own private views — all are still the class they inherit from.
/// Class-name matching would break under the release build's symbol handling, which is how the equivalent
/// Android check failed the first time it met R8.
///
/// It is not enough on its own here, and that is a difference from Android worth stating rather than
/// discovering. On Android, React Native needed no support at all because `ReactTextView` descends from
/// `TextView`. On iOS, React Native does not use `UILabel` — it draws text itself into a plain `UIView` — so
/// ancestry finds nothing and the text went unmasked. Accessibility traits answer what ancestry cannot; see
/// `AccessibilityKind`.
extension UIView {

    /// This view and everything under it, in the coordinate space of `window`.
    func lightSessionSnapshot(in window: UIWindow) -> ViewSnapshot {
        ViewSnapshot(
            frame: lightSessionFrame(in: window),
            kind: lightSessionKind,
            isHidden: isHidden,
            alpha: Double(alpha),
            color: lightSessionBackgroundColor,
            clipsToBounds: clipsToBounds,
            declaresOpaque: isOpaque,
            children: lightSessionChildrenInPaintOrder(in: window)
        )
    }

    /// Everything drawn inside this view, in the order it is painted.
    ///
    /// Subviews and the view's own drawing layers are **siblings** — both are entries in
    /// `layer.sublayers`, and that list is the paint order. This used to walk the subviews and then
    /// append the layers, which is not an ordering at all: it puts every layer on top of every subview
    /// regardless of where they really sit.
    ///
    /// For a UIKit screen the difference is invisible, because a UIKit view's content is its subviews
    /// and there is nothing in the layer list to misplace. For a SwiftUI screen it destroyed the
    /// wireframe. Measured on a form sheet with four fields and a button — the SDK built twenty-five
    /// nodes and the picture had three colours, because the node after all of them was this:
    ///
    ///     node[23] UNKNOWN 0,186 1206x2436 color=#F7F7F7
    ///
    /// the sheet's own background, painted last and therefore over everything. The rendered wireframe
    /// showed 62 pixels of the button and none of the fields.
    ///
    /// The old order was chosen for the mask, on the grounds that a cover arriving last discards more
    /// and errs towards masking. Correct order errs the same way for the only case that matters: a
    /// node genuinely behind an opaque cover is one the screenshot does not show either.
    func lightSessionChildrenInPaintOrder(in window: UIWindow) -> [ViewSnapshot] {
        guard let sublayers = layer.sublayers, !sublayers.isEmpty else {
            return subviews.map { $0.lightSessionSnapshot(in: window) }
        }

        var children: [ViewSnapshot] = []
        var unplaced = subviews

        for sublayer in sublayers {
            if let owner = sublayer.delegate as? UIView {
                // A view's own layer. Walked as a view — with its class, its traits and its subviews —
                // at the position the layer list gives it.
                guard let index = unplaced.firstIndex(where: { $0 === owner }) else { continue }
                unplaced.remove(at: index)
                children.append(owner.lightSessionSnapshot(in: window))
            } else {
                children.append(contentsOf: LayerContent.node(for: sublayer))
            }
        }

        // A subview whose layer is not a direct sublayer of this one still has to be described. It
        // should not happen; losing a screen's content to an assumption about UIKit would.
        children.append(contentsOf: unplaced.map { $0.lightSessionSnapshot(in: window) })
        return children
    }

    /// This view's rectangle in the window, as it is **on screen right now**.
    ///
    /// Presented geometry, not model geometry, and that distinction is why this is not one line.
    /// `view.convert(bounds, to: window)` answers where the view *will be* once any running animation ends. The
    /// pixels a capture contains are the presented state — mid-slide. Reading one while drawing the other is what
    /// put mask rectangles beside the words they were meant to cover: a stored frame of a push showed two screens
    /// side by side with grey blocks next to the text instead of over it.
    ///
    /// The arithmetic is `CALayer`'s own, and each line earns its place:
    ///
    ///  * The **position** is converted through the *presented* parent with `to: nil`, which means "the root of
    ///    the layer tree". An earlier attempt converted into `window.layer.presentation()` instead and silently did
    ///    nothing, because a window is not what animates — the container inside it is — so that call returned nil
    ///    and every frame fell back to the model. `to: nil` needs no target layer at all.
    ///  * A layer with **no presentation layer is not animating**, so its model values *are* its presented ones.
    ///    That is what makes it safe to take presented-if-available link by link rather than needing the whole
    ///    ancestry to be animating at once.
    ///  * `position` is where the **anchor point** sits, not the origin, so the anchor is subtracted. Skipping that
    ///    offsets every view by half its size on the default anchor of (0.5, 0.5).
    ///  * `layer.transform` is folded in, so a modal presentation — which scales the screen behind it — is measured
    ///    where it is drawn rather than where it would be at rest.
    func lightSessionFrame(in window: UIWindow) -> Rect {
        // Asked of the layer, because a layer is what the arithmetic is about and because SwiftUI's content
        // is layers with no view to ask. One implementation, two callers.
        layer.lightSessionFrame()
    }

    /// What this view is, for the purposes of a wireframe.
    ///
    /// Order matters, and the specific views come before the general ones they descend from:
    /// `UITextView` is a `UIScrollView`, a `UIButton` is a `UIControl`, and `UITextField` is a
    /// `UIControl` too. Asking the general question first would label all of them containers.
    var lightSessionKind: NodeKind {
        // Editable text first: a `UITextView` that cannot be edited is a paragraph, one that can is a
        // field, and they read differently in a wireframe.
        if let textView = self as? UITextView {
            return textView.isEditable ? .input : .text
        }
        if self is UITextField { return .input }
        if self is UILabel { return .text }
        if self is WKWebView { return .webView }
        // A `UIButton`'s label and image are subviews, so this must come before the checks that would
        // catch them individually — otherwise a button is drawn as the text inside it and loses its
        // shape. The subviews are still walked; they simply sit on top.
        if self is UIButton { return .button }
        // Switches, sliders, steppers, segmented controls: things you operate. `UIButton` above is the
        // common case and gets its own branch for clarity, not because this would miss it.
        if self is UIControl { return .button }
        if self is UIImageView { return .image }

        // What the view says it is, when its class does not say.
        //
        // This is what makes React Native's text on iOS text: RN draws into `RCTParagraphComponentView`, a plain
        // `UIView`, so no superclass check can find it — and a paragraph classified as a container is a paragraph
        // left legible in the capture, because containers are not masked. It was, and looking at a stored
        // screenshot is how that was found.
        //
        // Deliberately *after* the class checks, so a `UILabel` is still text by ancestry and this only answers
        // the cases ancestry cannot. See `AccessibilityKind` for why a semantic claim beats a class-name list.
        if let claimed = AccessibilityKind.kind(forTraits: accessibilityTraits.rawValue) {
            return claimed
        }

        // Explicitly a container, and each for a reason:
        //  * `UIScrollView` and its table/collection kin are frames around content.
        //  * `UIVisualEffectView` is a blur, which has no content of its own.
        //  * `UIStackView` is layout with nothing drawn.
        if self is UIScrollView || self is UIVisualEffectView || self is UIStackView {
            return .container
        }

        // A plain `UIView`. If it has a background it draws, and it is the only thing on some screens
        // — a splash, a colour block, a caret. That is why this returns `unknown` rather than
        // `container`: `unknown` counts as content, and treating these as furniture is precisely the
        // bug that left an Android screen with no wireframe at all while its screenshot masked the hole.
        if lightSessionBackgroundColor != nil && subviews.isEmpty {
            return .unknown
        }
        return .container
    }

    /// The view's background, when it is solid enough to be worth drawing.
    ///
    /// Returns `nil` for a clear or nearly-clear background so the builder can skip drawing the
    /// container at all. A wireframe of every transparent layout view is unreadable.
    var lightSessionBackgroundColor: Color? {
        guard let backgroundColor else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        // Resolved against this view's traits first: a dynamic system colour is a *promise* of a
        // colour, and asking it for components without the trait collection gives the light-mode
        // answer on a dark screen — a wireframe of a screen that does not exist.
        let resolved = backgroundColor.resolvedColor(with: traitCollection)
        guard resolved.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        guard a > 0.05 else { return nil }
        return Color(red: Double(r), green: Double(g), blue: Double(b), alpha: Double(a))
    }
}

extension UIWindow {
    /// The window's own background, drawn under everything.
    ///
    /// A window usually has none, in which case the root view's is the screen's background — which is
    /// what the user sees and what the wireframe needs.
    var lightSessionBackground: Color? {
        lightSessionBackgroundColor ?? rootViewController?.view?.lightSessionBackgroundColor
    }
}

/// Marks a view as walked in its own right, so `LayerContent` leaves its layer alone. Without this the
/// mask of every UIKit view would be emitted twice: once for the view, once for the layer behind it.
extension UIView: UIViewLike {}

extension UIWindow {

    /// Everything on screen, which is the window and not its root view.
    ///
    /// The difference is a modal. A presented view controller's view is **not** a descendant of the
    /// presenting controller's view — UIKit installs it in a container of its own under the window —
    /// so a walk that starts at `rootViewController.view` never reaches a sheet, an alert or a
    /// full-screen cover, and never classifies a word inside one.
    ///
    /// That was not a missing feature, it was a leak. The pixels come from `drawHierarchy` on the
    /// *window*, which draws the modal whether or not anything described it, while the masks came
    /// from the screen underneath. Measured on a stored capture of a sheet: its heading, its
    /// paragraph and its button were legible, with a single grey block over them belonging to the
    /// navigation bar of the screen behind. A screenshot that leaves the device with text in it has
    /// left the device with text in it, whatever the next step does.
    ///
    /// Starting here also fixes the second half of what that looked like. With the sheet in the
    /// snapshot, its own opaque background is an opaque cover, so `CoveredContent` discards the
    /// rectangles of the screen it hides instead of drawing them on top of it.
    var lightSessionContent: ViewSnapshot {
        lightSessionSnapshot(in: self)
    }
}
#endif
