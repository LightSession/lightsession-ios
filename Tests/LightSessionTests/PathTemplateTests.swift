import XCTest
@testable import LightSession

/// The collapsing, which is the part of network capture that decides whether a customer's user ids
/// reach our database.
///
/// Every case here is a rule with a reason, and the ones marked as such were failures first — the
/// email case shipped wrong on the Android side and was caught by a test like this one, which is
/// why it is written down twice.
final class PathTemplateTests: XCTestCase {

    // MARK: - What survives

    func testRouteWordsSurvive() {
        XCTAssertEqual(PathTemplate.of("/v1/users"), "/v1/users")
        XCTAssertEqual(PathTemplate.of("/api/v2/orders/summary"), "/api/v2/orders/summary")
        XCTAssertEqual(PathTemplate.of("/oauth2/token"), "/oauth2/token")
        XCTAssertEqual(PathTemplate.of("/"), "/")
    }

    /// A trailing slash is a different path from none and both are kept as given — collapsing is
    /// about values, not about tidying.
    func testShapeIsPreserved() {
        XCTAssertEqual(PathTemplate.of("/v1/users/"), "/v1/users/")
    }

    // MARK: - What collapses

    func testNumericSegmentBecomesId() {
        XCTAssertEqual(PathTemplate.of("/v1/users/84321/orders"), "/v1/users/{id}/orders")
    }

    func testUUIDBecomesItsOwnMarker() {
        XCTAssertEqual(
            PathTemplate.of("/projects/1e527025-c3ae-40c1-bf98-7d6a67e759a6/events"),
            "/projects/{uuid}/events"
        )
    }

    /// A bare 32-hex run is a hash, not a UUID, and must not be reported as one — `{uuid}` is a
    /// claim about the shape of the id that a reader will act on.
    func testUnhyphenatedHexIsAnIdNotAUUID() {
        XCTAssertEqual(PathTemplate.of("/x/e8b49506e2034b2e92f3fde7380810f5"), "/x/{id}")
    }

    func testLongMixedSegmentIsAnId() {
        XCTAssertEqual(PathTemplate.of("/files/a1b2c3d4e5f6g7"), "/files/{id}")
    }

    func testShortMixedSegmentIsAWord() {
        XCTAssertEqual(PathTemplate.of("/v1/api2/oauth2"), "/v1/api2/oauth2")
    }

    func testVeryLongWordIsAnId() {
        XCTAssertEqual(PathTemplate.of("/x/" + String(repeating: "a", count: 40)), "/x/{id}")
    }

    // MARK: - The email case, which was a real bug

    /// The extension carve-out used to run before the alphabet check, so `maria@example.com` became
    /// `{id}.com` — and `.com` is not an extension, it is the tail of a domain that had just been
    /// published to our database. Found on the Android side and ported with the fix.
    func testEmailIsFullyCollapsedAndPublishesNoDomain() {
        let collapsed = PathTemplate.of("/users/maria@example.com/profile")
        XCTAssertEqual(collapsed, "/users/{id}/profile")
        XCTAssertFalse(collapsed.contains("example"))
        XCTAssertFalse(collapsed.contains(".com"))
    }

    /// A real extension is not data, and `/assets/logo.png` versus `/assets/{id}.png` are different
    /// questions — so the carve-out is kept, just not first.
    func testFileExtensionsSurviveOnTheirStem() {
        XCTAssertEqual(PathTemplate.of("/assets/logo.png"), "/assets/logo.png")
        XCTAssertEqual(PathTemplate.of("/assets/8842.png"), "/assets/{id}.png")
        XCTAssertEqual(
            PathTemplate.of("/assets/a1b2c3d4e5f6g7h8.png"),
            "/assets/{id}.png"
        )
    }

    /// An id with an extension on it is still an id. The stem used to skip the digit and UUID rules,
    /// so a numbered or UUID-named file published its name — the quiet half of the failure being
    /// that it also minted one endpoint per file, which is the endpoint list destroying itself.
    func testAnIdWearingAnExtensionIsStillAnId() {
        XCTAssertEqual(PathTemplate.of("/assets/8842.png"), "/assets/{id}.png")
        XCTAssertEqual(
            PathTemplate.of("/f/1e527025-c3ae-40c1-bf98-7d6a67e759a6.pdf"),
            "/f/{uuid}.pdf"
        )
        XCTAssertEqual(PathTemplate.of("/f/report.tar.gz"), "/f/report.tar.gz")
    }

    // MARK: - Values that are not ids but are still not route words

    func testAnythingOutsideTheRouteAlphabetIsAnId() {
        XCTAssertEqual(PathTemplate.of("/v1/find/name%20surname"), "/v1/find/{id}")
        XCTAssertEqual(PathTemplate.of("/v1/at/-23.5505,-46.6333"), "/v1/at/{id}")
        XCTAssertEqual(PathTemplate.of("/v1/k/a=b"), "/v1/k/{id}")
        XCTAssertEqual(PathTemplate.of("/v1/k/urn:ietf:rfc:1234"), "/v1/k/{id}")
    }

    // MARK: - The query, which is never read at all

    func testQueryAndFragmentAreDroppedEntirely() {
        XCTAssertEqual(PathTemplate.of("/v1/me?token=eyJhbGciOiJIUzI1NiJ9"), "/v1/me")
        XCTAssertEqual(PathTemplate.of("/v1/me#access_token=abc123"), "/v1/me")
        XCTAssertEqual(PathTemplate.of("/v1/me?a=1#b=2"), "/v1/me")
    }

    /// The property, stated as a property rather than as three examples: nothing after a `?` or a
    /// `#` can appear in the output, whatever it is.
    func testNoSecretInAQueryCanReachTheOutput() {
        let secrets = [
            "token=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.abc.def",
            "api_key=sk_live_51H8xQ2",
            "password=hunter2",
            "cpf=12345678900",
        ]
        for secret in secrets {
            let collapsed = PathTemplate.of("/v1/me?\(secret)")
            XCTAssertEqual(collapsed, "/v1/me", "query leaked for \(secret)")
        }
    }

    // MARK: - Refusals

    func testANonPathIsRefusedRatherThanGuessedAt() {
        XCTAssertEqual(PathTemplate.of(""), "")
        XCTAssertEqual(PathTemplate.of("v1/users"), "")
        XCTAssertEqual(PathTemplate.of("https://api.example.com/v1/me"), "")
    }

    func testAnAbsurdlyLongTemplateIsRefused() {
        let long = "/" + (0..<40).map { _ in "segmentname" }.joined(separator: "/")
        XCTAssertEqual(PathTemplate.of(long), "")
    }

    /// Empty segments from a doubled slash are kept as empty rather than collapsed to `{id}`: `//`
    /// is a shape the app produced, and reporting it as an id would hide a URL-building bug.
    func testDoubledSlashesAreNotIds() {
        XCTAssertEqual(PathTemplate.of("/v1//users"), "/v1//users")
    }
}
