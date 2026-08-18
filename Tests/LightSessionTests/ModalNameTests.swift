import XCTest
@testable import LightSession

/// A name for an un-named modal that differs when the modal differs, and never when it does not.
///
/// The bug: the fallback was one word for the shape, so two different un-named sheets on one screen
/// composed to the same name and the same capture id. One silently replaced the other — or, when the
/// cache bar judged the first richer, the second was discarded and never appeared at all. One node
/// standing in for two screens, with nothing anywhere saying so.
///
/// The facts here are measured, not invented. Two SwiftUI `.sheet`s on one screen arrive as the same
/// class (`PresentationHostingController<AnyView>`, content type erased) with the same
/// `modalPresentationStyle`; only their detents differed. Every case below uses values read off a
/// running app.
final class ModalNameTests: XCTestCase {

    private func name(
        identifier: String? = nil,
        isSheet: Bool = true,
        styleRaw: Int = 1,
        detents: [String] = [],
        grabber: Bool = false,
        radius: Double? = nil
    ) -> String {
        ScreenIdentity.modalName(
            identifier: identifier,
            isSheet: isSheet,
            styleRaw: styleRaw,
            detentIdentifiers: detents,
            prefersGrabberVisible: grabber,
            cornerRadius: radius
        )
    }

    // MARK: - Telling two modals apart

    /// The case this exists for, with the values the sample actually produced: same class, same
    /// style, different detents.
    func testTwoSheetsThatDifferOnlyByDetentGetDifferentNames() {
        let filters = name(styleRaw: 2, detents: ["com.apple.UIKit.medium"])
        let share = name(styleRaw: 2, detents: ["com.apple.UIKit.large"])
        XCTAssertNotEqual(
            filters, share,
            "these two shared a node in a real app; the detents are the only thing that separated them"
        )
    }

    func testASheetAndAFullScreenModalGetDifferentNames() {
        XCTAssertNotEqual(name(isSheet: true, styleRaw: 1), name(isSheet: false, styleRaw: 0))
    }

    func testTheOrderOfDetentsIsPartOfTheIdentity() {
        XCTAssertNotEqual(
            name(detents: ["com.apple.UIKit.medium", "com.apple.UIKit.large"]),
            name(detents: ["com.apple.UIKit.large", "com.apple.UIKit.medium"])
        )
    }

    func testGrabberAndCornerRadiusAreReadToo() {
        XCTAssertNotEqual(name(grabber: false), name(grabber: true))
        XCTAssertNotEqual(name(radius: nil), name(radius: 16))
    }

    // MARK: - Not telling the same modal apart from itself

    /// The half that matters as much: the same sheet opening twice is one node, not two. A name that
    /// varied per presentation would mint a node per visit, which is worse than the collision.
    func testTheSameConfigurationIsAlwaysTheSameName() {
        let once = name(styleRaw: 2, detents: ["com.apple.UIKit.large"], grabber: true, radius: 12)
        let again = name(styleRaw: 2, detents: ["com.apple.UIKit.large"], grabber: true, radius: 12)
        XCTAssertEqual(once, again)
    }

    /// Stable across launches, which `String.hashValue` is not — Swift seeds it per process, so a
    /// name built from it would differ every run and mint a node per launch.
    func testTheNameDoesNotDependOnSwiftsSeededStringHashing() {
        XCTAssertEqual(
            name(detents: ["com.apple.UIKit.medium"]),
            "sheet-" + String(format: "%06x", Self.expectedHash(
                styleRaw: 1, detents: ["com.apple.UIKit.medium"], grabber: false, radius: nil
            ) & 0xFFFFFF),
            "the digits must be reproducible from the bytes alone, in this process or any other"
        )
    }

    /// A radius is a layout value; a fraction of a point is not a different sheet.
    func testAFractionOfAPointIsNotADifferentSheet() {
        XCTAssertEqual(name(radius: 16.0), name(radius: 16.4))
    }

    // MARK: - Naming

    func testTheAppsIdentifierStillWinsOutright() {
        XCTAssertEqual(name(identifier: "Trocar empresa", detents: ["x"]), "Trocar empresa")
    }

    func testAnIdentifierThatIsReallyDataFallsBackToStructure() {
        let fromARecord = String(repeating: "Pedido 84321 de Maria ", count: 8)
        XCTAssertEqual(name(identifier: fromARecord), name())
    }

    func testTheNameSaysWhichKindItWas() {
        XCTAssertTrue(name(isSheet: true).hasPrefix("sheet-"))
        XCTAssertTrue(name(isSheet: false, styleRaw: 0).hasPrefix("modal-"))
    }

    /// Recomputed here from the bytes, so the test pins the algorithm and not just its own output.
    private static func expectedHash(
        styleRaw: Int, detents: [String], grabber: Bool, radius: Double?
    ) -> Int64 {
        var hash: Int64 = 17
        func mix(_ value: Int) { hash = hash &* 31 &+ Int64(value) }
        mix(styleRaw)
        mix(detents.count)
        for detent in detents {
            for byte in detent.utf8 { mix(Int(byte)) }
            mix(0)
        }
        mix(grabber ? 1 : 0)
        mix(radius.map { Int($0.rounded()) } ?? -1)
        return hash
    }
}
