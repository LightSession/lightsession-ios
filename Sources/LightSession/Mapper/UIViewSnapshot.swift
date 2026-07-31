#if canImport(UIKit)
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
            children: subviews.map { $0.lightSessionSnapshot(in: window) }
        )
    }

    private func lightSessionFrame(in window: UIWindow) -> Rect {
        let converted = convert(bounds, to: window)
        return Rect(
            left: converted.minX,
            top: converted.minY,
            right: converted.maxX,
            bottom: converted.maxY
        )
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
#endif
