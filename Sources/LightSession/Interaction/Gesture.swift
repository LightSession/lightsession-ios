import Foundation

/// One touch in a gesture, in the coordinate space that goes on the wire.
public struct TouchPoint: Equatable, Sendable {
    /// Device pixels, not points.
    ///
    /// This is the detail most likely to be wrong in a way nothing complains about. A heatmap is drawn
    /// over a capture, and captures are in pixels — so a gesture recorded in points would land every
    /// touch in the top-left third of a 3× screen, producing a heatmap that looks plausible and is
    /// wrong. Android has no equivalent trap because a `MotionEvent` is already in pixels.
    public var x: Double
    public var y: Double
    /// Milliseconds since the epoch, matching the server's clock field.
    public var timestampMillis: Int64

    public init(x: Double, y: Double, timestampMillis: Int64) {
        self.x = x
        self.y = y
        self.timestampMillis = timestampMillis
    }
}

/// What kind of gesture a set of points turned out to be.
public enum GestureKind: String, Equatable, Sendable {
    case tap = "TAP"
    case swipe = "SWIPE"
}

/// Accumulates the points of one gesture and decides what it was.
///
/// Pure, so the rules can be tested without touching a screen. They are the same rules the Android SDK
/// uses, deliberately: the two platforms write into one heatmap, and a tap that is a tap on Android and a
/// swipe on iOS would make the same product feature mean two things.
public struct GestureRecorder {

    /// How far a finger must travel before another point is kept.
    ///
    /// A drag delivers an event for every pixel travelled and a heatmap does not need them. Ten is
    /// Android's threshold and it is in the wire's unit, pixels.
    public static let minPointDistance: Double = 10

    private(set) public var points: [TouchPoint] = []
    private(set) public var isTracking = false

    public init() {}

    public mutating func begin(at point: TouchPoint) {
        points = [point]
        isTracking = true
    }

    /// Records an intermediate point if it is far enough from the last one kept.
    public mutating func move(to point: TouchPoint) {
        guard isTracking else { return }
        if isFarEnough(point) {
            points.append(point)
        }
    }

    /// Ends the gesture and returns it, or `nil` if there was nothing being tracked.
    public mutating func end(at point: TouchPoint) -> Gesture? {
        guard isTracking else { return nil }
        isTracking = false
        if isFarEnough(point) {
            points.append(point)
        }
        let captured = points
        points = []
        guard let first = captured.first, let last = captured.last else { return nil }
        return Gesture(
            // One point means the finger never travelled far enough to record a second, which is what a
            // tap is. Anything else is a swipe. Distance is not measured again here: the point filter
            // above has already applied it, and applying it twice with different thresholds is how two
            // definitions of "tap" come to exist.
            kind: captured.count == 1 ? .tap : .swipe,
            points: captured,
            startMillis: first.timestampMillis,
            endMillis: last.timestampMillis
        )
    }

    /// Throws the gesture away.
    ///
    /// Used when a touch is cancelled, and when recording is turned off mid-gesture. Dropped rather than
    /// kept: points left in the buffer would be sent as part of whatever gesture came next, which is a
    /// swipe stitched together from two different moments.
    public mutating func cancel() {
        points = []
        isTracking = false
    }

    private func isFarEnough(_ point: TouchPoint) -> Bool {
        guard let last = points.last else { return true }
        let dx = point.x - last.x
        let dy = point.y - last.y
        return (dx * dx + dy * dy).squareRoot() > Self.minPointDistance
    }
}

/// A finished gesture.
public struct Gesture: Equatable, Sendable {
    public let kind: GestureKind
    public let points: [TouchPoint]
    public let startMillis: Int64
    public let endMillis: Int64

    public var durationMillis: Int64 { endMillis - startMillis }

    public init(kind: GestureKind, points: [TouchPoint], startMillis: Int64, endMillis: Int64) {
        self.kind = kind
        self.points = points
        self.startMillis = startMillis
        self.endMillis = endMillis
    }
}
