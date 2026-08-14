import XCTest
@testable import LightSession

/// The bar that replaced "sent".
///
/// The boolean it replaced made the first wireframe permanent: a loading screen whose late-content
/// watch a touch killed stored the spinner for the life of the install, and every install predating
/// a reader improvement held wireframes a newer scan would beat. The bar converges instead — richer
/// ships, equal-or-poorer is silence — and these tests pin the ratchet itself, mirroring the five
/// the Android SDK keeps: unknown is zero, the bar never falls, equal does not raise it, richer
/// does, and two captures do not share one.
final class CaptureCacheTests: XCTestCase {

    /// In-memory storage, so a test exercises the cache's rules and not `UserDefaults`.
    private final class MemoryStorage: CaptureCacheStorage {
        var values: [String: String] = [:]
        func string(forKey key: String) -> String? { values[key] }
        func set(_ value: String?, forKey key: String) { values[key] = value }
        func removeAll(withPrefix prefix: String) {
            values = values.filter { !$0.key.hasPrefix(prefix) }
        }
    }

    private func makeCache(_ storage: MemoryStorage = MemoryStorage()) -> CaptureCache {
        CaptureCache(storage: storage, appVersion: "1.0")
    }

    func testAnUnknownCaptureHasBarZero() {
        let cache = makeCache()
        XCTAssertEqual(cache.state(forCapture: "s1"), .none)
        XCTAssertEqual(cache.state(forCapture: "s1").wireframeRects, 0)
    }

    func testTheBarNeverFalls() {
        let cache = makeCache()
        cache.recordWireframe(forCapture: "s1", rects: 81)
        cache.recordWireframe(forCapture: "s1", rects: 37)
        XCTAssertEqual(
            cache.state(forCapture: "s1").wireframeRects, 81,
            "sends race — a first capture completing after a late upgrade must not lower the bar"
        )
    }

    func testAnEqualSendDoesNotChangeTheBar() {
        let cache = makeCache()
        cache.recordWireframe(forCapture: "s1", rects: 37)
        cache.recordWireframe(forCapture: "s1", rects: 37)
        XCTAssertEqual(cache.state(forCapture: "s1").wireframeRects, 37)
    }

    func testARicherSendRaisesTheBar() {
        let cache = makeCache()
        cache.recordWireframe(forCapture: "s1", rects: 37)
        cache.recordWireframe(forCapture: "s1", rects: 81)
        XCTAssertEqual(cache.state(forCapture: "s1").wireframeRects, 81)
    }

    func testTwoCapturesDoNotShareABar() {
        let cache = makeCache()
        cache.recordWireframe(forCapture: "s1", rects: 81)
        cache.recordWireframe(forCapture: "s2", rects: 5)
        XCTAssertEqual(cache.state(forCapture: "s1").wireframeRects, 81)
        XCTAssertEqual(cache.state(forCapture: "s2").wireframeRects, 5)
    }

    /// An entry written before the bar existed: `wireframe`, no count.
    ///
    /// It parses as bar 0, which makes any capture with a single rectangle "richer" — so every
    /// legacy install resends each stale screen once, records the bar, and goes quiet. That one send
    /// per screen is the healing, not a bug.
    func testALegacyEntryParsesAsBarZero() {
        let storage = MemoryStorage()
        let cache = makeCache(storage)
        storage.values["com.lightsession.capture.s1"] = "wireframe"
        let state = cache.state(forCapture: "s1")
        XCTAssertTrue(state.hasWireframe)
        XCTAssertFalse(state.hasScreenshot)
        XCTAssertEqual(state.wireframeRects, 0)
    }

    func testAScreenshotPreservesTheBar() {
        let cache = makeCache()
        cache.recordWireframe(forCapture: "s1", rects: 81)
        cache.recordScreenshot(forCapture: "s1")
        let state = cache.state(forCapture: "s1")
        XCTAssertTrue(state.hasScreenshot)
        XCTAssertEqual(
            state.wireframeRects, 81,
            "the wireframe layer keeps existing beside the screenshot server-side; "
                + "forgetting its richness would resend it on the next visit"
        )
    }

    /// The rule the boolean version enforced, kept under the bar: a wireframe landing after the
    /// screenshot must not erase the knowledge that the real screen is up there — but its count
    /// still raises the bar, because the two live in different layers server-side.
    func testAWireframeAfterAScreenshotKeepsTheScreenshotAndRaisesTheBar() {
        let cache = makeCache()
        cache.recordWireframe(forCapture: "s1", rects: 37)
        cache.recordScreenshot(forCapture: "s1")
        cache.recordWireframe(forCapture: "s1", rects: 81)
        let state = cache.state(forCapture: "s1")
        XCTAssertTrue(state.hasScreenshot, "the screenshot marker must survive a late wireframe")
        XCTAssertEqual(state.wireframeRects, 81)
    }
}
