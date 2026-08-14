import XCTest
@testable import LightSession

/// The serializer that runs while the process is dying, tested where it can be walked calmly.
///
/// Every bound here exists because its absence has a failure mode on the way down: an unbounded
/// cause walk turns a crash with a report into a hang without one, an uncapped stack ships a
/// thousand identical frames, an uncapped message ships a request body someone concatenated into
/// a description.
final class ErrorCrumbTests: XCTestCase {

    private enum Boom: Error { case bad }

    /// An `NSError` whose userInfo points back at itself — constructible, so guarded.
    private final class CyclicError: NSError, @unchecked Sendable {
        override var userInfo: [String: Any] { [NSUnderlyingErrorKey: self] }
    }

    private func nsError(
        _ domain: String, _ code: Int, message: String? = nil, underlying: NSError? = nil
    ) -> NSError {
        var info: [String: Any] = [:]
        if let message { info[NSLocalizedDescriptionKey] = message }
        if let underlying { info[NSUnderlyingErrorKey] = underlying }
        return NSError(domain: domain, code: code, userInfo: info)
    }

    func testTheCauseChainIsOutermostFirst() {
        let root = nsError("root", 3)
        let middle = nsError("middle", 2, underlying: root)
        let outer = nsError("outer", 1, underlying: middle)

        let links = ErrorCrumb.exceptions(for: outer, stack: [], appModule: "App")
        XCTAssertEqual(links.count, 3)
        XCTAssertEqual(links[0]["domain"] as? String, "outer", "index 0 is what reached the handler")
        XCTAssertEqual(links[1]["domain"] as? String, "middle")
        XCTAssertEqual(links[2]["domain"] as? String, "root", "the last entry is the root cause")
    }

    func testACauseCycleIsBrokenByIdentity() {
        let cyclic = CyclicError(domain: "loop", code: 1)
        let links = ErrorCrumb.exceptions(for: cyclic, stack: [], appModule: "App")
        XCTAssertEqual(links.count, 1, "the same object appearing twice is the cycle being guarded")
    }

    func testTheChainStopsAtEight() {
        var current = nsError("d0", 0)
        for i in 1...12 { current = nsError("d\(i)", i, underlying: current) }
        let links = ErrorCrumb.exceptions(for: current, stack: [], appModule: "App")
        XCTAssertEqual(links.count, ErrorCrumb.maxCauses)
    }

    func testAMessageIsCapped() {
        let error = nsError("d", 1, message: String(repeating: "x", count: 5_000))
        let links = ErrorCrumb.exceptions(for: error, stack: [], appModule: "App")
        XCTAssertEqual((links[0]["message"] as? String)?.count, ErrorCrumb.maxMessage)
    }

    func testTheSwiftTypeNamesTheOutermostLink() {
        let links = ErrorCrumb.exceptions(for: Boom.bad, stack: [], appModule: "App")
        XCTAssertEqual(links.count, 1)
        XCTAssertTrue(
            (links[0]["type"] as? String)?.hasSuffix("Boom") == true,
            "the thrown value's own type, not the NSError bridge it crossed"
        )
    }

    func testOnlyTheFirstLinkCarriesTheStack() {
        let outer = nsError("outer", 1, underlying: nsError("root", 2))
        let stack = ["0   App   0x0000000000000001 caught + 1"]
        let links = ErrorCrumb.exceptions(for: outer, stack: stack, appModule: "App")
        XCTAssertEqual((links[0]["frames"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(
            (links[1]["frames"] as? [[String: Any]])?.count, 0,
            "an underlying NSError has no stack of its own on this platform; inventing one would lie"
        )
    }

    // MARK: - Frames

    func testASymbolLineParsesIntoModuleAndSymbol() {
        let frame = ErrorCrumb.frame(
            fromSymbolLine: "4   MyApp                     0x0000000102a1b2c3 $s5MyApp3fooyyF + 123",
            appModule: "MyApp"
        )
        XCTAssertEqual(frame["class"] as? String, "MyApp")
        XCTAssertEqual(frame["method"] as? String, "$s5MyApp3fooyyF + 123")
        XCTAssertEqual(frame["in_app"] as? Bool, true)
    }

    func testAModuleNameWithSpacesSurvivesParsing() {
        let frame = ErrorCrumb.frame(
            fromSymbolLine: "7   My App 0x0000000000000001 handler + 1",
            appModule: "My App"
        )
        XCTAssertEqual(frame["class"] as? String, "My App", "the address anchors the parse, not spaces")
        XCTAssertEqual(frame["in_app"] as? Bool, true)
    }

    func testAnUnparseableLineIsKeptWholeRatherThanDropped() {
        let frame = ErrorCrumb.frame(fromSymbolLine: "not a frame at all", appModule: "App")
        XCTAssertEqual(frame["class"] as? String, "?")
        XCTAssertEqual(frame["method"] as? String, "not a frame at all")
        XCTAssertEqual(frame["in_app"] as? Bool, false)
    }

    func testFramesAreCappedWithAnElisionMarker() {
        let symbols = (0..<200).map { "\($0)   App 0x0000000000000001 f\($0) + 1" }
        let frames = ErrorCrumb.frames(fromSymbols: symbols, appModule: "App")
        XCTAssertEqual(frames.count, ErrorCrumb.maxFrames + 1)
        XCTAssertEqual(
            frames.last?["method"] as? String, "80 frames elided",
            "a truncated trace says so instead of ending mid-air"
        )
        XCTAssertEqual(frames.last?["in_app"] as? Bool, false)
    }

    // MARK: - The envelope

    func testTheEnvelopeCarriesTheFieldsAndroidSends() {
        let event = ErrorEvent(
            sequence: 7,
            details: ErrorDetails(
                handled: false,
                threadName: "main",
                threadId: 259,
                exceptions: [["type": "T"]],
                attributes: ["gateway": "stripe", "attempt": 2],
                timestampMillis: 1_000
            ),
            userId: "u1",
            userType: .anonymous,
            appVersion: "1.0",
            screen: "checkout",
            screenId: "cap-1"
        )
        let crumb = event.breadcrumb
        XCTAssertEqual(crumb["type"] as? String, "error")
        XCTAssertEqual(crumb["timestamp"] as? Int64, 1_000)
        XCTAssertEqual(crumb["sequence"] as? Int, 7)
        XCTAssertEqual(crumb["user_id"] as? String, "u1")
        XCTAssertEqual(crumb["user_type"] as? String, "anonymous")
        XCTAssertEqual(crumb["app_version"] as? String, "1.0")
        XCTAssertEqual(crumb["handled"] as? Bool, false)
        XCTAssertEqual(crumb["thread"] as? String, "main")
        XCTAssertEqual(crumb["screen"] as? String, "checkout")
        XCTAssertEqual(crumb["screen_id"] as? String, "cap-1")
        XCTAssertNotNil(crumb["exceptions"])
        XCTAssertEqual((crumb["attributes"] as? [String: Any])?.count, 2)
    }

    func testAnUnknownScreenIsOmittedNotInvented() {
        let event = ErrorEvent(
            sequence: 1,
            details: ErrorDetails(
                handled: true, threadName: "main", threadId: 1,
                exceptions: [], attributes: [:], timestampMillis: 1
            ),
            userId: "u", userType: .anonymous, appVersion: "1",
            screen: nil, screenId: nil
        )
        XCTAssertNil(event.breadcrumb["screen"])
        XCTAssertNil(event.breadcrumb["screen_id"])
    }

    func testAttributesKeepOnlyWhatJSONCanCarry() {
        struct Opaque {}
        let kept = ErrorEvent.scalars([
            "s": "text", "i": 3, "d": 1.5, "b": true, "object": Opaque(),
        ])
        XCTAssertEqual(kept.count, 4)
        XCTAssertNil(kept["object"], "a domain object stringified would be stored as if it meant something")
    }
}
