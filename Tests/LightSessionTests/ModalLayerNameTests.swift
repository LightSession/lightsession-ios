import XCTest
@testable import LightSession

/// Which controllers become a modal sub-screen, and — the half that was missing — which must not.
///
/// This test exists because its absence shipped twice in two directions. First a guard that
/// recognised only alerts and React Native's host, so a SwiftUI sheet was never mapped at all.
/// Then a guard that asked `presentingViewController != nil`, which is true for anything *inside* a
/// presented stack, so a pushed screen and a keyboard host became phantom nodes named `Modal` and
/// `Sheet` with edges out of a login screen nobody had left.
///
/// Both failures are one sentence in a table here. The lesson is the one the file this tests
/// already stated for its neighbour: a decision with more than one wrong answer belongs in a pure
/// function, where every wrong answer can be written down.
final class ModalLayerNameTests: XCTestCase {

    // MARK: - Not modals

    /// The regression that reached a real app: a screen pushed inside a presented navigation stack
    /// has a `presentingViewController`, and is not a modal.
    func testAPushedScreenIsNotAModal() {
        XCTAssertNil(
            modalLayerName(
                className: "_TtGC7SwiftUI19UIHostingControllerVQ_",
                isPresentedItself: false,
                isInScreenWindow: true,
                isAlreadyNamedByApp: false,
                shape: .other,
                identifier: nil
            ),
            "a push inside a presented stack reports a presenter and presented nothing itself"
        )
    }

    func testAKeyboardHostIsNotAModal() {
        XCTAssertNil(
            modalLayerName(
                className: "UIInputWindowController",
                isPresentedItself: false,
                isInScreenWindow: true,
                isAlreadyNamedByApp: false,
                shape: .other,
                identifier: nil
            ),
            "the keyboard's own controllers are nested in somebody else's presentation"
        )
    }

    func testARootIsNotAModal() {
        XCTAssertNil(
            modalLayerName(
                className: "UINavigationController",
                isPresentedItself: false,
                isInScreenWindow: true,
                isAlreadyNamedByApp: false,
                shape: .other,
                identifier: nil
            )
        )
    }

    /// A sheet's *content* — a controller inside the sheet's own navigation stack — must not be a
    /// second modal layer over the sheet it lives in.
    func testAControllerInsideASheetIsNotItsOwnModal() {
        XCTAssertNil(
            modalLayerName(
                className: "UIViewController",
                isPresentedItself: false,
                isInScreenWindow: true,
                isAlreadyNamedByApp: false,
                shape: .sheet,
                identifier: nil
            ),
            "the shape says sheet because it inherits the presentation, not because it is one"
        )
    }

    /// The one that reached a real app, captured from the device rather than reasoned about.
    ///
    /// Submitting a login form makes iOS offer to save the password. The offer is a genuine
    /// presentation — `UIKeyboardHiddenViewController_Save` presenting
    /// `_SFAppPasswordSavingViewController` — so the identity check passes honestly. But it lives in
    /// `UITextEffectsWindow`, the keyboard's own window, and it arrives one screen *after* the form:
    /// it became a node called `Modal` hanging off an MFA screen whose code presents nothing at all,
    /// with edges in and out.
    func testTheSystemsSavePasswordOfferIsNotThisScreensModal() {
        XCTAssertNil(
            modalLayerName(
                className: "UIKeyboardHiddenViewController_Save",
                isPresentedItself: true,
                isInScreenWindow: false,
                isAlreadyNamedByApp: false,
                shape: .other,
                identifier: nil
            ),
            "a presentation in the keyboard's window is over that window, not over this screen"
        )
    }

    /// And the window rule outranks the bridge's class check, which used to answer first.
    func testEvenTheReactNativeHostMustBeInThisWindow() {
        XCTAssertNil(
            modalLayerName(
                className: "RCTModalHostViewController",
                isPresentedItself: false,
                isInScreenWindow: false,
                isAlreadyNamedByApp: false,
                shape: .other,
                identifier: nil
            )
        )
    }

    /// The other one from the same app: one presentation counted twice.
    ///
    /// A `.sheet` carrying `.lightSessionSubScreen("Trocar empresa")` is noticed by two mechanisms —
    /// the content's `onAppear` names it, and its hosting controller's `viewDidAppear` arrives here a
    /// moment later. Both fired, and the map recorded `dispatches › Trocar empresa › Sheet`: a level
    /// the app does not have, with the developer's own name demoted to a parent of a word invented
    /// for the same sheet.
    func testAPresentationTheAppAlreadyNamedGetsNoSecondLayer() {
        XCTAssertNil(
            modalLayerName(
                className: "_TtGC7SwiftUI19UIHostingControllerVQ_",
                isPresentedItself: true,
                isInScreenWindow: true,
                isAlreadyNamedByApp: true,
                shape: .sheet,
                identifier: nil
            ),
            "the app named this sheet from inside it; naming it again for its shape stacks one thing twice"
        )
    }

    /// And the guard is about *this* presentation, not about the screen having any named part: with
    /// nothing declared, the same sheet is still a layer. Otherwise the fix would be "never add one".
    func testAnUnnamedSheetIsStillALayer() {
        XCTAssertEqual(
            modalLayerName(
                className: "_TtGC7SwiftUI19UIHostingControllerVQ_",
                isPresentedItself: true,
                isInScreenWindow: true,
                isAlreadyNamedByApp: false,
                shape: .sheet,
                identifier: nil
            ),
            "Sheet"
        )
    }

    // MARK: - Modals

    func testASheetIsNamedForItsShape() {
        XCTAssertEqual(
            modalLayerName(
                className: "_TtGC7SwiftUI19UIHostingControllerVQ_",
                isPresentedItself: true,
                isInScreenWindow: true,
                isAlreadyNamedByApp: false,
                shape: .sheet,
                identifier: nil
            ),
            "Sheet"
        )
    }

    func testAFullScreenPresentationIsAModal() {
        XCTAssertEqual(
            modalLayerName(
                className: "UIViewController",
                isPresentedItself: true,
                isInScreenWindow: true,
                isAlreadyNamedByApp: false,
                shape: .other,
                identifier: nil
            ),
            "Modal"
        )
    }

    /// React Native presents its host itself, and it is a modal whatever the presentation says —
    /// the one case that does not go through the identity check.
    func testTheReactNativeHostIsAlwaysAModal() {
        XCTAssertEqual(
            modalLayerName(
                className: "RCTModalHostViewController",
                isPresentedItself: false,
                isInScreenWindow: true,
                isAlreadyNamedByApp: false,
                shape: .other,
                identifier: nil
            ),
            "Modal",
            "the bridge's host is recognised by what it is, not by how it was presented"
        )
    }

    // MARK: - Naming

    func testTheAppsOwnIdentifierWins() {
        XCTAssertEqual(
            modalLayerName(
                className: "UIViewController",
                isPresentedItself: true,
                isInScreenWindow: true,
                isAlreadyNamedByApp: false,
                shape: .sheet,
                identifier: "Filtros"
            ),
            "Filtros",
            "the developer naming the thing beats a name derived from its shape"
        )
    }

    /// The trap the alert naming exists to avoid, applied here: a label built from a record would
    /// mint a node per record. `subScreenLabel` is what refuses it, and this pins that it is asked.
    func testALabelThatIsReallyDataIsRefused() {
        let fromARecord = String(repeating: "Pedido 84321 de Maria ", count: 8)
        XCTAssertEqual(
            modalLayerName(
                className: "UIViewController",
                isPresentedItself: true,
                isInScreenWindow: true,
                isAlreadyNamedByApp: false,
                shape: .sheet,
                identifier: fromARecord
            ),
            "Sheet",
            "an identifier too long to be a label falls back to the shape rather than becoming a node"
        )
    }
}
