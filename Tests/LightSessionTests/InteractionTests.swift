import XCTest
@testable import LightSession

/// Gesture classification, which has to agree with Android's byte for byte.
///
/// The two platforms write into one heatmap. A gesture that is a tap on one and a swipe on the other would
/// make the same product feature mean two different things depending on the phone.
final class GestureRecorderTests: XCTestCase {

    private func point(_ x: Double, _ y: Double, _ t: Int64 = 0) -> TouchPoint {
        TouchPoint(x: x, y: y, timestampMillis: t)
    }

    func testAFingerThatDoesNotTravelIsATap() {
        var recorder = GestureRecorder()
        recorder.begin(at: point(100, 200, 1_000))
        // Well inside the 10-pixel threshold: a real tap always jitters a little.
        recorder.move(to: point(103, 202, 1_020))
        let gesture = recorder.end(at: point(104, 203, 1_060))
        XCTAssertEqual(gesture?.kind, .tap)
        XCTAssertEqual(gesture?.points.count, 1, "jitter must not turn a tap into a two-point swipe")
        XCTAssertEqual(gesture?.durationMillis, 0, "a one-point gesture spans one instant")
    }

    func testAFingerThatTravelsIsASwipe() {
        var recorder = GestureRecorder()
        recorder.begin(at: point(100, 900, 1_000))
        recorder.move(to: point(100, 700, 1_050))
        recorder.move(to: point(100, 500, 1_100))
        let gesture = recorder.end(at: point(100, 300, 1_150))
        XCTAssertEqual(gesture?.kind, .swipe)
        XCTAssertEqual(gesture?.points.count, 4)
        XCTAssertEqual(gesture?.durationMillis, 150)
    }

    /// A drag delivers an event per pixel travelled, and a heatmap does not need them.
    func testPointsCloserThanTheThresholdAreDropped() {
        var recorder = GestureRecorder()
        recorder.begin(at: point(0, 0))
        for y in stride(from: 1.0, through: 9.0, by: 1.0) {
            recorder.move(to: point(0, y))
        }
        let gesture = recorder.end(at: point(0, 9))
        XCTAssertEqual(gesture?.points.count, 1, "nine sub-threshold moves are still one point")
        XCTAssertEqual(gesture?.kind, .tap)
    }

    func testACancelledGestureProducesNothing() {
        var recorder = GestureRecorder()
        recorder.begin(at: point(0, 0))
        recorder.move(to: point(0, 100))
        recorder.cancel()
        XCTAssertNil(recorder.end(at: point(0, 200)))
    }

    /// Points left behind after a cancel would be sent as the start of the next gesture — a swipe stitched
    /// together from two different moments.
    func testTheNextGestureDoesNotInheritACancelledOne() {
        var recorder = GestureRecorder()
        recorder.begin(at: point(0, 0))
        recorder.move(to: point(0, 500))
        recorder.cancel()

        recorder.begin(at: point(700, 700))
        let gesture = recorder.end(at: point(702, 701))
        XCTAssertEqual(gesture?.kind, .tap)
        XCTAssertEqual(gesture?.points.first?.x, 700)
    }

    func testMovesWithoutABeginAreIgnored() {
        var recorder = GestureRecorder()
        recorder.move(to: point(10, 10))
        XCTAssertNil(recorder.end(at: point(20, 20)), "a touch the SDK never saw begin is not a gesture")
    }
}

/// Which session an event belongs to, and when that changes.
final class SessionIdentityTests: XCTestCase {

    private func identity(timeout: Int64 = 30_000) -> SessionIdentity {
        SessionIdentity(sessionId: "first", anonymousId: "anon", startedAtMillis: 0, idleTimeoutMillis: timeout)
    }

    func testActivityInsideTheTimeoutKeepsTheSession() {
        var session = identity()
        let result = session.touch(nowMillis: 29_999) { "second" }
        XCTAssertEqual(result.id, "first")
        XCTAssertFalse(result.rotated)
    }

    /// Exactly the timeout counts as expired, because the server's reaper has already taken it: attaching
    /// events to it would file them against a row that is closed.
    func testTheSessionRotatesAtExactlyTheTimeout() {
        var session = identity()
        let result = session.touch(nowMillis: 30_000) { "second" }
        XCTAssertEqual(result.id, "second")
        XCTAssertTrue(result.rotated)
    }

    func testActivityExtendsTheWindowRatherThanCountingFromTheStart() {
        var session = identity()
        session.touch(nowMillis: 20_000) { "second" }
        // 20s after the last touch, 40s after the session began. Still the same session.
        let result = session.touch(nowMillis: 40_000) { "third" }
        XCTAssertEqual(result.id, "first")
    }

    func testAnonymousUntilIdentified() {
        var session = identity()
        XCTAssertEqual(session.userType, .anonymous)
        XCTAssertEqual(session.reportedUserId, "anon")

        session.identify(userId: "person-7")
        XCTAssertEqual(session.userType, .identified)
        XCTAssertEqual(session.reportedUserId, "person-7")
    }

    /// The device is the same device. A fresh anonymous id would make one person look like two.
    func testResetKeepsTheInstallsOwnId() {
        var session = identity()
        session.identify(userId: "person-7")
        session.reset()
        XCTAssertEqual(session.userType, .anonymous)
        XCTAssertEqual(session.reportedUserId, "anon")
    }
}

/// When a batch goes out, and what is in it.
final class BreadcrumbBatchTests: XCTestCase {

    private func event(sequence: Int, kind: GestureKind = .tap, screenId: String? = "cap-1") -> InteractionEvent {
        InteractionEvent(
            gesture: Gesture(
                kind: kind,
                points: [TouchPoint(x: 10, y: 20, timestampMillis: 1_000)],
                startMillis: 1_000,
                endMillis: 1_050
            ),
            screen: "Home",
            screenId: screenId,
            sequence: sequence,
            userId: "anon",
            userType: .anonymous,
            appVersion: "1.0"
        )
    }

    func testAnEmptyBufferNeverFlushes() {
        let batcher = BreadcrumbBatcher()
        XCTAssertFalse(batcher.shouldFlush(nowMillis: 999_999))
    }

    func testCountTrigger() {
        var batcher = BreadcrumbBatcher(flushAtCount: 3, flushAfterMillis: 60_000)
        batcher.add(event(sequence: 1), nowMillis: 0)
        batcher.add(event(sequence: 2), nowMillis: 0)
        XCTAssertFalse(batcher.shouldFlush(nowMillis: 0))
        batcher.add(event(sequence: 3), nowMillis: 0)
        XCTAssertTrue(batcher.shouldFlush(nowMillis: 0))
    }

    /// Without an age trigger the last few events of a session sit in memory until the next touch — and the
    /// last few are the ones before the person gave up.
    func testAgeTriggerSendsASmallBatch() {
        var batcher = BreadcrumbBatcher(flushAtCount: 100, flushAfterMillis: 5_000)
        batcher.add(event(sequence: 1), nowMillis: 1_000)
        XCTAssertFalse(batcher.shouldFlush(nowMillis: 5_999))
        XCTAssertTrue(batcher.shouldFlush(nowMillis: 6_000))
    }

    func testDrainClearsTheBufferAndNumbersTheBatch() {
        var batcher = BreadcrumbBatcher(flushAtCount: 1)
        batcher.add(event(sequence: 1), nowMillis: 0)
        XCTAssertEqual(batcher.drain(nowMillis: 0).count, 1)
        XCTAssertTrue(batcher.pending.isEmpty)
        XCTAssertEqual(batcher.batchNumber, 1)
        XCTAssertFalse(batcher.shouldFlush(nowMillis: 999_999), "a drained buffer has nothing to send")
    }

    /// Reached only when uploads have been failing for a long time. The recent events describe what the
    /// person is doing now, which is what a session is watched for.
    func testTheOldestEventsAreDroppedWhenTheBufferIsFull() {
        var batcher = BreadcrumbBatcher(flushAtCount: 10_000, maxBuffered: 3)
        for i in 1...5 { batcher.add(event(sequence: i), nowMillis: 0) }
        XCTAssertEqual(batcher.pending.map(\.sequence), [3, 4, 5])
        XCTAssertEqual(batcher.droppedCount, 2)
    }

    // MARK: - Payload

    func testTheBatchCarriesEverythingTheServerReads() throws {
        let fields = try XCTUnwrap(breadcrumbBatchFields(
            events: [event(sequence: 1)],
            sessionId: "session-1",
            userId: "anon",
            userType: .anonymous,
            appVersion: "1.0",
            batchNumber: 4,
            timestampMillis: 1_700,
            deviceInfo: ["platform": "ios"],
            appInfo: ["version": "1.0"]
        ))
        XCTAssertEqual(fields["type"], "breadcrumb_batch")
        // The two the ingest service refuses a batch without.
        XCTAssertEqual(fields["session_id"], "session-1")
        XCTAssertNotNil(fields["breadcrumbs"])
        XCTAssertEqual(fields["batch_number"], "4")
        XCTAssertEqual(fields["user_type"], "anonymous")
    }

    /// A breadcrumb's own `type` is "interaction", so the gesture's kind has to travel as
    /// `interaction_type`. Android renames the key while merging, and matching that rename is what makes an
    /// iOS touch and an Android touch the same row.
    func testTheGestureKindTravelsAsInteractionType() throws {
        let crumb = event(sequence: 1, kind: .swipe).breadcrumb
        XCTAssertEqual(crumb["type"] as? String, "interaction")
        XCTAssertEqual(crumb["interaction_type"] as? String, "SWIPE")
    }

    func testPointsCarryTheirOffsetFromTheGesturesStart() throws {
        let gesture = Gesture(
            kind: .swipe,
            points: [
                TouchPoint(x: 0, y: 0, timestampMillis: 1_000),
                TouchPoint(x: 0, y: 100, timestampMillis: 1_120),
            ],
            startMillis: 1_000,
            endMillis: 1_120
        )
        let crumb = InteractionEvent(
            gesture: gesture, screen: "Home", screenId: nil, sequence: 1,
            userId: "anon", userType: .anonymous, appVersion: "1.0"
        ).breadcrumb
        let points = try XCTUnwrap(crumb["points"] as? [[String: Any]])
        XCTAssertEqual(points[0]["time_since_start"] as? Int64, 0)
        XCTAssertEqual(points[1]["time_since_start"] as? Int64, 120)
    }

    /// Android sent a missing screen id as the literal string "null" and stored it as one. Absent means
    /// absent.
    func testAnUnknownCaptureIsOmittedRatherThanSentAsAPlaceholder() {
        let crumb = event(sequence: 1, screenId: nil).breadcrumb
        XCTAssertNil(crumb["screen_id"])
    }

    func testTheBatchIsOrderedBySequenceRatherThanByArrival() throws {
        let fields = try XCTUnwrap(breadcrumbBatchFields(
            events: [event(sequence: 3), event(sequence: 1), event(sequence: 2)],
            sessionId: "s", userId: "u", userType: .anonymous, appVersion: "1.0",
            batchNumber: 1, timestampMillis: 0, deviceInfo: [:], appInfo: [:]
        ))
        let data = try XCTUnwrap(fields["breadcrumbs"]?.data(using: .utf8))
        let crumbs = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(crumbs.compactMap { $0["sequence"] as? Int }, [1, 2, 3])
    }
}

/// The screen-change breadcrumb, which is not the same thing as the graph's edge.
///
/// Written after measuring: a replay of 168 frames arrived with `navigation_count = 0`, because the flows had
/// gone to the product API and nothing had gone to the session's timeline. Every frame was there and nothing
/// said where one screen ended and the next began.
final class NavigationEventTests: XCTestCase {

    private func event(from: String = "Home", to: String = "Form") -> NavigationEvent {
        NavigationEvent(
            from: from, to: to, screenKind: .uiKit, transition: "appear",
            sequence: 4, timestampMillis: 1_700, userId: "anon", userType: .anonymous, appVersion: "1.0"
        )
    }

    /// A navigation's fields sit one level down while an interaction's are flat. Nobody would design that; it
    /// is what the worker parses.
    func testTheFieldsAreNestedUnderData() throws {
        let crumb = event().breadcrumb
        XCTAssertEqual(crumb["type"] as? String, "navigation")
        let data = try XCTUnwrap(crumb["data"] as? [String: Any])
        XCTAssertEqual(data["from"] as? String, "Home")
        XCTAssertEqual(data["to"] as? String, "Form")
        XCTAssertEqual(data["screenType"] as? String, "UIKIT")
        XCTAssertEqual(data["transitionType"] as? String, "appear")
    }

    /// Touches and screen changes share one counter, so a tap that happened between two screens is
    /// reconstructible as having happened between them.
    func testBothKindsShareOneOrderedBatch() throws {
        let tap = InteractionEvent(
            gesture: Gesture(
                kind: .tap,
                points: [TouchPoint(x: 1, y: 2, timestampMillis: 10)],
                startMillis: 10, endMillis: 10
            ),
            screen: "Home", screenId: nil, sequence: 2,
            userId: "anon", userType: .anonymous, appVersion: "1.0"
        )
        let fields = try XCTUnwrap(breadcrumbBatchFields(
            events: [event(), tap],
            sessionId: "s", userId: "anon", userType: .anonymous, appVersion: "1.0",
            batchNumber: 1, timestampMillis: 0, deviceInfo: [:], appInfo: [:]
        ))
        let data = try XCTUnwrap(fields["breadcrumbs"]?.data(using: .utf8))
        let crumbs = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(crumbs.compactMap { $0["type"] as? String }, ["interaction", "navigation"],
                       "sequence 2 before sequence 4, whatever order they were buffered in")
    }
}

/// The recording switch.
///
/// One switch read by every producer, because a flag per recorder is two flags that can disagree — and the one
/// that disagrees is the one still recording after someone asked it not to.
final class RecordingSwitchTests: XCTestCase {

    override func tearDown() {
        // Shared state, so it is put back: a test that leaves recording off silently disables the next one.
        Recording.shared.start()
        super.tearDown()
    }

    /// An app that installed a recorder and called nothing expects it to record. Opt-in would mean an SDK that
    /// looks installed and captures nothing, which is the failure that takes longest to notice.
    func testRecordingIsOnByDefault() {
        XCTAssertTrue(Recording.shared.isEnabled)
    }

    func testStoppingAndResuming() {
        XCTAssertTrue(Recording.shared.stop(), "the first stop is a change")
        XCTAssertFalse(Recording.shared.isEnabled)
        XCTAssertTrue(Recording.shared.start())
        XCTAssertTrue(Recording.shared.isEnabled)
    }

    /// The return value says whether anything changed, so a caller can log a transition rather than a repeat —
    /// an app calling `startRecording` on every screen is a normal thing to do.
    func testARepeatedCallReportsNoChange() {
        XCTAssertFalse(Recording.shared.start(), "already recording")
        Recording.shared.stop()
        XCTAssertFalse(Recording.shared.stop(), "already stopped")
    }
}
