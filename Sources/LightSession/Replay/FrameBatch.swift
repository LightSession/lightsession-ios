import Foundation

/// One captured frame of a replay.
public struct ReplayFrame: Equatable, Sendable {
    /// The JPEG, or the four-byte repeat signal.
    public let data: Data
    /// Whether this stands in for a frame identical to the one before it.
    public let isRepeat: Bool
    public let sequence: Int
    public let timestampMillis: Int64

    public init(data: Data, isRepeat: Bool, sequence: Int, timestampMillis: Int64) {
        self.data = data
        self.isRepeat = isRepeat
        self.sequence = sequence
        self.timestampMillis = timestampMillis
    }

    /// The four bytes that mean "the same as the last one".
    ///
    /// `"RPTD"`, and it must stay exactly these bytes: the Android SDK sends them, and the server tells a
    /// repeat from a frame by the part's content type and file name. A replay is mostly repeats — a screen
    /// nobody is touching — so this is what keeps an idle minute at sixteen bytes instead of a megabyte.
    public static let repeatSignal = Data([0x52, 0x50, 0x54, 0x44])

    /// The part's file name, in the shape the server expects.
    public var fileName: String {
        isRepeat
            ? "repeated_signal_\(sequence)_\(timestampMillis).signal"
            : "frame_\(sequence)_\(timestampMillis).jpg"
    }

    /// A repeat is bytes, not an image, and is sent as such.
    public var contentType: String {
        isRepeat ? "application/octet-stream" : "image/jpeg"
    }

    /// What the server stores beside the frame.
    public func metadata(index: Int) -> [String: String] {
        [
            "timestamp": String(timestampMillis),
            "sequence_number": String(sequence),
            "frame_index": String(index),
            "is_repeated_frame": isRepeat ? "true" : "false",
            "frame_type": isRepeat ? "repeated_signal" : "real_frame",
            "data_size": String(data.count),
        ]
    }
}

/// Buffers frames and decides when a batch goes out.
///
/// Four rules, because frames differ from breadcrumbs in two ways — they are large, and most of them are
/// four-byte repeats. A count of *real* frames, a byte total, a far-off ceiling so an idle screen cannot grow
/// the buffer for ever, and a limit past which the oldest are discarded.
public struct FrameBatcher {

    /// Send once this many **real** frames are buffered.
    ///
    /// Real, not total, and that word was measured into place. Counting every frame meant a batch went out
    /// every 24 seconds forever: an app left untouched for 38 minutes uploaded 96 batches, 95 of which
    /// contained nothing but four-byte repeat signals — and by then the server had long since finalised the
    /// session, so it was 94 pointless radio wake-ups against a row that was already closed. A recorder that
    /// competes on how little it costs the host app cannot do that.
    ///
    /// Nothing is lost by waiting: the repeats are still recorded and still uploaded, just alongside the next
    /// thing that actually happened, or when the app leaves.
    public let flushAtCount: Int
    public let flushAtBytes: Int
    /// A ceiling on buffered frames whatever their kind, so an idle screen cannot grow the buffer for ever.
    ///
    /// Ten minutes of repeats at one a second, which is 4 KB. Deliberately large: this exists so the buffer is
    /// bounded, not to make idle batches prompt.
    public let flushAtTotalCount: Int
    /// Past this the oldest frames are dropped.
    ///
    /// Only reachable when uploads have been failing for a while. Dropping the **oldest** is deliberate: a
    /// replay with a gap in the middle still reaches the end, and the end is where "why did they give up" is
    /// answered. Dropping the newest gives a continuous replay that stops before the interesting part.
    public let maxBufferedBytes: Int

    private(set) public var pending: [ReplayFrame] = []
    private(set) public var bufferedBytes = 0
    private(set) public var batchNumber = 0
    private(set) public var shedCount = 0

    public init(
        flushAtCount: Int = 24,
        flushAtBytes: Int = 2 * 1024 * 1024,
        flushAtTotalCount: Int = 600,
        maxBufferedBytes: Int = 8 * 1024 * 1024
    ) {
        self.flushAtCount = flushAtCount
        self.flushAtBytes = flushAtBytes
        self.flushAtTotalCount = flushAtTotalCount
        self.maxBufferedBytes = maxBufferedBytes
    }

    /// How many buffered frames carry an image.
    public var realCount: Int { pending.filter { !$0.isRepeat }.count }

    public mutating func add(_ frame: ReplayFrame) {
        pending.append(frame)
        bufferedBytes += frame.data.count
        while bufferedBytes > maxBufferedBytes, !pending.isEmpty {
            let dropped = pending.removeFirst()
            bufferedBytes -= dropped.data.count
            shedCount += 1
        }
    }

    public var shouldFlush: Bool {
        guard !pending.isEmpty else { return false }
        return realCount >= flushAtCount
            || bufferedBytes >= flushAtBytes
            || pending.count >= flushAtTotalCount
    }

    /// Why this batch is being sent, for the metadata the server keeps.
    public enum FlushReason: String, Sendable {
        case count
        case size
        case background
        case sessionRotated
        case stopped
    }

    public mutating func drain() -> [ReplayFrame] {
        let batch = pending
        pending = []
        bufferedBytes = 0
        batchNumber += 1
        return batch
    }
}

/// The `metadata` part of `POST {ingestURL}/upload_batch`.
///
/// `batch_id` and `session_id` are the two the server refuses a batch without. Everything else it reads
/// leniently and stores; the counts in particular are what make a replay's timeline reconstructible, because
/// a repeat signal has no timestamp of its own on the wire beyond this.
///
/// Every value is a string. Not a style choice: it is what the Android SDK sends, and the server parses
/// numbers leniently *because* of that. Sending real JSON numbers would work and would make the two SDKs
/// differ for no reason.
public func frameBatchMetadata(
    frames: [ReplayFrame],
    batchId: String,
    sessionId: String,
    userId: String,
    userType: UserType,
    appVersion: String,
    batchNumber: Int,
    reason: FrameBatcher.FlushReason
) -> [String: String]? {
    guard let first = frames.first, let last = frames.last else { return nil }
    return [
        "batch_id": batchId,
        "session_id": sessionId,
        "user_id": userId,
        "user_type": userType.rawValue,
        "app_version": appVersion,
        "total_frame_count": String(frames.count),
        "real_frame_count": String(frames.filter { !$0.isRepeat }.count),
        "repeated_signal_count": String(frames.filter(\.isRepeat).count),
        "flush_reason": reason.rawValue,
        "total_batches_sent": String(batchNumber),
        "first_frame_timestamp": String(first.timestampMillis),
        "last_frame_timestamp": String(last.timestampMillis),
        "sequence_range": "\(first.sequence)-\(last.sequence)",
    ]
}

/// How often to capture, given what the person is doing.
///
/// Two intervals, and the reason is a mismatch in rates: touches arrive at 60–120 Hz while a useful replay
/// of a static screen needs about one frame a second. One interval has to be wrong for one of them — a fast
/// one spends its whole budget on a screen nobody is touching, a slow one turns a swipe into a jump cut.
public struct CaptureCadence: Sendable {
    public let idleMillis: Int64
    public let burstMillis: Int64
    /// How long a burst survives with no further touch.
    public let burstQuietMillis: Int64
    /// How long one burst window may run before it lapses.
    ///
    /// Not a cap on bursting overall, and the difference is worth being exact about because the obvious
    /// reading is wrong: when the ceiling is reached the window closes, and the *next* touch opens a fresh
    /// one. So an endless scroll does not hold the fast interval for ever — it gets a slow tick every few
    /// seconds — but nor is it limited to one burst. Android behaves identically, and a test here asserted
    /// the obvious reading and failed.
    public let burstMaxMillis: Int64

    public init(
        idleMillis: Int64 = 1_000,
        burstMillis: Int64 = 100,
        burstQuietMillis: Int64 = 250,
        burstMaxMillis: Int64 = 5_000
    ) {
        // Clamped rather than trusted: a burst slower than idle is a configuration that makes the fast path
        // the slow one, and 16 ms is one frame at 60 Hz — below it nothing more can be captured anyway.
        self.idleMillis = max(idleMillis, 50)
        self.burstMillis = min(max(burstMillis, 16), max(idleMillis, 50))
        self.burstQuietMillis = burstQuietMillis
        self.burstMaxMillis = burstMaxMillis
    }

    /// The burst window's state, as plain values so the rule can be tested by passing clocks.
    public struct Burst: Equatable, Sendable {
        public var startedAtMillis: Int64?
        public var untilMillis: Int64

        public init(startedAtMillis: Int64? = nil, untilMillis: Int64 = 0) {
            self.startedAtMillis = startedAtMillis
            self.untilMillis = untilMillis
        }
    }

    public func isBursting(_ burst: Burst, nowMillis: Int64) -> Bool {
        guard let startedAt = burst.startedAtMillis, nowMillis < burst.untilMillis else { return false }
        return nowMillis < startedAt + burstMaxMillis
    }

    public func delay(_ burst: Burst, nowMillis: Int64) -> Int64 {
        isBursting(burst, nowMillis: nowMillis) ? burstMillis : idleMillis
    }

    /// Opens or extends the burst window.
    public func touched(_ burst: Burst, nowMillis: Int64) -> Burst {
        var next = burst
        if !isBursting(burst, nowMillis: nowMillis) {
            next.startedAtMillis = nowMillis
        }
        next.untilMillis = nowMillis + burstQuietMillis
        return next
    }
}
