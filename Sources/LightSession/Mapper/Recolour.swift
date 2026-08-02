/// Replaces a wireframe's palette colours with the ones actually on screen.
///
/// A port of the Android SDK's `Recolour`, deliberately down to the constants: the two platforms draw
/// into one screen map, and a wireframe that changes colour depending on which phone produced it is a
/// graph nobody can read across.
///
/// ## Why not ask the framework
///
/// iOS reaches further here than Android could — a `CALayer` really does hand over `backgroundColor`
/// and `borderColor`, and this SDK already reports both. That is why a sheet arrives with its own
/// `#F7F7F7` and a button with its `#0088FF`.
///
/// It is also why the property route is finished rather than promising. The kinds still wearing palette
/// colours — text, inputs, images — are exactly the ones no layer property can answer for: a label's
/// pixels are its glyphs over whatever is behind it, an image's are a bitmap, a gradient's belong to
/// `CAGradientLayer.colors` and not to any background. Every one of those needs the pixels.
///
/// The pixels also cost nothing extra in correctness: theme, dark mode, photographs, web views and
/// anything drawn by hand come out right, from one implementation, with nothing to keep in step with
/// SwiftUI.
///
/// ## Dominant, or mean
///
/// Neither reduction wins, and that is why there are two. Over a card with text on it — the card
/// `#F2F4F7` — the mean gives `#BFC1C3`, a grey belonging to neither the card nor the ink, while the
/// most common colour gives the card, because most of a text block is background. Over a gradient the
/// mean gives its midpoint and the most common colour picks whichever narrow band happened to win.
///
/// So: the most common colour when one actually dominates, and the mean when nothing does — and
/// "nothing dominates" is what a photograph or a gradient *is*. See ``dominance``.
///
/// ## What this costs
///
/// The wireframe stops being a typed diagram and becomes a low-fidelity picture of the screen. An input
/// sampled from a white field comes back white, not palette orange, so the colour no longer tells a
/// reader what kind of thing it is looking at. That is the trade Android already made and this matches
/// it; ``LightSessionConfig/sampleWireframeColours`` turns it off for anyone who wants the legend back.
///
/// ## What this means for privacy
///
/// A rectangle's thousands of pixels become three numbers. That is not reversible: no glyph can be
/// recovered from a colour, and the dominant colour of a text block is its background, so the text does
/// not merely blur — it is gone.
///
/// The guarantee is a property of the *rectangles*, though, not of this code. One colour per text block
/// says nothing; one colour per glyph would spell the word out. That is what ``glyphSizedNodes`` is for,
/// and the caller refuses rather than asks.
enum Recolour {

    /// Every Nth pixel in each axis.
    ///
    /// A sixteenth of the pixels, which is far more than enough to answer "what colour is this surface".
    ///
    /// Stride rather than a smaller bitmap, and the difference is not performance. Downscaling *averages*
    /// pixels, which is the one thing that must not happen before a histogram: a text block at quarter
    /// scale has its ink blended into its paper, and the dominant colour comes back a grey that is
    /// neither. Skipping pixels leaves the distribution alone.
    static let stride = 4

    /// How much of a rectangle one colour must cover to be called its colour.
    ///
    /// Two fifths separates the two cases cleanly and is not close to either: a card with text on it is
    /// 70–85% background, and the widest band of a gradient is a few percent.
    static let dominance = 0.4

    /// 32 levels per channel: merges anti-aliasing without merging colours anybody would call different.
    private static let levelsShift = 3
    private static let buckets = 1 << 15

    /// Below this, on both axes, a rectangle could be one character.
    ///
    /// 12 pixels is smaller than any glyph a phone renders at a readable size — body text at the
    /// smallest common scale is around 30 pixels tall on a 1080-wide screen. Anything under this on
    /// *both* axes is not a widget.
    static let minimumSafeSide = 12

    /// Whether the frame's rectangles are coarse enough for their colours to say nothing.
    ///
    /// The privacy property rests entirely on rectangle size. One colour for a paragraph is the colour
    /// of the paper; one colour per letter would spell the paragraph out in a mosaic, and nothing about
    /// the sampling would have changed — only what it was asked about.
    ///
    /// So the shape of the payload is the thing to defend. A rectangle small enough to hold a single
    /// character is the signal, and there is no legitimate reason for the walk to emit one: the smallest
    /// thing it describes is a widget.
    ///
    /// Returns the count rather than a boolean, so a caller can say how bad it is.
    static func glyphSizedNodes(in frame: SkeletonFrame, minimumSide: Int = minimumSafeSide) -> Int {
        frame.nodes.count { node in
            !node.stroke
                && (node.right - node.left) < minimumSide
                && (node.bottom - node.top) < minimumSide
        }
    }

    /// The frame with every fillable node's colour read from `pixels`.
    ///
    /// Node geometry is in the frame's coordinates, which need not be the bitmap's: a capture taken at
    /// half scale is half the size of the geometry describing it. Scaled here rather than requiring the
    /// caller to match them, because the caller that gets it wrong produces a wireframe coloured from
    /// the wrong parts of the screen and nothing says so.
    static func apply<Pixels: PixelSource>(_ frame: SkeletonFrame, sampling pixels: Pixels) -> SkeletonFrame {
        guard pixels.width > 0, pixels.height > 0, frame.width > 0, frame.height > 0 else { return frame }

        let scaleX = Double(pixels.width) / Double(frame.width)
        let scaleY = Double(pixels.height) / Double(frame.height)

        // Allocated once for the whole frame rather than per node: 32,768 entries per rectangle would be
        // megabytes across a screen. Only the buckets actually used are cleared, since wiping all of them
        // per node costs more than the counting does.
        var histogram = [Int](repeating: 0, count: buckets)
        var touched = [Int](repeating: 0, count: buckets)

        let recoloured = frame.nodes.map { node -> SkeletonNode in
            // An outline is structure, not surface. Sampling a container's whole area would give the
            // average of its children and paint its border a colour belonging to none of them.
            guard !node.stroke else { return node }

            let sampled = sample(
                pixels,
                left: Int(Double(node.left) * scaleX),
                top: Int(Double(node.top) * scaleY),
                right: Int(Double(node.right) * scaleX),
                bottom: Int(Double(node.bottom) * scaleY),
                histogram: &histogram,
                touched: &touched
            )
            // Nothing sampled — a node off screen, or thinner than nothing. Keeping the palette colour is
            // better than painting it transparent.
            guard let sampled else { return node }

            return SkeletonNode(
                left: node.left,
                top: node.top,
                right: node.right,
                bottom: node.bottom,
                kind: node.kind,
                color: sampled,
                stroke: node.stroke
            )
        }
        return SkeletonFrame(
            width: frame.width,
            height: frame.height,
            background: frame.background,
            nodes: recoloured
        )
    }

    /// One rectangle's colour as the wire format's hex, or nil if it covers no pixels.
    private static func sample<Pixels: PixelSource>(
        _ pixels: Pixels,
        left: Int,
        top: Int,
        right: Int,
        bottom: Int,
        histogram: inout [Int],
        touched: inout [Int]
    ) -> String? {
        let x0 = min(max(left, 0), pixels.width - 1)
        let y0 = min(max(top, 0), pixels.height - 1)
        // At least one pixel wide and tall. A hairline divider is thinner than the stride and would
        // otherwise sample nothing at all.
        let x1 = min(max(right, x0 + 1), pixels.width)
        let y1 = min(max(bottom, y0 + 1), pixels.height)

        var totalRed = 0, totalGreen = 0, totalBlue = 0
        var counted = 0
        var used = 0

        var y = y0
        while y < y1 {
            var x = x0
            while x < x1 {
                let (red, green, blue) = pixels.rgb(x: x, y: y)
                totalRed += Int(red)
                totalGreen += Int(green)
                totalBlue += Int(blue)
                counted += 1

                let bucket = (Int(red) >> levelsShift) << 10
                    | (Int(green) >> levelsShift) << 5
                    | (Int(blue) >> levelsShift)
                if histogram[bucket] == 0 {
                    touched[used] = bucket
                    used += 1
                }
                histogram[bucket] += 1

                x += stride
            }
            y += stride
        }

        guard counted > 0 else { return nil }

        var best = 0
        var bestCount = 0
        for index in 0..<used {
            let bucket = touched[index]
            if histogram[bucket] > bestCount {
                bestCount = histogram[bucket]
                best = bucket
            }
            histogram[bucket] = 0
        }

        if Double(bestCount) / Double(counted) >= dominance {
            // Mid-bucket rather than its floor, so a white surface comes back white instead of very
            // slightly grey.
            //
            // Parenthesised past the point of taste, because this is where a port of the Kotlin goes
            // wrong without a word: Swift binds `<<` tighter than `+`, Kotlin's `shl` binds looser, so
            // the same characters mean `(a << b) + c` here and `a << (b + c)` there.
            let half = 1 << (levelsShift - 1)
            return hex(
                red: (((best >> 10) & 0x1F) << levelsShift) + half,
                green: (((best >> 5) & 0x1F) << levelsShift) + half,
                blue: ((best & 0x1F) << levelsShift) + half
            )
        }
        return hex(
            red: totalRed / counted,
            green: totalGreen / counted,
            blue: totalBlue / counted
        )
    }

    /// `#RRGGBB`, which is what the wire format takes and what the renderer parses.
    private static func hex(red: Int, green: Int, blue: Int) -> String {
        String(
            format: "#%02X%02X%02X",
            min(max(red, 0), 255),
            min(max(green, 0), 255),
            min(max(blue, 0), 255)
        )
    }
}

/// Somewhere to read pixels from, so the reduction can be tested without a device.
///
/// The Android original takes an `IntArray` and is tested on the JVM for exactly this reason — needing a
/// `Bitmap` to test a weighted average would have meant not testing it. This is the same idea shaped for
/// the two callers iOS has: an array in the tests, and CoreGraphics' own buffer in production, which is
/// read in place rather than copied. A screen's bitmap is around 12 MB and the sampling touches a
/// sixteenth of it.
protocol PixelSource {
    var width: Int { get }
    var height: Int { get }
    /// The pixel at `x`, `y`. Callers stay inside `width` and `height`.
    func rgb(x: Int, y: Int) -> (UInt8, UInt8, UInt8)
}

/// Pixels held as one array, in `0xRRGGBB` order. What the tests use.
struct ArrayPixels: PixelSource {
    let width: Int
    let height: Int
    let pixels: [UInt32]

    @inline(__always)
    func rgb(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        let pixel = pixels[y * width + x]
        return (UInt8((pixel >> 16) & 0xFF), UInt8((pixel >> 8) & 0xFF), UInt8(pixel & 0xFF))
    }
}

#if canImport(UIKit)
import CoreGraphics

/// CoreGraphics' own buffer, read in place.
///
/// Not a copy: `CGDataProviderCopyData` on a screen-sized bitmap is around 12 MB, and the sampling
/// touches a sixteenth of it. The buffer belongs to the context, so this is only valid for as long as
/// the context is — which is what `BitmapRenderer.withPixels` exists to guarantee.
struct ContextPixels: PixelSource {
    let width: Int
    let height: Int
    /// Bytes per row, which CoreGraphics chooses and which is **not** `width * 4`. It pads rows to a
    /// stride it likes, and assuming otherwise reads a picture that slowly shears across the screen.
    let bytesPerRow: Int
    let base: UnsafePointer<UInt8>

    /// `noneSkipLast` over device RGB, so a pixel is R, G, B and one byte nobody wrote.
    @inline(__always)
    func rgb(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        let pixel = base + y * bytesPerRow + x * 4
        return (pixel[0], pixel[1], pixel[2])
    }
}
#endif
