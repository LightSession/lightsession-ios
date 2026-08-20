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
