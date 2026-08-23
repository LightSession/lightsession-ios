#if canImport(UIKit)
import Foundation

/// Where a recorded call goes.
///
/// A protocol for one conformer, which is the price of being able to test the property this feature
/// is judged on: that nothing here holds a lock while calling out. A fake sink can re-enter, and
/// re-entering is what a lock held across the call would turn into a deadlock in the customer's app.
protocol ApiCallSink: AnyObject {
    func record(call: ApiCall, timestampMillis: Int64)
    /// The session the sampling decision is derived from. Read here rather than passed in,
    /// because the decision has to be made *before* a call is built — a request the sample does
    /// not want should cost a hash and nothing more.
    var samplingSessionId: String { get }
}

extension InteractionRecorder: ApiCallSink {
    /// Read off the session coordinator, so a rotation changes the sampling verdict with it —
    /// which is what keeps a long-lived process from committing to one answer at launch.
    var samplingSessionId: String { session.sessionId }
}

/// The seam between the app's HTTP client and the recorder.
///
/// Exists so the public entry points do not need to reach into `LightSession`'s private state, and
/// so a test can arm the capture without starting the SDK.
///
/// The lock guards two pointer reads and is released before the recorder is called. That ordering is
/// the rule the Android interceptor is tested against and it holds here for the same reason: this
/// code runs on a queue the customer's networking owns, and a lock held across a call into our own
/// machinery is a lock their next request can wait on.
enum NetworkCapture {
    private static let lock = NSLock()
    private static weak var recorder: (any ApiCallSink)?
    private static var isEnabled = false
    private static var sampleRate = NetworkSampling.noSampling

    static func install(
        recorder: (any ApiCallSink)?,
        enabled: Bool,
        sampleRate: Double = NetworkSampling.noSampling
    ) {
        lock.lock()
        self.recorder = recorder
        self.isEnabled = enabled
        self.sampleRate = sampleRate
        lock.unlock()
    }

    /// Whether anything would be recorded. Read by the public entry points so an app that left the
    /// flag off pays a lock and a branch per request, and nothing else.
    static var isArmed: Bool {
        lock.lock()
        let armed = isEnabled && recorder != nil
        lock.unlock()
        return armed
    }

    /// The weight this request should carry, or `nil` when the sample does not want it.
    ///
    /// Asked before an `ApiCall` is built, so a request the sample drops costs a lock, a hash and
    /// nothing else. The lock covers two reads and is released before the hash — the rule this
    /// file is tested against is that nothing here is held across a call out, and the same
    /// reasoning applies to work of any length on the app's own network queue.
    static func weight(failed: Bool) -> Int? {
        lock.lock()
        let armed = isEnabled && recorder != nil
        let rate = sampleRate
        let sessionId = recorder?.samplingSessionId ?? ""
        lock.unlock()
        guard armed else { return nil }
        return NetworkSampling.weight(sessionId: sessionId, rate: rate, failed: failed)
    }

    static func record(_ call: ApiCall, timestampMillis: Int64) {
        lock.lock()
        let target = isEnabled ? recorder : nil
        lock.unlock()
        target?.record(call: call, timestampMillis: timestampMillis)
    }

    /// Test seam. Resets to the un-installed state.
    static func uninstall() {
        install(recorder: nil, enabled: false)
    }
}

extension LightSession {

    /// Records one HTTP request, from a `URLSessionTask` that has finished.
    ///
    /// For an app whose `URLSession` already has a delegate of its own — pass the task and its
    /// metrics along from `urlSession(_:task:didFinishCollecting:)` and nothing else changes:
    ///
    /// ```swift
    /// func urlSession(
    ///     _ session: URLSession,
    ///     task: URLSessionTask,
    ///     didFinishCollecting metrics: URLSessionTaskMetrics
    /// ) {
    ///     LightSession.record(task, metrics: metrics)
    /// }
    /// ```
    ///
    /// An app with no delegate of its own uses `LightSessionURLSessionDelegate` instead, which is
    /// this call and nothing more.
    ///
    /// Reads only what the task and the metrics already computed. Nothing here touches a stream, so
    /// there is no version of this that consumes a body the app was about to read — the failure that
    /// has to be actively avoided on the Android side is structurally impossible on this one.
    ///
    /// The metrics are required rather than optional, and that is a correction of this API's first
    /// shape. With a default of `nil` the obvious call is `record(task)`, which compiles, records,
    /// and reports every duration as zero — quietly turning the percentiles this feature exists to
    /// produce into a column of noise. A caller who genuinely has no metrics has no duration either,
    /// and should say so through `recordRequest` with a number it stands behind.
    public static func record(_ task: URLSessionTask, metrics: URLSessionTaskMetrics) {
        guard NetworkCapture.isArmed else { return }
        let request = task.originalRequest ?? task.currentRequest
        let response = task.response as? HTTPURLResponse
        let interval = metrics.taskInterval

        // Summed across transactions, so a redirected or retried request reports what it actually
        // cost the device rather than what its last hop did.
        var sent: Int64 = 0
        var received: Int64 = 0
        for transaction in metrics.transactionMetrics {
            sent += transaction.countOfRequestBodyBytesSent
            // The on-the-wire count, not the decoded one: this number answers "what did this cost
            // the user's data", and a gzipped response cost its compressed size. It is also the
            // number Android's `Content-Length` reports, so the two platforms agree.
            received += transaction.countOfResponseBodyBytesReceived
        }

        recordRequest(
            method: request?.httpMethod ?? "",
            url: request?.url,
            statusCode: response?.statusCode ?? 0,
            durationMillis: Int64(interval.duration * 1000),
            requestBytes: sent,
            responseBytes: received,
            error: task.error,
            // The moment the request left, which is where it belongs on the timeline: beside the tap
            // that caused it, not beside whatever the person did while waiting.
            startedAt: interval.start
        )
    }

    /// Records one HTTP request, from a client that is not `URLSession`.
    ///
    /// The primitive everything else here is built on, for Alamofire's `EventMonitor`, a
    /// hand-written client, or a wrapper of any shape:
    ///
    /// ```swift
    /// LightSession.recordRequest(
    ///     method: "POST",
    ///     url: url,
    ///     statusCode: 201,
    ///     durationMillis: 118,
    ///     requestBytes: 348,
    ///     responseBytes: 1204,
    ///     error: nil
    /// )
    /// ```
    ///
    /// What is kept: the method, the host, the path with its dynamic segments collapsed **here, on
    /// the device**, the status, the duration, the two byte counts, and a one-word failure class.
    /// The query string is dropped before anything is stored, and there is no parameter for a body
    /// or a header — passing one is not possible rather than discouraged.
    ///
    /// Callable from any thread. Does nothing at all unless the app set `captureNetwork: true`.
    public static func recordRequest(
        method: String,
        url: URL?,
        statusCode: Int,
        durationMillis: Int64,
        requestBytes: Int64 = 0,
        responseBytes: Int64 = 0,
        error: Error? = nil,
        startedAt: Date? = nil
    ) {
        guard NetworkCapture.isArmed else { return }
        // The sampling decision first, before any of the work it gates. `statusCode == 0` means
        // the request never got an answer, which is a failure and one of the ones most worth
        // keeping whatever the rate says.
        let failed = statusCode >= 400 || statusCode == 0
        guard let weight = NetworkCapture.weight(failed: failed) else { return }
        let call = ApiCall(
            method: method,
            url: url,
            status: statusCode,
            durationMillis: durationMillis,
            requestBytes: requestBytes,
            responseBytes: responseBytes,
            failure: NetworkFailure.of(error),
            weight: weight
        )
        // A call whose URL had no usable path is dropped rather than stored as an endpoint called
        // `""`. One un-attributable row teaches nobody anything and it would be the widest bucket in
        // the endpoint list.
        guard !call.path.isEmpty, !call.method.isEmpty else { return }
        let startedMillis = startedAt.map { Int64($0.timeIntervalSince1970 * 1000) }
        NetworkCapture.record(
            call,
            timestampMillis: startedMillis ?? Int64(Date().timeIntervalSince1970 * 1000)
        )
    }
}

/// A `URLSession` delegate that records what the session did, and does nothing else.
///
/// One line for an app that has no delegate of its own:
///
/// ```swift
/// let session = URLSession(
///     configuration: .default,
///     delegate: LightSessionURLSessionDelegate(),
///     delegateQueue: nil
/// )
/// ```
///
/// Everything the session does keeps working — `data(for:)` and the other async calls included,
/// which is worth stating because a session with a delegate is often assumed to be the old
/// completion-handler world. The task-delegate callbacks fire for those too.
///
/// This observes. It cannot redirect a request, cancel one, alter a response or read a body — the
/// one callback implemented is handed a finished task and a metrics object. That is the whole reason
/// this shape was chosen over `URLProtocol`, which would have to re-issue every request the app
/// makes through our code, and over swizzling, which would have to be right about a private
/// implementation on every future OS.
public final class LightSessionURLSessionDelegate: NSObject, URLSessionTaskDelegate {

    public override init() {
        super.init()
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        LightSession.record(task, metrics: metrics)
    }
}
#endif
