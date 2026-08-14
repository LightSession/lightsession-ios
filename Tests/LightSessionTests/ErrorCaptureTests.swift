import XCTest
@testable import LightSession

/// The crash handler's discipline, tested on the JVM's Apple cousin — a plain process, calmly.
///
/// The invariants here only ever run while an app is dying, which is the worst possible place to
/// discover them wrong. Reduced to a latch, a capture closure and a previous handler, every one of
/// them can be walked by an ordinary test — the same reasoning the Android SDK records on its
/// CrashHandler, whose behaviour this mirrors.
final class ErrorCaptureTests: XCTestCase {

    override func tearDown() {
        ErrorCapture.resetForTest()
        super.tearDown()
    }

    private func exception(_ name: String = "TestException") -> NSException {
        NSException(
            name: NSExceptionName(name),
            reason: "raised on purpose",
            userInfo: nil
        )
    }

    func testTheCaptureRunsOnceAndThePreviousHandlerAlwaysRuns() {
        var captured: [NSException] = []
        var forwarded: [NSException] = []
        ErrorCapture.resetForTest(previous: { forwarded.append($0) })
        ErrorCapture.install { captured.append($0) }

        let first = exception("First")
        ErrorCapture.handle(first)

        XCTAssertEqual(captured.count, 1)
        XCTAssertTrue(captured[0] === first, "the capture sees the crash the app actually had")
        XCTAssertEqual(forwarded.count, 1)
        XCTAssertTrue(
            forwarded[0] === first,
            "the previous handler gets the original exception, not anything of ours"
        )

        // A second thread crashing while the first is being written — or the capture path raising
        // into itself — must fall straight through to the previous handler, not re-enter.
        let second = exception("Second")
        ErrorCapture.handle(second)

        XCTAssertEqual(captured.count, 1, "one capture per process death")
        XCTAssertEqual(forwarded.count, 2, "the chain is unconditional; only the capture is one-shot")
        XCTAssertTrue(forwarded[1] === second)
    }

    func testAMissingPreviousHandlerIsNotAnError() {
        var captured = 0
        ErrorCapture.resetForTest(previous: nil)
        ErrorCapture.install { _ in captured += 1 }
        ErrorCapture.handle(exception())
        XCTAssertEqual(captured, 1)
    }

    func testAnExceptionSerialisesIntoASingleLink() {
        let links = ErrorCrumb.exceptions(for: exception("NSRangeException"), appModule: "App")
        XCTAssertEqual(links.count, 1, "an NSException has no cause chain on this platform")
        XCTAssertEqual(links[0]["type"] as? String, "NSRangeException")
        XCTAssertEqual(links[0]["message"] as? String, "raised on purpose")
        XCTAssertNotNil(links[0]["frames"])
    }
}
