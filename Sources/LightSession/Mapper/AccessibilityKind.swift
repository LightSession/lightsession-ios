import Foundation

/// What a view says it is, through accessibility.
///
/// The escape hatch for a real problem: **classification by superclass does not work on iOS for React Native.**
/// On Android it worked for free, because `ReactTextView` descends from `TextView`. On iOS React Native does not
/// use `UILabel` at all — it draws text itself into `RCTParagraphComponentView`, a plain `UIView` — so a
/// paragraph classified as a container and, because containers are not masked, **left legible in the capture**.
/// Measured by looking at a stored screenshot: the nav bar title and the text fields were covered and the
/// heading, the body paragraph and the button label were readable.
///
/// The obvious fix is to match the class name, and it is the wrong one: it covers exactly the frameworks someone
/// thought of, on exactly the versions they tested, and it is the mistake this SDK's own comments warn about
/// elsewhere. Accessibility traits are a *semantic* claim the view makes about itself — one that React Native,
/// SwiftUI, Flutter and hand-written UIKit all set, because screen readers depend on it. A framework that sets
/// it wrong is broken for VoiceOver too, which is the kind of bug that gets fixed.
///
/// Pure, and takes the raw bitmask, so the mapping can be tested without a simulator and the constants are
/// written down where they can be checked rather than trusted.
public enum AccessibilityKind {

    /// `UIAccessibilityTraits.staticText`.
    ///
    /// Observed as `64` on `RCTParagraphComponentView` in a running React Native app — every `<Text>` on screen.
    public static let staticText: UInt64 = 64

    /// `UIAccessibilityTraits.button`.
    ///
    /// Catches what says it is a button without being a `UIControl`: a React Native `Pressable` with
    /// `accessibilityRole="button"`, a SwiftUI `Button`. A real `UIButton` is already recognised by its class.
    public static let button: UInt64 = 1

    /// `UIAccessibilityTraits.image`. Observed as `4` on a `UIImageView`, which confirms the table above is
    /// being read correctly rather than guessed at.
    public static let image: UInt64 = 4

    /// `UIAccessibilityTraits.searchField`.
    public static let searchField: UInt64 = 1 << 8

    /// The kind a view's traits imply, or `nil` when they imply nothing.
    ///
    /// Order is by how much is at stake. Text comes first because text is what masking exists for, and a view
    /// that claims both `staticText` and `button` — a labelled control — is safer treated as text: the cost of
    /// being wrong is a grey block where a label was, against a name left legible in a capture.
    public static func kind(forTraits raw: UInt64) -> NodeKind? {
        if raw & staticText != 0 { return .text }
        if raw & searchField != 0 { return .input }
        if raw & button != 0 { return .button }
        if raw & image != 0 { return .image }
        return nil
    }
}
