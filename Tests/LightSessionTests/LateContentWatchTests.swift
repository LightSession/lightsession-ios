#if canImport(UIKit)
import XCTest
@testable import LightSession

/// The tripwire's own semantics: one shot, silent while nothing changes, dead once cancelled.
///
/// UIKit-gated like the class it tests, so `swift test` on macOS skips it — run on a simulator:
///   xcodebuild test -scheme LightSession -destination 'platform=iOS Simulator,name=...' \
///     -only-testing:LightSessionTests/LateContentWatchTests
///
/// The signature is injected, so none of this needs a window: what is under test is the latch,
/// not the view walk, which has its own tests under `SkeletonBuilderTests`.
final class LateContentWatchTests: XCTestCase {

    /// Well past one 50 ms cadence plus its tolerance, so a tick that is going to happen has.
    private let beat: TimeInterval = 0.4

    private func spin(_ interval: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: interval))
    }

    func testFiresOnceOnAChangeAndNotBefore() {
        let watch = LateContentWatch(cadence: 0.05)
        var signature = ContentSignature(count: 1, geometry: 17)
        var fires = 0

        watch.arm(baseline: signature, signature: { signature }, onChanged: { fires += 1 })

        spin(beat)
        XCTAssertEqual(fires, 0, "an unchanged screen must never fire the watch")

        signature = ContentSignature(count: 9, geometry: 43)
        spin(beat)
        XCTAssertEqual(fires, 1, "the change should have tripped it")

        signature = ContentSignature(count: 20, geometry: 99)
        spin(beat)
        XCTAssertEqual(fires, 1, "one-shot: re-arming is the caller's decision, budgeted")
    }

    func testCancelDisarmsWithoutFiring() {
        let watch = LateContentWatch(cadence: 0.05)
        var signature = ContentSignature(count: 1, geometry: 17)
        var fires = 0

        watch.arm(baseline: signature, signature: { signature }, onChanged: { fires += 1 })
        watch.cancel()
        signature = ContentSignature(count: 9, geometry: 43)
        spin(beat)
        XCTAssertEqual(fires, 0, "a cancelled watch is dead, whatever the screen does after")
    }

    func testAVanishedWindowEndsTheWatch() {
        let watch = LateContentWatch(cadence: 0.05)
        var fires = 0
        var window: ContentSignature? = ContentSignature(count: 1, geometry: 17)

        watch.arm(
            baseline: ContentSignature(count: 1, geometry: 17),
            signature: { window },
            onChanged: { fires += 1 }
        )
        window = nil
        spin(beat)
        XCTAssertEqual(fires, 0, "nil means the window is gone; there is nothing to recapture")
    }

    func testAFreshArmReplacesThePreviousOne() {
        let watch = LateContentWatch(cadence: 0.05)
        var signature = ContentSignature(count: 1, geometry: 17)
        var first = 0
        var second = 0

        watch.arm(baseline: signature, signature: { signature }, onChanged: { first += 1 })
        watch.arm(baseline: signature, signature: { signature }, onChanged: { second += 1 })

        signature = ContentSignature(count: 9, geometry: 43)
        spin(beat)
        XCTAssertEqual(first, 0, "a screen waits for one arrival at a time; the newest arm wins")
        XCTAssertEqual(second, 1)
    }
}
#endif
