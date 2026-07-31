import Foundation

/// What an opaque view hides.
///
/// The rule this exists for, stated as the bug it fixes: **the mask of one screen was drawn over the next one.**
/// During a navigation transition both view controllers' views are in the window at once, and a walk of the
/// hierarchy finds the labels of the screen being left as well as the one being entered. Both got masked, so a
/// capture of screen B carried grey blocks positioned for screen A's text — over pixels where there was no text.
///
/// The fix is to notice what is *visible*. A view that is opaque and covers an area hides everything already
/// collected beneath it, so those regions are discarded. Paint order is what makes it work: the traversal is
/// pre-order, so "already collected" is exactly "underneath".
///
/// Two levels, and the difference matters:
///
///  * **Covers the whole capture** — a pushed screen's background — clears everything collected so far.
///  * **Covers part of it** — a sheet, a card, an opaque bar — clears only what is entirely inside it.
///
/// A mask that is only *partly* covered keeps its whole rectangle: a text view straddling the edge of an opaque
/// card is not trimmed. That is deliberate and it errs the safe way — a mask slightly too large hides content that
/// was already hidden, while trimming it could expose text. Trimming would mean carrying clip regions through to
/// the renderer, which is more machinery than the bug needs.
public enum CoveredContent {

    /// The alpha at which a background stops counting as see-through.
    ///
    /// The strict answer is exactly 1: a semi-transparent overlay must not clear regions under it, because they
    /// still show through. A hair below 1 is allowed here because a background composed from a dynamic colour
    /// can resolve to 0.999, and treating that as translucent would disable the rule on the screens that need
    /// it most.
    public static let opaqueAlpha: Double = 0.99

    /// Whether this view hides what is behind it.
    public static func isOpaqueCover(_ node: ViewSnapshot) -> Bool {
        guard !node.isHidden, node.alpha >= opaqueAlpha else { return false }
        guard node.declaresOpaque else { return false }
        guard let colour = node.color, colour.alpha >= opaqueAlpha else { return false }
        return true
    }

    /// Removes from `collected` whatever `cover` hides, given the capture's own bounds.
    ///
    /// Generic over the element so the wireframe and the mask share one rule. Two lists that decide separately
    /// what is visible are two lists that disagree, and the one that disagrees is the one that leaks.
    public static func discardCovered<T>(
        _ collected: inout [T],
        by cover: Rect,
        captureBounds: Rect,
        frameOf: (T) -> Rect
    ) {
        guard !cover.isEmpty else { return }

        if covers(cover, captureBounds) {
            collected.removeAll()
            return
        }
        collected.removeAll { contains(cover, frameOf($0)) }
    }

    /// Whether `cover` spans the whole of `area`, within a pixel of rounding.
    ///
    /// A tolerance rather than equality: a pushed view's frame is derived from a layout pass and lands on
    /// fractional points, so `==` against the window would answer no on exactly the case this is for.
    static func covers(_ cover: Rect, _ area: Rect) -> Bool {
        let slack = 1.0
        return cover.left <= area.left + slack
            && cover.top <= area.top + slack
            && cover.right >= area.right - slack
            && cover.bottom >= area.bottom - slack
    }

    /// Whether `inner` sits entirely inside `outer`.
    static func contains(_ outer: Rect, _ inner: Rect) -> Bool {
        inner.left >= outer.left
            && inner.top >= outer.top
            && inner.right <= outer.right
            && inner.bottom <= outer.bottom
    }
}
