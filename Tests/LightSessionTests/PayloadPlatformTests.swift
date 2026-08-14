import XCTest
@testable import LightSession

/// The platform field, on every body that carries one.
///
/// The server checks it against the project the API key belongs to: a project created for iOS refuses
/// `android`, one created for React Native or Flutter accepts both, and one whose SDK sends nothing is
/// accepted as before. That last rule is why this test exists rather than being obviously unnecessary — a
/// missing value does not fail, it is *accepted by every project*, so a field dropped by a refactor turns the
/// check silently off and looks exactly like the bug it was added to catch.
///
/// The three bodies here had no test at all before this. They are the screen-map writes, and they are the ones
/// that produced the incident: an Android project's key in an iOS integration, two apps in one screen map.
final class PayloadPlatformTests: XCTestCase {
    private func screen(imageBase64: String?) -> ScreenReport {
        ScreenReport(
            compositeId: "Home_390x844_Light",
            name: "Home",
            kind: .uiKit,
            skeleton: nil,
            imageBase64: imageBase64,
            width: 390,
            height: 844,
            density: 3.0,
            theme: .light,
            appVersionName: "1.0.0",
            appVersionCode: 1
        )
    }

    func testCreateBodyNamesThePlatform() {
        XCTAssertEqual(screen(imageBase64: nil).createBody["platform"] as? String, "ios")
    }

    func testScreenshotBodyNamesThePlatform() {
        let body = screen(imageBase64: "AAAA").screenshotBody
        XCTAssertEqual(body?["platform"] as? String, "ios")
    }

    /// The one write with no other hint of where it came from: no screen type, no device info, no
    /// resolution. Without this field the server cannot check a flow at all.
    func testFlowBodyNamesThePlatform() {
        let flow = FlowReport(
            from: "Home",
            to: "Detail",
            transition: "push",
            appVersionName: "1.0.0",
            appVersionCode: 1
        )
        XCTAssertEqual(flow.body(timestampMillis: 0)["platform"] as? String, "ios")
    }

    /// The value the server folds iPadOS into as well. Pinned as a literal rather than compared against
    /// `Platform.name`, which would pass whatever that constant said.
    func testTheNameIsTheOneTheServerParses() {
        XCTAssertEqual(Platform.name, "ios")
    }
}

/// The density field, under the name the server pins from its side.
///
/// Mirrors `density_is_optional_on_the_wire_and_read_when_it_is_there` in ls-api: the server
/// tolerates its absence because old SDKs are phones in pockets, but *this* SDK must never be the
/// old one again — the session payload carried density from the start while the capture payload
/// did not, and every iOS capture was stored NULL and drawn on the frontend's assumption.
final class PayloadDensityTests: XCTestCase {
    private func screen(imageBase64: String?) -> ScreenReport {
        ScreenReport(
            compositeId: "Home_390x844_Light",
            name: "Home",
            kind: .uiKit,
            skeleton: nil,
            imageBase64: imageBase64,
            width: 390,
            height: 844,
            density: 3.0,
            theme: .light,
            appVersionName: "1.0.0",
            appVersionCode: 1
        )
    }

    func testCreateBodyCarriesTheDensity() {
        XCTAssertEqual(screen(imageBase64: nil).createBody["density"] as? Double, 3.0)
    }

    /// Matching Android: the replace route rewrites the image of a capture row the create already
    /// made, and the row carries the density. Writing it here too would be a second source of truth
    /// for the same cell.
    func testScreenshotBodyOmitsTheDensity() {
        let body = screen(imageBase64: "AAAA").screenshotBody
        XCTAssertNotNil(body)
        XCTAssertNil(body?["density"], "the screenshot replace must not carry density")
    }
}
