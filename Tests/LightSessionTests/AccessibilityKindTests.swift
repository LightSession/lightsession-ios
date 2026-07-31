import XCTest
@testable import LightSession

/// What a view's accessibility traits imply about it.
///
/// These constants are UIKit's, and they are written down here so they can be checked rather than trusted. Two
/// were confirmed against a running app: `RCTParagraphComponentView` reported `64` and a `UIImageView` reported
/// `4`, which is how the reading of the table was verified rather than assumed.
final class AccessibilityKindTests: XCTestCase {

    /// The bug this exists for. React Native's `<Text>` on iOS is a plain `UIView` that draws its own text, so
    /// no superclass check finds it — and an unmasked paragraph is text left legible in a stored capture.
    func testStaticTextIsText() {
        XCTAssertEqual(AccessibilityKind.kind(forTraits: 64), .text)
    }

    func testTheObservedValuesMatchUIKitsTable() {
        XCTAssertEqual(AccessibilityKind.staticText, 64)
        XCTAssertEqual(AccessibilityKind.button, 1)
        XCTAssertEqual(AccessibilityKind.image, 4)
    }

    func testAButtonThatIsNotAControl() {
        // A React Native `Pressable` with `accessibilityRole="button"`, or a SwiftUI `Button`.
        XCTAssertEqual(AccessibilityKind.kind(forTraits: 1), .button)
    }

    func testASearchFieldIsAnInput() {
        XCTAssertEqual(AccessibilityKind.kind(forTraits: 1 << 8), .input)
    }

    func testNoTraitsImpliesNothing() {
        XCTAssertNil(AccessibilityKind.kind(forTraits: 0))
        // Selected + playsSound: real traits that say nothing about what the view holds.
        XCTAssertNil(AccessibilityKind.kind(forTraits: 8 | 16))
    }

    /// A labelled control claims both. Text wins, and the asymmetry is the point: being wrong this way costs a
    /// grey block where a label was, and being wrong the other way leaves a name readable in a capture.
    func testTextWinsOverButtonWhenBothAreClaimed() {
        XCTAssertEqual(AccessibilityKind.kind(forTraits: 64 | 1), .text)
    }

    func testTraitsAreReadAsAMaskRatherThanAValue() {
        // staticText alongside unrelated traits still reads as text.
        XCTAssertEqual(AccessibilityKind.kind(forTraits: 64 | 8 | 128), .text)
    }
}
