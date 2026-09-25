import XCTest
@testable import LightSession

/// The rules a capture follows with an embedder's mask report — when it covers, when it refuses, and
/// when pixels it took are still covered.
final class SuppliedMasksTests: XCTestCase {

    private let a = [Rect(left: 0, top: 0, right: 100, bottom: 20)]
    private let b = [Rect(left: 0, top: 40, right: 100, bottom: 60)]

    override func tearDown() {
        // Process-wide state: a report left here would reach every later test.
        SuppliedMasks.clear()
        super.tearDown()
    }

    func testNoEmbedderIsNoDecision() {
        XCTAssertEqual(SuppliedMasks.plan(nowMillis: 0), .none)
    }

    func testAReportThatCouldNotMeasureRefuses() {
        SuppliedMasks.set(generation: 1, rects: nil, nowMillis: 0)
        XCTAssertEqual(SuppliedMasks.plan(nowMillis: 10_000), .refuse)
    }

    func testAnEmptyReportIsACleanScreen() {
        SuppliedMasks.set(generation: 1, rects: [], nowMillis: 0)
        guard case .cover(let plan) = SuppliedMasks.plan(nowMillis: 10_000) else {
            return XCTFail("an empty report is a screen with nothing to cover, not a failure")
        }
        XCTAssertEqual(plan.rects, [])
    }

    /// The frame just reported may not be on screen yet, and the two before it may be: while frames
    /// are arriving, all three have to agree.
    func testWhileFramesArriveThePipelineHasToAgree() {
        SuppliedMasks.set(generation: 1, rects: a, nowMillis: 0)
        SuppliedMasks.set(generation: 2, rects: a, nowMillis: 16)
        XCTAssertEqual(
            SuppliedMasks.plan(nowMillis: 20), .refuse,
            "frame 0's pixels could still be on screen, and nothing says where its text was"
        )
        SuppliedMasks.set(generation: 3, rects: a, nowMillis: 32)
        guard case .cover(let plan) = SuppliedMasks.plan(nowMillis: 36) else {
            return XCTFail("three frames with the same rectangles cover whatever is on screen")
        }
        XCTAssertEqual(plan.rects, a)
        XCTAssertEqual(plan.oldestOnScreen, 1)
    }

    func testAMoveRefusesUntilThePipelineHasCaughtUp() {
        for generation in 1...5 {
            SuppliedMasks.set(generation: Int64(generation), rects: a, nowMillis: Int64(generation) * 16)
        }
        SuppliedMasks.set(generation: 6, rects: b, nowMillis: 96)
        XCTAssertEqual(
            SuppliedMasks.plan(nowMillis: 100), .refuse,
            "frame 6 moved; frames 4 and 5 may be what the screen shows"
        )
        SuppliedMasks.set(generation: 7, rects: b, nowMillis: 112)
        XCTAssertEqual(SuppliedMasks.plan(nowMillis: 116), .refuse)
        SuppliedMasks.set(generation: 8, rects: b, nowMillis: 128)
        guard case .cover = SuppliedMasks.plan(nowMillis: 130) else {
            return XCTFail("frames 6, 7 and 8 agree")
        }
    }

    /// A screen that painted once and then stopped — an app sitting on a still screen — is on screen
    /// by now, and has to be capturable.
    func testAStillScreenIsCoveredOnceThePipelineHasDrained() {
        let drained = SuppliedMasks.drainedAfterMillis
        SuppliedMasks.set(generation: 1, rects: a, nowMillis: 0)
        XCTAssertEqual(SuppliedMasks.plan(nowMillis: drained - 1), .refuse, "frame 1 may not be on screen yet")
        guard case .cover(let plan) = SuppliedMasks.plan(nowMillis: drained) else {
            return XCTFail("no new frame for the whole wait: frame 1 is what the screen shows")
        }
        XCTAssertEqual(plan.oldestOnScreen, 1)
    }

    /// The wait is what a screen that moves now and then pays, so it is held to what was measured:
    /// at 500 ms a list jumping every 700 ms kept 8 of its 22 distinct frames.
    func testAScreenThatMovesEveryFewHundredMillisecondsIsCapturedBetweenMoves() {
        SuppliedMasks.set(generation: 1, rects: a, nowMillis: 0)
        guard case .cover = SuppliedMasks.plan(nowMillis: 200) else {
            return XCTFail("200 ms after a jump, with nothing painted since, is a frame to take")
        }
    }

    func testPixelsStayCoveredWhileLaterFramesKeepTheRectangles() {
        for generation in 1...3 {
            SuppliedMasks.set(generation: Int64(generation), rects: a, nowMillis: Int64(generation) * 16)
        }
        guard case .cover(let plan) = SuppliedMasks.plan(nowMillis: 50) else { return XCTFail() }
        SuppliedMasks.set(generation: 4, rects: a, nowMillis: 64)
        XCTAssertTrue(SuppliedMasks.stillHolds(plan), "a spinner turning, a map redrawing")
        SuppliedMasks.set(generation: 5, rects: b, nowMillis: 80)
        XCTAssertFalse(SuppliedMasks.stillHolds(plan), "frame 5 may be what was copied, with its text elsewhere")
    }

    func testRectanglesBackWhereTheyWereStillCountAsMoved() {
        for generation in 1...3 {
            SuppliedMasks.set(generation: Int64(generation), rects: a, nowMillis: Int64(generation) * 16)
        }
        guard case .cover(let plan) = SuppliedMasks.plan(nowMillis: 50) else { return XCTFail() }
        SuppliedMasks.set(generation: 4, rects: b, nowMillis: 64)
        SuppliedMasks.set(generation: 5, rects: a, nowMillis: 80)
        XCTAssertFalse(SuppliedMasks.stillHolds(plan), "frame 4 had them elsewhere and may be the one copied")
    }

    func testAnEmbedderThatStoppedFailedOrRestartedCountsAsMoved() {
        for generation in 1...3 {
            SuppliedMasks.set(generation: Int64(generation), rects: a, nowMillis: Int64(generation) * 16)
        }
        guard case .cover(let plan) = SuppliedMasks.plan(nowMillis: 50) else { return XCTFail() }

        SuppliedMasks.set(generation: 4, rects: nil, nowMillis: 64)
        XCTAssertFalse(SuppliedMasks.stillHolds(plan), "a report that could not measure")

        SuppliedMasks.set(generation: 1, rects: a, nowMillis: 80)
        XCTAssertFalse(SuppliedMasks.stillHolds(plan), "a count that went backwards is tied to nothing")

        SuppliedMasks.clear()
        XCTAssertFalse(SuppliedMasks.stillHolds(plan), "an embedder that stopped reporting")
    }
}
