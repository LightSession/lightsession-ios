import XCTest
@testable import LightSession

/// What is allowed to leave the device for one HTTP request.
///
/// The type exists to make the answer unfakeable, so these tests are mostly about what *cannot* be
/// found in the result — a query, a credential, a header, a body.
final class ApiCallTests: XCTestCase {

    private func call(
        _ method: String = "GET",
        _ urlString: String,
        status: Int = 200,
        durationMillis: Int64 = 10,
        requestBytes: Int64 = 0,
        responseBytes: Int64 = 0,
        failure: String = ""
    ) -> ApiCall {
        ApiCall(
            method: method,
            url: URL(string: urlString),
            status: status,
            durationMillis: durationMillis,
            requestBytes: requestBytes,
            responseBytes: responseBytes,
            failure: failure
        )
    }

    func testTheOrdinaryCase() {
        let made = call("post", "https://api.example.com/v1/orders/84321/items", status: 201)
        XCTAssertEqual(made.method, "POST")
        XCTAssertEqual(made.host, "api.example.com")
        XCTAssertEqual(made.path, "/v1/orders/{id}/items")
        XCTAssertEqual(made.status, 201)
    }

    /// The one that matters most: a token in a query is not stored anywhere on the value, in any
    /// field, however the fields are later combined.
    func testATokenInTheQueryIsInNoField() {
        let made = call("GET", "https://api.example.com/v1/me?token=eyJhbGciOiJIUzI1NiJ9&cvv=737")
        for field in [made.method, made.host, made.path, made.failure] {
            XCTAssertFalse(field.contains("eyJ"), "token found in \(field)")
            XCTAssertFalse(field.contains("737"), "cvv found in \(field)")
            XCTAssertFalse(field.contains("?"), "query survived in \(field)")
        }
        XCTAssertEqual(made.path, "/v1/me")
    }

    /// `https://user:pass@host/` is a real thing that real code produces, and the password is in the
    /// authority — the field a naive host read would store.
    func testCredentialsInTheAuthorityAreNotStored() {
        let made = call("GET", "https://admin:hunter2@api.example.com/v1/me")
        XCTAssertFalse(made.host.contains("hunter2"))
        XCTAssertFalse(made.host.contains("admin"))
    }

    func testThePortIsNotPartOfTheHost() {
        XCTAssertEqual(call("GET", "http://10.0.2.2:3002/health").host, "10.0.2.2")
    }

    func testHostIsLowercased() {
        XCTAssertEqual(call("GET", "https://API.Example.COM/v1/me").host, "api.example.com")
    }

    // MARK: - Clamps

    /// A request that never got an answer has no status, and `0` is what the ingest and the rollup
    /// already read as "failed before answering".
    func testAnImpossibleStatusBecomesZero() {
        XCTAssertEqual(call("GET", "https://h.com/a", status: -1).status, 0)
        XCTAssertEqual(call("GET", "https://h.com/a", status: 0).status, 0)
        XCTAssertEqual(call("GET", "https://h.com/a", status: 99).status, 0)
        XCTAssertEqual(call("GET", "https://h.com/a", status: 600).status, 0)
        XCTAssertEqual(call("GET", "https://h.com/a", status: 599).status, 599)
    }

    /// `expectedContentLength` is `-1` for a chunked response, and a negative byte count summed into
    /// a rollup subtracts from someone else's total.
    func testNegativeCountsAreClampedToZero() {
        let made = call(
            "GET", "https://h.com/a",
            durationMillis: -5, requestBytes: -1, responseBytes: -1
        )
        XCTAssertEqual(made.durationMillis, 0)
        XCTAssertEqual(made.requestBytes, 0)
        XCTAssertEqual(made.responseBytes, 0)
    }

    func testAMethodThatIsNotOneIsEmptied() {
        XCTAssertEqual(call("", "https://h.com/a").method, "")
        XCTAssertEqual(call("GET /v1/me HTTP/1.1", "https://h.com/a").method, "")
        XCTAssertEqual(call("  get  ", "https://h.com/a").method, "GET")
    }

    func testANilURLIsEmptyRatherThanAnything() {
        let made = ApiCall(
            method: "GET", url: nil, status: 200,
            durationMillis: 0, requestBytes: 0, responseBytes: 0, failure: ""
        )
        XCTAssertEqual(made.host, "")
        XCTAssertEqual(made.path, "")
    }
}
