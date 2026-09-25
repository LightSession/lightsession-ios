import Foundation

/// Mask rectangles handed in by an embedder, for screens the view walk cannot read.
///
/// ## Why an embedder gets a say at all
///
/// `MaskGeometry` finds what to cover by walking the view tree, and a toolkit that paints into a
/// layer of its own — Flutter draws its whole screen into one `FlutterView` backed by Metal — gives
/// that walk one node with nothing in it. The walk succeeds, covers nothing, and the capture ships
/// every word on the screen: `drawHierarchy` does composite the Metal content, so the picture is the
/// real screen. The only party that knows where the text on such a screen is, is the toolkit that
/// painted it, so it says so through this.
///
/// ## Which frame the pixels are
///
/// Rectangles are only true of the frame they were measured on, and the embedder's report and its
/// pixels do not arrive together. Flutter reports a frame's rectangles the moment the frame is handed
/// to its raster thread — *before* it is on screen — and the raster thread keeps a pipeline: while
/// frame `g` is reported, the screen can still show `g - 1`, or `g - 2`. A capture that covered
/// frame `g`'s rectangles on frame `g - 1`'s pixels would put the masks where the text is going
/// while the text is still where it was.
///
/// So a plan names the oldest frame its pixels could be, and a frame ships only when every report
/// from that one on carried exactly the planned rectangles. Two frames back while frames are still
/// arriving; the planned frame itself once none has arrived for [drainedAfterMillis], because by
/// then the pipeline has put it on screen. A screen whose masks move every frame — a scroll — loses
/// its frames while it moves, which is the point: nothing can say where its text is in the pixels.
/// A screen that repaints with its masks still — a spinner, a map — keeps them.
///
/// ## Invalid is not empty
///
/// [set] with nil rectangles means the embedder tried to measure its screen and failed. From that
/// moment every capture is refused until a good report arrives, because the alternative is shipping
/// pixels whose masks are unknown. An *empty* list is different and legitimate: a screen with
/// nothing to cover.
///
/// Rectangles are in the window's coordinate space, in points, as `MaskGeometry`'s are.
public enum SuppliedMasks {

    /// Frames the raster pipeline can be behind the latest report. Two: one being drawn, one queued.
    static let pipelineDepth: Int64 = 2

    /// How long after a report, with no newer one, its frame is taken to be on screen.
    ///
    /// 150 ms, down from 500, and measured both ways with the Flutter example's list on a simulator.
    /// The wait is what a screen that moves now and then pays: at 500 ms a list jumping every 700 ms
    /// shipped 8 distinct frames to the replay, against 22 with no rule at all; at 150 ms, 24. And it
    /// still covers a raster thread far behind: with the list made to take 40 ms a frame at the
    /// median, 60 ms at p95, every frame over budget, no rule left 8 frames with text showing beside
    /// its masks, and 150 ms left none, twice. A raster slower than this can still outrun it — so
    /// can one slower than 500 ms, and the check after the capture is what stands behind both.
    static let drainedAfterMillis: Int64 = 150

    struct Report: Equatable {
        let generation: Int64
        /// Nil means the embedder could not measure this frame — refuse, see above.
        let rects: [Rect]?
        /// The first generation of the unbroken run of reports, ending with this one, that all
        /// carried exactly these rectangles.
        let sameSince: Int64
        let arrivedAtMillis: Int64
    }

    /// The rectangles a capture covers, and the frames its pixels may come from.
    struct Plan: Equatable {
        let generation: Int64
        let rects: [Rect]
        /// The oldest generation whose pixels this capture may hold.
        let oldestOnScreen: Int64
    }

    /// What to do with the embedder's report for a capture about to be taken.
    enum Decision: Equatable {
        /// No embedder has spoken: the walk is the whole answer.
        case none
        /// Cover these as well, and check [stillHolds] once the pixels are taken.
        case cover(Plan)
        /// Take no picture now: the report could not measure, or its rectangles are still moving.
        case refuse
    }

    /// Wall clock in milliseconds. Here rather than borrowed, because the clocks elsewhere in the SDK
    /// sit behind UIKit and this has to be testable without it.
    static func nowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private static let lock = NSLock()
    private static var current: Report?

    /// Replaces the standing report.
    ///
    /// - Parameters:
    ///   - generation: strictly increasing per painted frame on the embedder's side.
    ///   - rects: what to cover, in window points; empty when the screen holds nothing coverable,
    ///     nil when the embedder could not measure this frame.
    public static func set(generation: Int64, rects: [Rect]?) {
        set(generation: generation, rects: rects, nowMillis: nowMillis())
    }

    static func set(generation: Int64, rects: [Rect]?, nowMillis: Int64) {
        lock.lock()
        defer { lock.unlock() }
        let previous = current
        let unchanged = previous != nil && rects != nil && previous?.rects == rects
            && generation > previous!.generation
        current = Report(
            generation: generation,
            rects: rects,
            sameSince: unchanged ? previous!.sameSince : generation,
            arrivedAtMillis: nowMillis
        )
    }

    /// Forgets the standing report; the walk is authoritative again.
    public static func clear() {
        lock.lock()
        defer { lock.unlock() }
        current = nil
    }

    /// The decision for a capture taken now.
    static func plan(nowMillis: Int64 = nowMillis()) -> Decision {
        lock.lock()
        defer { lock.unlock() }
        guard let report = current else { return .none }
        guard let rects = report.rects else { return .refuse }
        let drained = nowMillis - report.arrivedAtMillis >= drainedAfterMillis
        let oldest = drained ? report.generation : report.generation - pipelineDepth
        // The pixels may be any frame from `oldest` on; every one of them has to have carried these
        // rectangles, or some part of the picture is uncovered.
        guard report.sameSince <= oldest else { return .refuse }
        return .cover(Plan(generation: report.generation, rects: rects, oldestOnScreen: oldest))
    }

    /// Whether the pixels taken for [plan] are still covered by it: every report that arrived since
    /// carried the same rectangles as all the frames the pixels could be.
    ///
    /// Asked after the capture, once reports that were already on their way have landed — see the
    /// replay's check. Not moved only when the run of identical rectangles still reaches back to the
    /// oldest frame the pixels could be; an embedder that stopped reporting, one whose latest report
    /// could not measure, and one whose count went backwards all count as moved.
    static func stillHolds(_ plan: Plan) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let now = current, now.rects != nil else { return false }
        if now.generation < plan.generation { return false }
        return now.sameSince <= plan.oldestOnScreen
    }
}
