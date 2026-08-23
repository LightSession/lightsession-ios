import Foundation

/// Whether a request is recorded, and what it stands for if it is.
///
/// The Android SDK's `NetworkSampling`, decision for decision, because the server does the
/// arithmetic once for both — an estimate assembled from two platforms that disagreed about what a
/// weight meant would be wrong in a way no query could detect.
///
/// ## Why the session and not the request
///
/// A coin per request is the obvious design and it is wrong here. At a tenth, a screen that fires
/// six calls at once is recorded as one, and a reader concludes the screen makes one request. That
/// is a lie about the app's *structure* rather than about its volume, and no sample size fixes it.
/// The session timeline gets the same treatment — holes in it, and that timeline is the one view
/// this product has that a server-side tool does not.
///
/// So the unit is the session: recorded whole, or not recorded. Structure survives, timelines
/// survive, and the statistics are still a uniform sample because sessions are drawn uniformly.
///
/// ## Why a hash and not a coin
///
/// The decision is derived from the session id rather than rolled and remembered. Nothing to store,
/// nothing to reset, and no rotation callback to forget — when the session id changes the answer
/// changes with it, which is what keeps the sample uniform across a long-lived process instead of
/// committing it to one verdict at launch. It is also a pure function, so it is testable without a
/// session.
///
/// ## Why failures are kept anyway
///
/// A rare failure at a tenth is seen once in ten occurrences, and the failure somebody phones about
/// is exactly the rare one. So a request that failed is recorded even in a session that was not
/// sampled — with weight `0`, which the server reads as "list it, count it nowhere". Without that
/// weight these extras would be a census of failures beside a sample of successes, and every rate
/// they touched would be wrong by the sampling factor. The bias lands on the latency tail in
/// particular, because the requests that fail are the slow ones.
enum NetworkSampling {

    /// Off. Every request is recorded and stands for exactly itself.
    static let noSampling: Double = 1.0

    /// Below this a rate means "record nothing but failures". Not zero, because a `1e-9` is a
    /// caller asking for nothing by a route that would otherwise divide into a weight no column
    /// can hold.
    private static let minimumRate: Double = 0.0001

    /// What one recorded request stands for, or `nil` when it is not recorded at all.
    ///
    /// The four answers, each a different statement to the server:
    /// - `1` — no sampling, or a sampled-in session at full rate. Stands for itself.
    /// - `N` — a sampled-in session at rate `1/N`. Stands for `N` requests.
    /// - `0` — a failure from a session that was not sampled. Visible, counted nowhere.
    /// - `nil` — a success from a session that was not sampled. Not recorded.
    static func weight(sessionId: String, rate: Double, failed: Bool) -> Int? {
        // A rate that is not a rate is a caller mistake, and the safe reading of a mistake here is
        // to record everything: too much data is a cost, too little is a wrong answer that nobody
        // can detect from the outside.
        guard rate.isFinite, !rate.isNaN, rate < noSampling else { return 1 }
        guard rate >= minimumRate else { return failed ? 0 : nil }

        if inSample(sessionId: sessionId, rate: rate) {
            // Rounded, and at least 1. A weight counts real requests and cannot be fractional; a
            // rate above 0.5 rounds to 1, which under-counts slightly rather than claiming traffic
            // that never happened.
            return max(1, Int((1.0 / rate).rounded()))
        }
        return failed ? 0 : nil
    }

    /// Whether this session is one of the recorded ones.
    ///
    /// 10,000 buckets, so a rate is honoured to a hundredth of a percent — the same floor
    /// `minimumRate` sets, and past it the arithmetic would claim precision the bucketing does not
    /// have.
    static func inSample(sessionId: String, rate: Double) -> Bool {
        guard rate.isFinite, !rate.isNaN, rate < noSampling else { return true }
        guard rate >= minimumRate else { return false }
        return Int(hash(sessionId) % 10_000) < Int(rate * 10_000)
    }

    /// FNV-1a over the id's UTF-8 bytes.
    ///
    /// Written out rather than using `hashValue`, and that is not caution: Swift seeds string
    /// hashing per process, so `hashValue` would give a session one verdict on this launch and
    /// another on the next. The spool carries a session across launches, so those two verdicts
    /// would end up in one session's data. The same trap `ScreenIdentity.modalName` documents,
    /// for the same reason.
    private static func hash(_ value: String) -> UInt32 {
        var h: UInt32 = 2_166_136_261
        for byte in value.utf8 {
            h ^= UInt32(byte)
            h = h &* 16_777_619
        }
        return h
    }
}
