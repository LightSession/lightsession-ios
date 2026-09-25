import XCTest
@testable import LightSession

/// An error an embedder reports, sent in exactly the shape a native one takes — the server groups on
/// the exception's type and the `class.method` of its first in-app frames, and a field named
/// differently here would put a Dart error in a group of its own on iOS only.
final class ReportedErrorTests: XCTestCase {

    private func frames(_ exceptions: [[String: Any]]) -> [[String: Any]] {
        exceptions.first?["frames"] as? [[String: Any]] ?? []
    }

    func testAFrameIsSentAsANativeOneIs() {
        let exceptions = ErrorCrumb.reported(
            type: "StateError",
            message: "Bad state: no element",
            frames: [
                ErrorFrame(module: "CheckoutPage", function: "pay", file: "package:shop/checkout.dart", line: 42, inApp: true),
                ErrorFrame(module: "dart:async", function: "_rootRun"),
            ]
        )
        XCTAssertEqual(exceptions.count, 1, "one exception: nothing says this error wraps another")
        XCTAssertEqual(exceptions[0]["type"] as? String, "StateError", "the runtime's own name, which groups it")
        XCTAssertEqual(exceptions[0]["message"] as? String, "Bad state: no element")

        let sent = frames(exceptions)
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0]["class"] as? String, "CheckoutPage")
        XCTAssertEqual(sent[0]["method"] as? String, "pay")
        XCTAssertEqual(sent[0]["file"] as? String, "package:shop/checkout.dart")
        XCTAssertEqual(sent[0]["line"] as? Int, 42)
        XCTAssertEqual(sent[0]["in_app"] as? Bool, true)
        XCTAssertNil(sent[0]["addr"])

        XCTAssertNil(sent[1]["file"], "a file the runtime did not name is left out, not invented")
        XCTAssertNil(sent[1]["line"])
        XCTAssertEqual(sent[1]["in_app"] as? Bool, false)
    }

    /// An obfuscated build's frames are addresses, named by the server from the build's symbols.
    func testAnAddressIsSentInHex() {
        let sent = frames(ErrorCrumb.reported(
            type: "_Exception",
            message: nil,
            frames: [ErrorFrame(module: "", function: "", address: 0x1_d4f3c)]
        ))
        XCTAssertEqual(sent[0]["addr"] as? String, "0x1d4f3c")
        XCTAssertEqual(sent[0]["class"] as? String, "")
    }

    func testNoMessageIsLeftOut() {
        let exceptions = ErrorCrumb.reported(type: "T", message: nil, frames: [])
        XCTAssertNil(exceptions[0]["message"])
    }

    func testTheBoundsOfANativeErrorApply() {
        let deep = (0..<200).map { ErrorFrame(module: "M", function: "f\($0)") }
        let exceptions = ErrorCrumb.reported(
            type: "T",
            message: String(repeating: "x", count: 5_000),
            frames: deep
        )
        XCTAssertEqual((exceptions[0]["message"] as? String)?.count, ErrorCrumb.maxMessage)
        let sent = frames(exceptions)
        XCTAssertEqual(sent.count, ErrorCrumb.maxFrames + 1)
        XCTAssertEqual(sent.last?["method"] as? String, "80 frames elided")
        XCTAssertEqual(sent.last?["in_app"] as? Bool, false)
    }

    func testTheSymbolsBlockNamesTheBuildAsTheServerStoresIt() {
        let full = ErrorSymbols(kind: "dart", buildId: "6A4F0C2B9E", arch: "arm64", appPackage: "shop").wire
        XCTAssertEqual(full["kind"] as? String, "dart")
        XCTAssertEqual(full["build_id"] as? String, "6a4f0c2b9e", "lowercase, as every runtime prints it")
        XCTAssertEqual(full["arch"] as? String, "arm64")
        XCTAssertEqual(full["app_package"] as? String, "shop")

        let bare = ErrorSymbols(kind: "dart", buildId: "ab").wire
        XCTAssertEqual(bare.count, 2)
    }

    // MARK: - The envelope

    private func event(_ details: ErrorDetails) -> [String: Any] {
        ErrorEvent(
            sequence: 1, details: details, userId: "u", userType: .anonymous, appVersion: "1",
            screen: "/checkout", screenId: "cap-1"
        ).breadcrumb
    }

    func testAReportedErrorSaysHowItArrivedAndNamesNoPlatformThread() {
        let crumb = event(ErrorDetails(
            handled: true,
            threadName: "main",
            threadId: nil,
            exceptions: ErrorCrumb.reported(type: "StateError", message: nil, frames: []),
            attributes: [:],
            timestampMillis: 1,
            mechanism: "platform_dispatcher",
            symbols: ErrorSymbols(kind: "dart", buildId: "AB")
        ))
        XCTAssertEqual(crumb["mechanism"] as? String, "platform_dispatcher")
        XCTAssertEqual((crumb["symbols"] as? [String: Any])?["build_id"] as? String, "ab")
        XCTAssertNil(crumb["thread_id"], "the runtime's thread is not a platform thread")
        XCTAssertEqual(crumb["thread"] as? String, "main")
        XCTAssertEqual(crumb["screen"] as? String, "/checkout", "attributed to its screen like any error")
    }

    func testANativeErrorIsAsItWas() {
        let crumb = event(ErrorDetails(
            handled: true, threadName: "main", threadId: 259,
            exceptions: [], attributes: [:], timestampMillis: 1
        ))
        XCTAssertEqual(crumb["thread_id"] as? UInt, 259)
        XCTAssertNil(crumb["mechanism"])
        XCTAssertNil(crumb["symbols"])
    }
}
