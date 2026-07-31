import Foundation

/// Where a capture must be covered before it leaves the device.
///
/// Pure, and that is a change worth naming: this logic used to live inside the UIKit renderer, where no test could
/// reach it — and it was wrong. A capture of one screen carried the mask rectangles of the *previous* screen,
/// because during a navigation transition both view controllers' views are in the window and the walk found the
/// text of both. Grey blocks landed where there was no text, and text elsewhere stayed legible.
///
/// The rule that fixes it is `CoveredContent`: an opaque view hides what is beneath it, so those rectangles are
/// discarded. Having it here rather than behind `#if canImport(UIKit)` means the transition case is a test.
public enum MaskGeometry {

    /// What gets covered.
    public struct Policy: Equatable, Sendable {
        public var text: Bool
        public var images: Bool

        public init(text: Bool, images: Bool) {
            self.text = text
            self.images = images
        }

        /// Text on, images off.
        ///
        /// Text is where the sensitive content is. Images are where the icons and logos are, and covering them by
        /// default produces a capture of grey blocks that tells nobody anything — so that one is opt-in.
        public static let `default` = Policy(text: true, images: false)
    }

    /// The rectangles to cover, in the capture's own coordinate space.
    public static func rects(in root: ViewSnapshot, policy: Policy, bounds: Rect) -> [Rect] {
        var out: [Rect] = []
        collect(root, policy: policy, bounds: bounds, into: &out)
        return out
    }

    /// Whether a view of this kind holds something the policy covers.
    static func isCovered(_ kind: NodeKind, by policy: Policy) -> Bool {
        switch kind {
        // A field's contents are text, and are likelier than a label to be someone's name, address or password.
        // It follows the text policy because there is no case for covering labels and leaving fields legible.
        case .text, .input:
            return policy.text
        case .image:
            return policy.images
        // A button's own label is covered by the text node inside it when text masking is on, and covering the
        // whole control would erase the screen's structure for no gain in safety.
        case .button, .container, .card, .webView, .unknown:
            return false
        }
    }

    private static func collect(
        _ node: ViewSnapshot,
        policy: Policy,
        bounds: Rect,
        into out: inout [Rect]
    ) {
        guard !node.isHidden, node.alpha > 0.05 else { return }

        // Before this view's own contribution: what it hides is no longer on screen, whoever put it there.
        //
        // Checked on the way down and in pre-order, so "already collected" is exactly "drawn beneath this". A
        // pushed screen's opaque background arrives after the screen it replaced and clears it.
        if CoveredContent.isOpaqueCover(node) {
            CoveredContent.discardCovered(&out, by: node.frame, captureBounds: bounds, frameOf: { $0 })
        }

        if isCovered(node.kind, by: policy), let visible = node.frame.clipped(to: bounds) {
            out.append(visible)
        }

        // Children are walked even under a covered node: a covered image can contain a label, and the block over
        // the image is not a guarantee about the label — the two rectangles may not coincide.
        for child in node.children {
            collect(child, policy: policy, bounds: bounds, into: &out)
        }
    }
}
