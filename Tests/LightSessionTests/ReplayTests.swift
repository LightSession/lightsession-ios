import XCTest
@testable import LightSession

/// The capture rate, which is two rates for a reason.
final class CaptureCadenceTests: XCTestCase {

    private let cadence = CaptureCadence(
        idleMillis: 1_000, burstMillis: 100, burstQuietMillis: 250, burstMaxMillis: 5_000
    )

    func testIdleByDefault() {
        XCTAssertEqual(cadence.delay(CaptureCadence.Burst(), nowMillis: 0), 1_000)
    }

    func testATouchOpensTheFastInterval() {
        let burst = cadence.touched(CaptureCadence.Burst(), nowMillis: 1_000)
        XCTAssertEqual(cadence.delay(burst, nowMillis: 1_000), 100)
    }

    func testTheFastIntervalLapsesAfterTheQuietPeriod() {
        let burst = cadence.touched(CaptureCadence.Burst(), nowMillis: 1_000)
        XCTAssertEqual(cadence.delay(burst, nowMillis: 1_249), 100)
        XCTAssertEqual(cadence.delay(burst, nowMillis: 1_250), 1_000, "a finger lifted 250 ms ago is idle")
    }

    /// What the ceiling actually does, which is not what its name suggests.
    ///
    /// It bounds one *window*, not bursting overall: at the ceiling the window lapses, and the next touch
    /// opens a fresh one. So an endless scroll gets a slow tick every few seconds rather than either holding
    /// the fast interval for ever or being limited to a single burst. Android is identical. The first version
    /// of this test asserted the obvious reading — that a six-second scroll ends up idle — and failed.
    func testTheCeilingLapsesAWindowRatherThanCappingBurstingOverall() {
        var burst = cadence.touched(CaptureCadence.Burst(), nowMillis: 0)
        // A scroll: a touch every 100 ms, extending the window each time.
        for now in stride(from: Int64(100), through: 4_900, by: 100) {
            burst = cadence.touched(burst, nowMillis: now)
        }
        XCTAssertTrue(cadence.isBursting(burst, nowMillis: 4_999), "still inside the first window")
        XCTAssertFalse(cadence.isBursting(burst, nowMillis: 5_000), "the ceiling lapses it")

        // And the scroll carries on: the next touch opens a new window.
        burst = cadence.touched(burst, nowMillis: 5_000)
        XCTAssertEqual(cadence.delay(burst, nowMillis: 5_100), 100)
    }

    /// A burst slower than idle would make the fast path the slow one.
    func testABurstSlowerThanIdleIsClamped() {
        let odd = CaptureCadence(idleMillis: 500, burstMillis: 2_000)
        XCTAssertLessThanOrEqual(odd.burstMillis, odd.idleMillis)
    }

    /// Nothing more can be captured below one frame at 60 Hz.
    func testAbsurdlyFastBurstsAreClamped() {
        XCTAssertEqual(CaptureCadence(idleMillis: 1_000, burstMillis: 1).burstMillis, 16)
    }
}

/// What goes in a frame batch, and when it goes.
final class FrameBatcherTests: XCTestCase {

    private func frame(_ sequence: Int, bytes: Int = 1_000, isRepeat: Bool = false) -> ReplayFrame {
        ReplayFrame(
            data: isRepeat ? ReplayFrame.repeatSignal : Data(repeating: 0xAB, count: bytes),
            isRepeat: isRepeat,
            sequence: sequence,
            timestampMillis: Int64(1_000 + sequence)
        )
    }

    /// A batch too small to trigger any size threshold still reaches the disk.
    ///
    /// This is the only bound on what an unannounced death costs. Every other trigger is about
    /// size, and a session that never reaches one keeps its frames in memory until the app leaves
    /// the foreground — which a crash, a jetsam kill or a stop from Xcode all skip. Measured in
    /// production before this existed: a 79-second session had 23 real frames against a threshold
    /// of 24 and had never written a batch, and a 9-second session on the same build recorded
    /// nothing at all. The breadcrumb batcher beside this one has always flushed on age; the frame
    /// batcher was the one that did not, and the asymmetry was the bug.
    func testAgeTriggerRescuesASessionTooShortForAnySizeThreshold() {
        var batcher = FrameBatcher(
            flushAtCount: 24, flushAtBytes: 2 * 1024 * 1024, flushAfterSeconds: 30
        )
        batcher.add(frame(1))
        batcher.add(frame(2))

        // Frames are stamped 1_000 + sequence, so the oldest here is at 1_001.
        XCTAssertFalse(
            batcher.shouldFlush(nowMillis: 30_000),
            "just under thirty seconds old, and far from any size threshold"
        )
        XCTAssertTrue(
            batcher.shouldFlush(nowMillis: 31_001),
            "thirty seconds of replay is the most an unannounced death may cost"
        )
        XCTAssertEqual(
            batcher.flushReason(nowMillis: 31_001), .age,
            "the reason has to name the age bound, or there is no evidence it ever fired"
        )
    }

    /// Age is the fallback, not a relabelling of the triggers that pre-empt it.
    func testASizeTriggeredBatchIsNotReportedAsAged() {
        var batcher = FrameBatcher(flushAtCount: 2, flushAtBytes: 10_000_000, flushAfterSeconds: 30)
        batcher.add(frame(1))
        batcher.add(frame(2))
        XCTAssertEqual(batcher.flushReason(nowMillis: 999_999), .count)
    }

    func testAnEmptyBatchIsNeverDueHoweverOld() {
        let batcher = FrameBatcher(flushAfterSeconds: 30)
        XCTAssertFalse(batcher.shouldFlush(nowMillis: 999_999_999))
        XCTAssertEqual(batcher.ageMillis(nowMillis: 999_999_999), 0)
    }

    func testCountTrigger() {
        var batcher = FrameBatcher(flushAtCount: 3, flushAtBytes: 10_000_000)
        batcher.add(frame(1))
        batcher.add(frame(2))
        XCTAssertFalse(batcher.shouldFlush(nowMillis: 1_100))
        batcher.add(frame(3))
        XCTAssertTrue(batcher.shouldFlush(nowMillis: 1_100))
    }

    func testByteTrigger() {
        var batcher = FrameBatcher(flushAtCount: 1_000, flushAtBytes: 2_500)
        batcher.add(frame(1, bytes: 1_000))
        batcher.add(frame(2, bytes: 1_000))
        XCTAssertFalse(batcher.shouldFlush(nowMillis: 1_100))
        batcher.add(frame(3, bytes: 1_000))
        XCTAssertTrue(batcher.shouldFlush(nowMillis: 1_100), "three kilobytes of frames is a batch even if the count is not")
    }

    /// A replay with a gap in the middle still reaches the end, and the end is where "why did they give up"
    /// is answered. Dropping the newest would give a continuous replay that stops before the interesting part.
    func testTheOldestFramesAreShedWhenTheCeilingIsHit() {
        var batcher = FrameBatcher(flushAtCount: 10_000, flushAtBytes: 10_000_000, maxBufferedBytes: 3_000)
        for i in 1...5 { batcher.add(frame(i, bytes: 1_000)) }
        XCTAssertEqual(batcher.pending.map(\.sequence), [3, 4, 5])
        XCTAssertEqual(batcher.shedCount, 2)
    }

    func testDrainClearsTheBufferAndItsByteCount() {
        var batcher = FrameBatcher(flushAtCount: 1)
        batcher.add(frame(1))
        XCTAssertEqual(batcher.drain().count, 1)
        XCTAssertEqual(batcher.bufferedBytes, 0)
        XCTAssertFalse(batcher.shouldFlush(nowMillis: 1_100))
        XCTAssertEqual(batcher.batchNumber, 1)
    }

    // MARK: - The frame itself

    /// These four bytes are the contract. Android sends them, and the server tells a repeat from a frame by
    /// the part's content type and file name.
    func testTheRepeatSignalIsExactlyRPTD() {
        XCTAssertEqual(Array(ReplayFrame.repeatSignal), [0x52, 0x50, 0x54, 0x44])
        XCTAssertEqual(String(data: ReplayFrame.repeatSignal, encoding: .ascii), "RPTD")
    }

    func testFileNamesAndTypesDistinguishARepeatFromAFrame() {
        let real = frame(7)
        XCTAssertEqual(real.fileName, "frame_7_1007.jpg")
        XCTAssertEqual(real.contentType, "image/jpeg")

        let repeated = frame(8, isRepeat: true)
        XCTAssertEqual(repeated.fileName, "repeated_signal_8_1008.signal")
        XCTAssertEqual(repeated.contentType, "application/octet-stream")
    }

    func testPerFrameMetadataNamesTheKind() {
        XCTAssertEqual(frame(1).metadata(index: 0)["frame_type"], "real_frame")
        XCTAssertEqual(frame(1, isRepeat: true).metadata(index: 0)["frame_type"], "repeated_signal")
        XCTAssertEqual(frame(1, isRepeat: true).metadata(index: 0)["is_repeated_frame"], "true")
    }

    // MARK: - Batch metadata

    func testMetadataCarriesTheTwoFieldsTheServerRequires() throws {
        let metadata = try XCTUnwrap(frameBatchMetadata(
            frames: [frame(1), frame(2, isRepeat: true)],
            batchId: "batch-1",
            sessionId: "session-1",
            userId: "anon",
            userType: .anonymous,
            appVersion: "1.0",
            batchNumber: 3,
            reason: .count
        ))
        XCTAssertEqual(metadata["batch_id"], "batch-1")
        XCTAssertEqual(metadata["session_id"], "session-1")
    }

    /// The counts are how a replay's timeline is reconstructed: a repeat signal carries no image, so the
    /// player needs to be told it stood for one.
    func testMetadataSeparatesRealFramesFromRepeats() throws {
        let metadata = try XCTUnwrap(frameBatchMetadata(
            frames: [frame(1), frame(2, isRepeat: true), frame(3, isRepeat: true)],
            batchId: "b", sessionId: "s", userId: "u", userType: .anonymous,
            appVersion: "1.0", batchNumber: 1, reason: .size
        ))
        XCTAssertEqual(metadata["total_frame_count"], "3")
        XCTAssertEqual(metadata["real_frame_count"], "1")
        XCTAssertEqual(metadata["repeated_signal_count"], "2")
        XCTAssertEqual(metadata["sequence_range"], "1-3")
        XCTAssertEqual(metadata["flush_reason"], "size")
        // The server checks this against the project the key belongs to. A batch that does not say
        // where it came from is accepted by every project, so a missing value here is the guard
        // silently switched off rather than a visible failure.
        XCTAssertEqual(metadata["platform"], "ios")
    }

    func testAnEmptyBatchHasNoMetadata() {
        XCTAssertNil(frameBatchMetadata(
            frames: [], batchId: "b", sessionId: "s", userId: "u",
            userType: .anonymous, appVersion: "1.0", batchNumber: 1, reason: .count
        ))
    }

    // MARK: - The multipart body

    /// The server pairs a frame body with its metadata by index, so a gap in the numbering silently detaches
    /// a frame from its timestamp.
    func testThePartsAreNumberedFromZeroAndPairUp() throws {
        let body = HTTPFrameSender.body(
            metadataJSON: "{}",
            frames: [frame(1), frame(2, isRepeat: true)],
            boundary: "BOUND"
        )
        let text = try XCTUnwrap(String(data: body, encoding: .isoLatin1))
        XCTAssertTrue(text.contains("name=\"frame_0\"; filename=\"frame_1_1001.jpg\""))
        XCTAssertTrue(text.contains("name=\"frame_0_metadata\""))
        XCTAssertTrue(text.contains("name=\"frame_1\"; filename=\"repeated_signal_2_1002.signal\""))
        XCTAssertTrue(text.contains("name=\"frame_1_metadata\""))
        XCTAssertTrue(text.contains("name=\"type\""), "the server routes on this")
        XCTAssertTrue(text.hasSuffix("--BOUND--\r\n"))
    }

    func testARepeatCarriesFourBytesRatherThanAnImage() throws {
        let body = HTTPFrameSender.body(
            metadataJSON: "{}", frames: [frame(9, isRepeat: true)], boundary: "B"
        )
        // 4 bytes of payload inside a small envelope: the whole point is that an idle minute costs almost
        // nothing, so this asserts the size rather than only the name.
        XCTAssertLessThan(body.count, 600)
        let text = try XCTUnwrap(String(data: body, encoding: .isoLatin1))
        XCTAssertTrue(text.contains("RPTD"))
    }
}

/// When an idle screen sends, which is the rule that a measurement rewrote.
///
/// An app left untouched for 38 minutes uploaded 96 batches, 95 of them holding nothing but four-byte repeat
/// signals — and the server had finalised the session long before, so those were requests against a closed
/// row. The frames still need recording; what was wrong was treating them as urgent.
final class IdleBatchingTests: XCTestCase {

    private func real(_ sequence: Int) -> ReplayFrame {
        ReplayFrame(
            data: Data(repeating: 0xAB, count: 9_000),
            isRepeat: false, sequence: sequence, timestampMillis: Int64(sequence)
        )
    }

    private func repeated(_ sequence: Int) -> ReplayFrame {
        ReplayFrame(
            data: ReplayFrame.repeatSignal, isRepeat: true,
            sequence: sequence, timestampMillis: Int64(sequence)
        )
    }

    func testAnIdleScreenDoesNotKeepSendingBatches() {
        var batcher = FrameBatcher(flushAtCount: 24, flushAtBytes: 2_000_000, flushAtTotalCount: 600)
        // Ten minutes of an untouched screen at one frame a second, minus one.
        for i in 1..<600 { batcher.add(repeated(i)) }
        XCTAssertFalse(batcher.shouldFlush(nowMillis: 1_100), "599 four-byte signals are not a batch worth waking the radio for")
        XCTAssertEqual(batcher.realCount, 0)
    }

    /// Bounded, though: the buffer must not grow for ever.
    func testTheCeilingEventuallySendsAnIdleBuffer() {
        var batcher = FrameBatcher(flushAtCount: 24, flushAtBytes: 2_000_000, flushAtTotalCount: 600)
        for i in 1...600 { batcher.add(repeated(i)) }
        XCTAssertTrue(batcher.shouldFlush(nowMillis: 1_100))
    }

    /// And nothing is lost by waiting: the repeats go out with the next thing that actually happened.
    func testBufferedRepeatsTravelWithTheNextRealFrames() {
        var batcher = FrameBatcher(flushAtCount: 2, flushAtBytes: 2_000_000, flushAtTotalCount: 600)
        for i in 1...50 { batcher.add(repeated(i)) }
        batcher.add(real(51))
        XCTAssertFalse(batcher.shouldFlush(nowMillis: 1_100), "one real frame is not the threshold")
        batcher.add(real(52))
        XCTAssertTrue(batcher.shouldFlush(nowMillis: 1_100))

        let batch = batcher.drain()
        XCTAssertEqual(batch.count, 52, "the whole idle stretch goes with the frames that ended it")
        XCTAssertEqual(batch.filter { !$0.isRepeat }.count, 2)
    }

    /// A screen being used still sends promptly — the change must not have slowed down the case that matters.
    func testAnActiveScreenStillSendsOnTheRealCount() {
        var batcher = FrameBatcher(flushAtCount: 3, flushAtBytes: 2_000_000, flushAtTotalCount: 600)
        batcher.add(real(1))
        batcher.add(real(2))
        XCTAssertFalse(batcher.shouldFlush(nowMillis: 1_100))
        batcher.add(real(3))
        XCTAssertTrue(batcher.shouldFlush(nowMillis: 1_100))
    }
}
