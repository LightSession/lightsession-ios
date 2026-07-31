import Foundation

/// Anything that can go in a breadcrumb batch.
///
/// Two kinds today — a touch and a screen change — and they share a batch because they share a timeline: a
/// replay needs to know a tap happened *between* these two screens, and separate uploads would put that
/// ordering at the mercy of two request latencies.
public protocol Breadcrumb {
    /// The session-wide counter. What the batch is ordered by, and what the timeline is rebuilt from.
    var sequence: Int { get }
    /// The object as the ingest worker reads it.
    var breadcrumb: [String: Any] { get }
}

/// A batch of breadcrumbs, and the rule for when to send one.
///
/// Batched rather than sent per touch for the reason the whole SDK exists: a recorder competes on how
/// little it costs the app it is in, and a request per tap is one radio wake-up per tap. Two triggers,
/// because either alone is wrong — a count alone never sends the last few events of a session, and an
/// interval alone lets a fast scroll accumulate hundreds in memory.
public struct BreadcrumbBatcher {

    /// Send once this many events are buffered.
    public let flushAtCount: Int
    /// Send if the oldest buffered event is this old, however few there are.
    public let flushAfterMillis: Int64
    /// Beyond this, the oldest events are dropped rather than the buffer growing without bound.
    ///
    /// Reached only when uploads have been failing for a long time. Dropping the *oldest* is deliberate:
    /// the recent ones describe what the person is doing now, which is what a session is watched for.
    public let maxBuffered: Int

    private(set) public var pending: [any Breadcrumb] = []
    private(set) public var batchNumber: Int = 0
    private var oldestMillis: Int64?
    private(set) public var droppedCount: Int = 0

    public init(flushAtCount: Int = 20, flushAfterMillis: Int64 = 5_000, maxBuffered: Int = 500) {
        self.flushAtCount = flushAtCount
        self.flushAfterMillis = flushAfterMillis
        self.maxBuffered = maxBuffered
    }

    public mutating func add(_ crumb: any Breadcrumb, nowMillis: Int64) {
        pending.append(crumb)
        if oldestMillis == nil { oldestMillis = nowMillis }
        if pending.count > maxBuffered {
            let excess = pending.count - maxBuffered
            pending.removeFirst(excess)
            droppedCount += excess
        }
    }

    public func shouldFlush(nowMillis: Int64) -> Bool {
        guard !pending.isEmpty else { return false }
        if pending.count >= flushAtCount { return true }
        guard let oldestMillis else { return false }
        return nowMillis - oldestMillis >= flushAfterMillis
    }

    /// Hands over everything buffered and clears it.
    ///
    /// The caller owns the upload from here, including its failure. Events are *not* put back on a failed
    /// send, and that is a deliberate limitation rather than an oversight: Android spools batches to disk
    /// so a failed upload survives a restart, and this SDK has no spool yet. Written down in the README
    /// rather than left for someone to discover from a gap in a session.
    public mutating func drain(nowMillis: Int64) -> [any Breadcrumb] {
        let batch = pending
        pending = []
        oldestMillis = nil
        batchNumber += 1
        return batch
    }
}

/// The multipart fields of `POST {ingestURL}/breadcrumb_batch`.
///
/// Only `session_id` and `breadcrumbs` are required by the server; the rest are sent because Android sends
/// them and the worker stores them. A field the server ignores costs nothing; a field it wanted and did not
/// get costs the whole batch.
public func breadcrumbBatchFields(
    events: [any Breadcrumb],
    sessionId: String,
    userId: String,
    userType: UserType,
    appVersion: String,
    batchNumber: Int,
    timestampMillis: Int64,
    deviceInfo: [String: Any],
    appInfo: [String: Any]
) -> [String: String]? {
    let crumbs = events
        // Ordered by the counter rather than by arrival: a batch assembled from a buffer can be out of
        // order, and the sequence is what the replay's timeline is rebuilt from.
        .sorted { $0.sequence < $1.sequence }
        .map(\.breadcrumb)

    guard
        let crumbsJSON = jsonString(crumbs),
        let deviceJSON = jsonString(deviceInfo),
        let appJSON = jsonString(appInfo)
    else { return nil }

    return [
        "type": "breadcrumb_batch",
        "session_id": sessionId,
        "user_id": userId,
        "user_type": userType.rawValue,
        "app_version": appVersion,
        "app_info": appJSON,
        "device_info": deviceJSON,
        "batch_number": String(batchNumber),
        "timestamp": String(timestampMillis),
        "breadcrumbs": crumbsJSON,
    ]
}

private func jsonString(_ value: Any) -> String? {
    guard JSONSerialization.isValidJSONObject(value) || value is [Any] else { return nil }
    guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
    return String(data: data, encoding: .utf8)
}
