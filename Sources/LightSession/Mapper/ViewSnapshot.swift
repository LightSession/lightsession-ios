import Foundation

/// A view hierarchy, described without UIKit.
///
/// This exists so the wireframe rules — which views are skipped, how a frame is clipped, what counts
/// as content, what order rectangles end up in — can be tested by building trees in a test file
/// instead of by launching a simulator and looking at a picture. On Android the equivalent rule got
/// two regressions past me in one afternoon, and both were the kind a unit test states in one line:
/// a plain coloured view stopped counting as content, so a splash screen produced no wireframe at all.
///
/// `UIView` is turned into this in one place, `UIView+Snapshot.swift`, which is the only file that has
/// to know about UIKit classes.
public struct ViewSnapshot: Equatable, Sendable {
    /// Already in the coordinate space of the window, and already in points.
    public var frame: Rect
    public var kind: NodeKind
    public var isHidden: Bool
    public var alpha: Double
    /// The view's own background, if it has an opaque enough one to be worth drawing.
    public var color: Color?
    /// Whether this view clips what its children draw. Decides whether children are trimmed to it.
    public var clipsToBounds: Bool
    /// What UIKit's own `isOpaque` says, before the background colour is consulted.
    ///
    /// Kept separate from `color` because the two answer different questions: `color` is what to draw, and this is
    /// whether anything behind the view can show through. `CoveredContent` needs both, and a view that draws a
    /// background while declaring itself non-opaque is one whose backdrop may still be visible.
    public var declaresOpaque: Bool
    /// Whether all this node draws is an outline around its edge, with nothing in the middle.
    ///
    /// SwiftUI draws a bordered text field as two layers — the fill underneath and a rounded-rect
    /// *stroke* on top, the second with no background colour at all. Described as a rectangle that
    /// draws, the stroke is a solid slab exactly the size of the field, painted after it. Measured on a
    /// four-field form: the wireframe had four grey blocks of 1114×160 and not one orange input, and
    /// the grey came to 712,960 pixels — four times the product, to the pixel.
    ///
    /// Two things follow from it, and both are wrong without it. The node is **stroked**, so the middle
    /// is left for what it surrounds; and it is never an opaque cover, because an outline hides nothing.
    public var drawsBorderOnly: Bool
    public var children: [ViewSnapshot]

    public init(
        frame: Rect,
        kind: NodeKind,
        isHidden: Bool = false,
        alpha: Double = 1,
        color: Color? = nil,
        clipsToBounds: Bool = false,
        declaresOpaque: Bool = false,
        drawsBorderOnly: Bool = false,
        children: [ViewSnapshot] = []
    ) {
        self.frame = frame
        self.kind = kind
        self.isHidden = isHidden
        self.alpha = alpha
        self.color = color
        self.clipsToBounds = clipsToBounds
        self.declaresOpaque = declaresOpaque
        self.drawsBorderOnly = drawsBorderOnly
        self.children = children
    }
}

/// A rectangle in points, left/top/right/bottom like the wire format.
///
/// Not `CGRect`: CoreGraphics is available on macOS, but width/height would then have to be converted
/// at every boundary, and the wire format is edges. Storing what is sent avoids one conversion and
/// one class of off-by-one.
public struct Rect: Equatable, Sendable {
    public var left: Double
    public var top: Double
    public var right: Double
    public var bottom: Double

    public init(left: Double, top: Double, right: Double, bottom: Double) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    public var width: Double { right - left }
    public var height: Double { bottom - top }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    /// The part of this rectangle inside `other`, or `nil` when they do not overlap.
    public func clipped(to other: Rect) -> Rect? {
        let clipped = Rect(
            left: max(left, other.left),
            top: max(top, other.top),
            right: min(right, other.right),
            bottom: min(bottom, other.bottom)
        )
        return clipped.isEmpty ? nil : clipped
    }

    /// Scaled to device pixels and rounded outwards.
    ///
    /// Outwards rather than nearest: a one-pixel separator is 0.33 points on a 3× screen, and
    /// rounding its edges to the nearest pixel can collapse it to nothing. A wireframe that loses its
    /// dividers reads as a different screen.
    public func toPixels(scale: Double) -> (left: Int, top: Int, right: Int, bottom: Int) {
        (
            Int((left * scale).rounded(.down)),
            Int((top * scale).rounded(.down)),
            Int((right * scale).rounded(.up)),
            Int((bottom * scale).rounded(.up))
        )
    }
}

/// A colour as four components in 0…1, in whatever space the platform gave it.
public struct Color: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public var hex: String {
        skeletonColorHex(red: red, green: green, blue: blue, alpha: alpha)
    }
}
