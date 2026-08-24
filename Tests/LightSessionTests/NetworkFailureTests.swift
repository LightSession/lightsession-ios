import XCTest
@testable import LightSession

/// Why a request failed, and the reason it is a word rather than a message.
final class NetworkFailureTests: XCTestCase {

    private struct Wrapped: Error {
        let underlying: Error
    }

    private enum AppError: Error {
        case network(underlying: Error)
    }

    func testNoErrorIsNoFailure() {
        XCTAssertEqual(NetworkFailure.of(nil), "")
    }

    func testTheTransportVocabulary() {
        let cases: [(URLError.Code, String)] = [
            (.timedOut, "timeout"),
            (.cannotFindHost, "dns"),
            (.dnsLookupFailed, "dns"),
            (.secureConnectionFailed, "tls"),
            (.serverCertificateUntrusted, "tls"),
            (.appTransportSecurityRequiresSecureConnection, "tls"),
            (.cannotConnectToHost, "connect"),
            (.networkConnectionLost, "connection_lost"),
            (.cancelled, "cancelled"),
            (.notConnectedToInternet, "offline"),
            (.badServerResponse, "io"),
            (.cannotDecodeContentData, "io"),
        ]
        for (code, expected) in cases {
            XCTAssertEqual(NetworkFailure.of(URLError(code)), expected, "for \(code)")
        }
    }

    /// The hop that makes this useful in a real app. Every client worth using wraps its transport
    /// errors; without following the cause once, every timeout in such an app reports `io`, which is
    /// the same as reporting nothing.
    func testAWrappedTransportErrorIsStillClassified() {
        let wrapped = NSError(
            domain: "AppKit.Client", code: 1,
            userInfo: [NSUnderlyingErrorKey: URLError(.timedOut)]
        )
        XCTAssertEqual(NetworkFailure.of(wrapped), "timeout")
    }

    /// A Swift enum carrying the cause in an associated value has no `userInfo`, so it bridges to an
    /// `NSError` the walk cannot see into. It falls back to `io` rather than guessing, and a caller
    /// that wants better passes the cause — documented rather than silently wrong.
    func testASwiftEnumWrapperFallsBackRatherThanGuessing() {
        XCTAssertEqual(NetworkFailure.of(AppError.network(underlying: URLError(.timedOut))), "io")
        XCTAssertEqual(NetworkFailure.of(URLError(.timedOut)), "timeout")
    }

    func testAnAppErrorIsNotAGuess() {
        XCTAssertEqual(NetworkFailure.of(Wrapped(underlying: URLError(.timedOut))), "io")
    }

    /// The reason for the whole type. `URLError` builds its description out of the request, so the
    /// URL — query, token and all — rides in the message. No output of this function may contain any
    /// of it.
    func testNoOutputEverCarriesTheURLOrAMessage() {
        let leaky = URLError(
            .timedOut,
            userInfo: [
                NSURLErrorFailingURLStringErrorKey:
                    "https://api.example.com/v1/me?token=eyJhbGciOiJIUzI1NiJ9",
                NSLocalizedDescriptionKey:
                    "The request to https://api.example.com/v1/me?token=eyJhbGciOiJIUzI1NiJ9 timed out.",
            ]
        )
        let word = NetworkFailure.of(leaky)
        XCTAssertEqual(word, "timeout")
        XCTAssertFalse(word.contains("eyJ"))
        XCTAssertFalse(word.contains("example.com"))
        XCTAssertFalse(word.contains(" "))
    }

    /// The set is closed, and the server's column is `LowCardinality(String)` on the strength of
    /// that. A future case added without a thought about the vocabulary fails here.
    func testEveryAnswerComesFromTheClosedSet() {
        let allowed: Set<String> = [
            "", "timeout", "dns", "tls", "connect", "connection_lost", "cancelled", "offline", "io",
        ]
        for raw in -4000...(-900) {
            let word = NetworkFailure.of(URLError(URLError.Code(rawValue: raw)))
            XCTAssertTrue(allowed.contains(word), "\(word) is outside the vocabulary (code \(raw))")
        }
    }
}

/// The gate on a failure class that came from outside Swift.
///
/// One caller has no `Error` to read: a request issued in JavaScript crosses the bridge as a word.
/// Trusting that word would let the closed vocabulary be widened from outside — and the server's
/// column is `LowCardinality(String)` on the strength of it being closed.
final class NetworkFailureValidationTests: XCTestCase {

    func testAKnownWordSurvives() {
        for word in NetworkFailure.vocabulary where !word.isEmpty {
            XCTAssertEqual(NetworkFailure.validated(word), word)
        }
    }

    func testEmptyMeansNoFailure() {
        XCTAssertEqual(NetworkFailure.validated(""), "")
        XCTAssertEqual(NetworkFailure.validated("   "), "")
    }

    /// Case and padding are the caller being loose, not the caller being wrong.
    func testCaseAndPaddingAreForgiven() {
        XCTAssertEqual(NetworkFailure.validated("TIMEOUT"), "timeout")
        XCTAssertEqual(NetworkFailure.validated("  Dns  "), "dns")
    }

    /// Anything unrecognised becomes `io` — the honest reading of "it failed and we cannot say
    /// how" — rather than being passed through into a column promised low cardinality.
    func testAnythingElseCollapsesToIo() {
        for raw in [
            "ECONNREFUSED", "timed out", "Error: network request failed", "🙂",
            String(repeating: "x", count: 500), "timeout;DROP TABLE events",
        ] {
            let word = NetworkFailure.validated(raw)
            XCTAssertEqual(word, "io", "for \(raw)")
        }
    }

    /// The property, stated as one: nothing this function returns is outside the set.
    func testNoOutputEverLeavesTheVocabulary() {
        let allowed = NetworkFailure.vocabulary.union([""])
        for raw in ["", "dns", "nonsense", "OFFLINE", "  ", "cancelled ", "http_500"] {
            XCTAssertTrue(
                allowed.contains(NetworkFailure.validated(raw)),
                "\(raw) produced something outside the vocabulary"
            )
        }
    }
}
