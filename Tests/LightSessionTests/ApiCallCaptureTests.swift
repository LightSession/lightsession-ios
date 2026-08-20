#if canImport(UIKit)
import XCTest
@testable import LightSession

/// The crumb an API call becomes, and the guards around the entry points.
///
/// This one puts our code in the path of every request a customer's app makes, so most of what is
/// asserted here is about what it must *not* do: leak, deadlock, throw, or record when nobody asked.
final class ApiCallCaptureTests: XCTestCase {

    /// A sink that records what it was handed and can be told to re-enter the capture.
    private final class Sink: ApiCallSink {
        var calls: [(ApiCall, Int64)] = []
        var onRecord: (() -> Void)?
        private let lock = NSLock()

        func record(call: ApiCall, timestampMillis: Int64) {
            lock.lock()
            calls.append((call, timestampMillis))
            lock.unlock()
            onRecord?()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls.count
        }
    }

    private var sink: Sink!

    override func setUp() {
        super.setUp()
        sink = Sink()
        NetworkCapture.install(recorder: sink, enabled: true)
    }

    override func tearDown() {
        NetworkCapture.uninstall()
        sink = nil
        super.tearDown()
    }

    private func event(_ call: ApiCall, screen: String? = "checkout") -> ApiCallEvent {
        ApiCallEvent(
            sequence: 7,
            call: call,
            timestampMillis: 1_700_000_000_000,
            userId: "u-1",
            userType: .anonymous,
            appVersion: "1.2.3",
            screen: screen,
            // Derived from `screen` rather than passed separately, because that is how the recorder
            // builds it: both come out of one `currentScreen()`, so a capture id without a name is
            // not a state that exists.
            screenId: screen == nil ? nil : "cap-9"
        )
    }

    private func aCall(
        _ method: String = "POST",
        _ url: String = "https://api.example.com/v1/orders/84321/items",
        status: Int = 201,
        failure: String = ""
    ) -> ApiCall {
        ApiCall(
            method: method, url: URL(string: url), status: status,
            durationMillis: 118, requestBytes: 348, responseBytes: 1_204, failure: failure
        )
    }

    // MARK: - The wire shape

    /// Field for field what the Android SDK sends, because the ingest has one parser.
    func testTheCrumbIsTheContractTheIngestReads() {
        let crumb = event(aCall()).breadcrumb
        XCTAssertEqual(crumb["type"] as? String, "api")
        XCTAssertEqual(crumb["sequence"] as? Int, 7)
        XCTAssertEqual(crumb["timestamp"] as? Int64, 1_700_000_000_000)
        XCTAssertEqual(crumb["screen"] as? String, "checkout")
        XCTAssertEqual(crumb["screen_id"] as? String, "cap-9")
        // Latency at the top level, where the ingest reads it for every crumb type — not in `data`.
        XCTAssertEqual(crumb["duration"] as? Int64, 118)
        XCTAssertNil((crumb["data"] as? [String: Any])?["duration"])

        let data = crumb["data"] as? [String: Any]
        XCTAssertEqual(data?["method"] as? String, "POST")
        XCTAssertEqual(data?["host"] as? String, "api.example.com")
        XCTAssertEqual(data?["path"] as? String, "/v1/orders/{id}/items")
        XCTAssertEqual(data?["status"] as? Int, 201)
        XCTAssertEqual(data?["request_bytes"] as? Int64, 348)
        XCTAssertEqual(data?["response_bytes"] as? Int64, 1_204)
        XCTAssertEqual(data?["error"] as? String, "")
        XCTAssertEqual(data?.count, 7, "a field was added or removed without the ingest agreeing")
    }

    /// A crumb that cannot be serialised does not fail alone — it fails the batch it is in, taking
    /// the taps and navigations with it.
    func testTheCrumbIsValidJSON() {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(event(aCall()).breadcrumb))
        let encoded = try? JSONSerialization.data(withJSONObject: event(aCall()).breadcrumb)
        XCTAssertNotNil(encoded)
    }

    /// The absence is the feature. Not "redacted by default" — there is no field, so no later edit
    /// adds one by relaxing a filter.
    func testNoBodyNoHeadersNoQueryAnywhereInTheCrumb() {
        let call = aCall("POST", "https://api.example.com/v1/login?token=eyJhbGciOiJIUzI1NiJ9")
        let crumb = event(call).breadcrumb
        let encoded = String(
            data: try! JSONSerialization.data(withJSONObject: crumb, options: [.sortedKeys]),
            encoding: .utf8
        )!
        for forbidden in ["body", "header", "authorization", "cookie", "eyJ", "?", "token"] {
            XCTAssertFalse(
                encoded.lowercased().contains(forbidden),
                "`\(forbidden)` found in the crumb: \(encoded)"
            )
        }
    }

    func testAnUnknownScreenOmitsTheFieldRatherThanNamingOne() {
        let crumb = event(aCall(), screen: nil).breadcrumb
        XCTAssertNil(crumb["screen"])
        XCTAssertNil(crumb["screen_id"])
    }

    // MARK: - The gate

    func testNothingIsRecordedWhenTheFlagIsOff() {
        NetworkCapture.install(recorder: sink, enabled: false)
        XCTAssertFalse(NetworkCapture.isArmed)
        LightSession.recordRequest(
            method: "GET", url: URL(string: "https://h.com/v1/me"),
            statusCode: 200, durationMillis: 5
        )
        XCTAssertEqual(sink.count, 0)
    }

    func testNothingIsRecordedAndNothingBreaksBeforeStart() {
        NetworkCapture.uninstall()
        XCTAssertFalse(NetworkCapture.isArmed)
        LightSession.recordRequest(
            method: "GET", url: URL(string: "https://h.com/v1/me"),
            statusCode: 200, durationMillis: 5
        )
    }

    func testAnArmedCaptureRecordsTheCollapsedPath() {
        LightSession.recordRequest(
            method: "get", url: URL(string: "https://api.example.com/v1/users/84321?token=abc"),
            statusCode: 200, durationMillis: 42, requestBytes: 0, responseBytes: 31
        )
        XCTAssertEqual(sink.count, 1)
        let recorded = sink.calls[0].0
        XCTAssertEqual(recorded.method, "GET")
        XCTAssertEqual(recorded.path, "/v1/users/{id}")
        XCTAssertEqual(recorded.host, "api.example.com")
        XCTAssertEqual(recorded.durationMillis, 42)
    }

    /// One un-attributable row would be the widest bucket in the endpoint list and teach nobody
    /// anything, so it is dropped rather than stored as an endpoint called `""`.
    func testACallWithNoUsablePathOrMethodIsDropped() {
        LightSession.recordRequest(method: "GET", url: nil, statusCode: 200, durationMillis: 1)
        LightSession.recordRequest(
            method: "", url: URL(string: "https://h.com/v1/me"), statusCode: 200, durationMillis: 1
        )
        XCTAssertEqual(sink.count, 0)
    }

    func testTheFailureClassRidesAlong() {
        LightSession.recordRequest(
            method: "GET", url: URL(string: "https://h.com/v1/me"),
            statusCode: 0, durationMillis: 30_000, error: URLError(.timedOut)
        )
        XCTAssertEqual(sink.calls.first?.0.failure, "timeout")
        XCTAssertEqual(sink.calls.first?.0.status, 0)
    }

    /// The moment the request left, not the moment it landed: that is where it belongs on the
    /// timeline, beside the tap that caused it.
    func testTheTimestampIsWhenTheRequestStarted() {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        LightSession.recordRequest(
            method: "GET", url: URL(string: "https://h.com/v1/me"),
            statusCode: 200, durationMillis: 9_000, startedAt: started
        )
        XCTAssertEqual(sink.calls.first?.1, 1_700_000_000_000)
    }

    // MARK: - The properties this feature is judged on

    /// The rule the Android interceptor is tested against, in its iOS form. If `record` held its lock
    /// while calling the sink, a sink that records again — any client that issues a request from a
    /// response handler — would deadlock the customer's app here rather than in our code.
    ///
    /// The outer call is made off the test's own thread on purpose: with the lock held across the
    /// sink, the re-entrant call blocks on a non-recursive lock its own thread already owns, and on
    /// the test's thread that would mean `wait(for:)` is never reached at all. Parked on another
    /// queue, the wait times out and this test goes red.
    ///
    /// Whoever hits that red should know what else to expect. The deadlocked thread holds the static
    /// lock forever, so every later test in this class deadlocks in `setUp` and the suite stops
    /// completing rather than finishing with one failure. Measured both ways: as written, fourteen
    /// tests in fifteen milliseconds; with the lock moved back across the call, the suite does not
    /// finish. Loud, which is the right failure for this one.
    func testNoLockIsHeldWhileCallingOut() {
        let reentered = expectation(description: "the re-entrant call completed")
        var once = true
        sink.onRecord = {
            guard once else { return }
            once = false
            LightSession.recordRequest(
                method: "GET", url: URL(string: "https://h.com/v1/retry"),
                statusCode: 200, durationMillis: 1
            )
            reentered.fulfill()
        }
        DispatchQueue.global().async {
            LightSession.recordRequest(
                method: "GET", url: URL(string: "https://h.com/v1/first"),
                statusCode: 500, durationMillis: 1
            )
        }
        wait(for: [reentered], timeout: 2)
        XCTAssertEqual(sink.count, 2)
    }

    /// A burst is the normal case — a screen that loads six things at once — and it arrives on
    /// whichever queues the app's client uses.
    func testConcurrentCallsAllArriveAndNothingDeadlocks() {
        let done = expectation(description: "all recorded")
        done.expectedFulfillmentCount = 200
        for index in 0..<200 {
            DispatchQueue.global().async {
                LightSession.recordRequest(
                    method: "GET", url: URL(string: "https://h.com/v1/items/\(index)"),
                    statusCode: 200, durationMillis: Int64(index)
                )
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(sink.count, 200)
        // Every one collapsed to the same endpoint, which is the point of the endpoint list.
        XCTAssertEqual(Set(sink.calls.map { $0.0.path }), ["/v1/items/{id}"])
    }

    /// Its worst failure is their app, so hostile input must be survivable rather than merely
    /// unlikely. Nothing here may crash: no force unwrap, no overflow, no index.
    func testHostileInputIsSurvived() {
        let urls: [String?] = [
            nil, "", "not a url", "://", "http://", "https://h.com",
            "https://" + String(repeating: "h", count: 5_000) + ".com/a",
            "https://h.com/" + String(repeating: "a/", count: 2_000),
            "https://h.com/\u{0}/x", "https://h.com/🙂/x",
            "https://user:pass@h.com:99999/a",
        ]
        for raw in urls {
            for method in ["", "GET", String(repeating: "X", count: 500), "🙂"] {
                LightSession.recordRequest(
                    method: method,
                    url: raw.flatMap { URL(string: $0) },
                    statusCode: Int.min,
                    durationMillis: Int64.min,
                    requestBytes: Int64.min,
                    responseBytes: Int64.max,
                    error: URLError(URLError.Code(rawValue: Int.max))
                )
            }
        }
        // Nothing asserted about the contents: the assertion is that this returned at all.
        XCTAssertTrue(true)
    }

    /// Weak, so an app that tears the SDK down does not keep a recorder alive through a static, and
    /// so a call arriving after teardown is dropped instead of resurrecting one.
    func testTheSinkIsHeldWeakly() {
        var short: Sink? = Sink()
        NetworkCapture.install(recorder: short, enabled: true)
        XCTAssertTrue(NetworkCapture.isArmed)
        short = nil
        XCTAssertFalse(NetworkCapture.isArmed)
        LightSession.recordRequest(
            method: "GET", url: URL(string: "https://h.com/v1/me"),
            statusCode: 200, durationMillis: 1
        )
    }
}
#endif
