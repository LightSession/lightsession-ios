import XCTest
@testable import LightSession

/// The spool, against a real temporary directory.
///
/// Not mocked: files are the whole point of this class, and a mock file system would test the mock. `FileManager`
/// works on macOS, so these run in `swift test` with no simulator.
final class BatchSpoolTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ls-spool-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func spool(maxBytes: Int = 32 * 1024 * 1024) throws -> BatchSpool {
        try BatchSpool(root: root, maxBytes: maxBytes)
    }

    private func frame(_ sequence: Int, bytes: Int = 1_000, isRepeat: Bool = false) -> ReplayFrame {
        ReplayFrame(
            data: isRepeat ? ReplayFrame.repeatSignal : Data(repeating: 0xAB, count: bytes),
            isRepeat: isRepeat,
            sequence: sequence,
            timestampMillis: Int64(1_700_000_000_000 + sequence)
        )
    }

    // MARK: - Round trip

    func testABreadcrumbBatchComesBackAsItWentIn() throws {
        let spool = try spool()
        let fields = ["session_id": "s-1", "breadcrumbs": "[{\"type\":\"interaction\"}]", "batch_number": "3"]
        try spool.write(breadcrumbs: fields)

        let pending = spool.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(spool.fields(of: pending[0]), fields)
    }

    func testAFrameBatchComesBackWithItsFramesInOrder() throws {
        let spool = try spool()
        let written = [frame(7), frame(8, isRepeat: true), frame(9)]
        try spool.write(frames: written, metadata: ["batch_id": "b-1", "session_id": "s-1"])

        let entry = try XCTUnwrap(spool.pending().first)
        let recovered = try XCTUnwrap(spool.frames(of: entry))
        XCTAssertEqual(recovered.metadata["batch_id"], "b-1")
        XCTAssertEqual(recovered.frames.map(\.sequence), [7, 8, 9])
        XCTAssertEqual(recovered.frames.map(\.isRepeat), [false, true, false])
        XCTAssertEqual(recovered.frames[0].data.count, 1_000)
        XCTAssertEqual(recovered.frames[1].data, ReplayFrame.repeatSignal)
    }

    /// Without zero padding in the on-disk name, `frame_10` sorts before `frame_9` and the replay plays out of
    /// sequence — a fault that would look like the app itself misbehaving.
    func testFramesPastTenKeepTheirOrder() throws {
        let spool = try spool()
        try spool.write(frames: (1...12).map { frame($0) }, metadata: ["batch_id": "b", "session_id": "s"])
        let entry = try XCTUnwrap(spool.pending().first)
        let recovered = try XCTUnwrap(spool.frames(of: entry))
        XCTAssertEqual(recovered.frames.map(\.sequence), Array(1...12))
    }

    func testAFramesTimestampAndKindSurviveTheRoundTrip() throws {
        let original = frame(42, isRepeat: true)
        let parsed = try XCTUnwrap(
            BatchSpool.parseFrame(fileName: "00003_" + original.fileName, data: original.data)
        )
        XCTAssertEqual(parsed.sequence, 42)
        XCTAssertEqual(parsed.timestampMillis, original.timestampMillis)
        XCTAssertTrue(parsed.isRepeat)
    }

    // MARK: - Drain order

    /// Breadcrumbs first. They are two orders of magnitude smaller and they are the only record that a tap
    /// happened, so a slow frame upload must not sit in front of them.
    func testBreadcrumbsDrainBeforeFrames() throws {
        let spool = try spool()
        try spool.write(frames: [frame(1)], metadata: ["batch_id": "b", "session_id": "s"])
        try spool.write(breadcrumbs: ["session_id": "s"])
        try spool.write(frames: [frame(2)], metadata: ["batch_id": "b2", "session_id": "s"])

        XCTAssertEqual(spool.pending().map(\.kind), [.breadcrumbs, .frames, .frames])
    }

    func testOldestFirstWithinAKind() throws {
        let spool = try spool()
        for i in 1...3 {
            try spool.write(frames: [frame(i)], metadata: ["batch_id": "b\(i)", "session_id": "s"])
        }
        XCTAssertEqual(spool.pending().map(\.sequence), [0, 1, 2])
    }

    /// A batch written before a restart must still sort before one written after it, so the sequence continues
    /// from what is on disk rather than from zero.
    func testSequencingContinuesAcrossRestarts() throws {
        let first = try spool()
        try first.write(breadcrumbs: ["session_id": "s"])
        try first.write(breadcrumbs: ["session_id": "s"])

        let second = try spool()
        try second.write(breadcrumbs: ["session_id": "s"])
        XCTAssertEqual(second.pending().map(\.sequence), [0, 1, 2])
    }

    // MARK: - Removal and pruning

    func testRemovingAnEntryIsWhatAcceptanceMeans() throws {
        let spool = try spool()
        try spool.write(breadcrumbs: ["session_id": "s"])
        let entry = try XCTUnwrap(spool.pending().first)
        spool.remove(entry)
        XCTAssertTrue(spool.pending().isEmpty)
    }

    /// A recorder must not fill someone's phone because their network has been down for a week.
    func testTheSpoolIsPrunedToItsCeiling() throws {
        let spool = try spool(maxBytes: 5_000)
        for i in 1...10 {
            try spool.write(frames: [frame(i, bytes: 2_000)], metadata: ["batch_id": "b\(i)", "session_id": "s"])
        }
        XCTAssertLessThanOrEqual(spool.size(), 5_000 + 2_100, "pruned to roughly the ceiling")
        // The newest survive: the recent part of a session is the part worth watching.
        let sequences = spool.pending().map(\.sequence)
        XCTAssertEqual(sequences.max(), 9)
    }

    /// Frames go before breadcrumbs when space has to be found — the reverse of the drain order. A frame batch
    /// is tens of kilobytes and the frame beside it looks almost identical; a breadcrumb is the only record
    /// that a tap happened.
    func testPruningSacrificesFramesBeforeBreadcrumbs() throws {
        let spool = try spool(maxBytes: 3_000)
        try spool.write(breadcrumbs: ["session_id": "s", "breadcrumbs": "[]"])
        for i in 1...5 {
            try spool.write(frames: [frame(i, bytes: 2_000)], metadata: ["batch_id": "b\(i)", "session_id": "s"])
        }
        XCTAssertTrue(
            spool.pending().contains { $0.kind == .breadcrumbs },
            "the interactions must outlive the frames"
        )
    }

    /// A crash halfway through writing twenty-four frames must leave nothing the drain can see, rather than a
    /// batch missing frames its metadata claims are there.
    func testAnUnfinishedBatchIsInvisible() throws {
        let spool = try spool()
        let staging = root.appendingPathComponent("staging-frames-000000042")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: staging.appendingPathComponent("meta.json"))

        XCTAssertTrue(spool.pending().isEmpty, "a staging directory is not a batch")
    }
}
