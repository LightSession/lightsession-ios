import Foundation

/// A screen described as geometry, for the server to draw.
///
/// The alternative to encoding a wireframe image on the device, and the reason this is the default
/// path: the device sends a few kilobytes of rectangles instead of paying an image encode for a
/// picture of rectangles. Android measured that encode at 8.25 ms and 80 KB on a 1080×2400 frame
/// against about 3 KB of JSON, and a recorder competes on how little it costs the app it is in.
///
/// The wire shape is fixed by `ls_media::skeleton` on the server and by the Android SDK, which
/// already writes into it. Three things about it are load-bearing:
///
///  * **Flat, in paint order.** The view tree is a tree, but the only thing the drawing needs from it
///    is what covers what — so it is flattened pre-order and the server paints in sequence. A child
///    cannot end up under its parent by accident.
///  * **One-letter keys.** One object per view per screen; the names would outweigh the numbers.
///  * **Colours from the device.** The device is the only side that knows the app's appearance. A
///    dark screen drawn with a light palette is a wireframe of a screen that does not exist.
///
/// There is no text in it and nothing rendered, so it cannot reproduce what a screen said.
public struct SkeletonFrame: Equatable, Sendable {
    public let width: Int
    public let height: Int
    /// The window background. `nil` means the server's default.
    public let background: String?
    /// Pre-order: parents before children.
    public let nodes: [SkeletonNode]

    public init(width: Int, height: Int, background: String?, nodes: [SkeletonNode]) {
        self.width = width
        self.height = height
        self.background = background
        self.nodes = nodes
    }
}

/// One view, in device pixels.
public struct SkeletonNode: Equatable, Sendable {
    public let left: Int
    public let top: Int
    public let right: Int
    public let bottom: Int
    public let kind: NodeKind
    /// `#RRGGBB` or `#AARRGGBB`. `nil` means the server's palette for this kind.
    public let color: String?
    /// Outline rather than fill. A filled container hides everything inside it.
    public let stroke: Bool

    public init(
        left: Int,
        top: Int,
        right: Int,
        bottom: Int,
        kind: NodeKind,
        color: String? = nil,
        stroke: Bool = false
    ) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
        self.kind = kind
        self.color = color
        self.stroke = stroke
    }
}

/// What a view is, as far as a wireframe is concerned.
///
/// The names match `ls_media::skeleton::NodeKind`. A name the server does not know degrades to
/// `UNKNOWN` there rather than failing, so adding a kind here is safe ahead of the server.
public enum NodeKind: String, Equatable, Sendable {
    case container = "CONTAINER"
    case text = "TEXT"
    case image = "IMAGE"
    case input = "INPUT"
    case button = "BUTTON"
    case webView = "WEBVIEW"
    case card = "CARD"
    case unknown = "UNKNOWN"
}

// MARK: - Wire encoding

extension SkeletonFrame {
    /// The JSON the server's `skeleton` field expects.
    ///
    /// Hand-built rather than `Codable`, because the encoding is not a mirror of the type: keys are
    /// abbreviated, `stroke` is omitted when false, and `color` is omitted when absent. Expressing
    /// that through `CodingKeys` and `encodeIfPresent` costs more to read than the dictionary does.
    public var jsonObject: [String: Any] {
        var frame: [String: Any] = [
            "width": width,
            "height": height,
            "nodes": nodes.map(\.jsonObject),
        ]
        if let background { frame["background"] = background }
        return frame
    }
}

extension SkeletonNode {
    public var jsonObject: [String: Any] {
        var node: [String: Any] = [
            "l": left,
            "t": top,
            "r": right,
            "b": bottom,
            "kind": kind.rawValue,
        ]
        if let color { node["color"] = color }
        // Omitted when false, which is most nodes. The server defaults it.
        if stroke { node["stroke"] = true }
        return node
    }
}

/// `#RRGGBB` when opaque, `#AARRGGBB` otherwise.
///
/// Alpha first, which is Android's channel order and *not* CSS's `#RRGGBBAA`. The server parses this
/// order; sending CSS's would silently swap a colour's alpha with its red.
///
/// Takes components rather than a `UIColor` so it stays a plain function that a test can call without
/// a simulator — the same reason the Android version avoids `android.graphics.Color`.
public func skeletonColorHex(red: Double, green: Double, blue: Double, alpha: Double) -> String {
    func byte(_ value: Double) -> Int {
        // Clamped, because a colour in an extended-range space can legitimately report components
        // outside 0…1 and `Int(1.2 * 255)` would overflow the two hex digits below.
        Int((min(max(value, 0), 1) * 255).rounded())
    }
    let a = byte(alpha), r = byte(red), g = byte(green), b = byte(blue)
    let rgb = String(format: "%02X%02X%02X", r, g, b)
    return a == 255 ? "#\(rgb)" : "#" + String(format: "%02X", a) + rgb
}
