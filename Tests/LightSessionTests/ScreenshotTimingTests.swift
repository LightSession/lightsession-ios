import XCTest
@testable import LightSession

/// When a real screenshot may be taken.
///
/// Every case here is a state the screen can be in five and a half seconds after the wireframe went out, which is
/// the point: the delay is what makes the capture worth having and also the whole risk of it.
final class ScreenshotTimingTests: XCTestCase {

    func testAnUntouchedScreenIsCaptured() {
        XCTAssertNil(
            ScreenshotTiming.decide(
                scheduledFor: "Home", currentScreen: "Home", wasTouched: false, isRecording: true
            )
        )
    }

    /// Cancelled, not postponed. The obvious reading of "untouched for five seconds" is a timer that restarts,
    /// and that is not the rule: if they interacted, the screen is no longer the one they arrived at, so a later
    /// capture would record a state nobody navigated to.
    func testATouchCancelsRatherThanDelays() {
        XCTAssertEqual(
            ScreenshotTiming.decide(
                scheduledFor: "Home", currentScreen: "Home", wasTouched: true, isRecording: true
            ),
            .touched
        )
    }

    func testLeavingTheScreenCancelsIt() {
        XCTAssertEqual(
            ScreenshotTiming.decide(
                scheduledFor: "Home", currentScreen: "Form", wasTouched: false, isRecording: true
            ),
            .navigatedAway
        )
    }

    /// A screen that has not been reported yet is not the screen this was scheduled for.
    func testNoCurrentScreenCountsAsHavingLeft() {
        XCTAssertEqual(
            ScreenshotTiming.decide(
                scheduledFor: "Home", currentScreen: nil, wasTouched: false, isRecording: true
            ),
            .navigatedAway
        )
    }

    /// Several seconds pass between scheduling and firing, and recording can be turned off in them. Checked at
    /// fire time rather than trusted from schedule time.
    func testRecordingStoppedDuringTheWaitCancelsIt() {
        XCTAssertEqual(
            ScreenshotTiming.decide(
                scheduledFor: "Home", currentScreen: "Home", wasTouched: false, isRecording: false
            ),
            .recordingStopped
        )
    }

    /// Recording being off is reported over the other reasons, because it is the one the app asked for and the
    /// one whose absence from a log would be confusing.
    func testRecordingStoppedIsReportedFirst() {
        XCTAssertEqual(
            ScreenshotTiming.decide(
                scheduledFor: "Home", currentScreen: "Form", wasTouched: true, isRecording: false
            ),
            .recordingStopped
        )
    }

    /// Android's constant to the millisecond. The two platforms fill the same slot in the same product, and a
    /// screenshot taken at a different moment is a different picture of the same screen.
    func testTheQuietPeriodMatchesAndroid() {
        XCTAssertEqual(ScreenshotTiming.quietPeriod, 5.5)
    }
}
