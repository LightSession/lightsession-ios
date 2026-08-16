#if canImport(UIKit)
import XCTest
import SwiftUI
@testable import LightSession

/// Where a modal's corner radius actually lives on this platform.
///
/// Written as a probe rather than a regression test: every assertion is about *UIKit's* behaviour,
/// not the SDK's, so a failure means an assumption behind the reader has changed. The Android SDK
/// asked the same question of Compose and got a surprising answer — the value was not in the View
/// outline at all — which is why this is measured here before anything reads it.
///
/// The question matters because of what must not happen. Rounding sheets by default would look
/// right for most apps and be confidently wrong for the one that squared its corners on purpose,
/// and inventing UI a customer does not have is a failure this SDK has paid for before. So the
/// rule is: read what the app declared, and absent means square. This probe establishes whether
/// there is anything to read.
///
/// ## What it measured
///
/// A `UIAlertController` declares **r=34, all four corners**, on its own view's layer — readable,
/// and the SDK reads it. A `.pageSheet` declares **r=0**: its rounding is applied by the
/// presentation machinery outside the app's view, so there is nothing on the app's side to read.
///
/// That asymmetry is the finding, and the SDK acts on it by doing nothing: a sheet is reported
/// square. Reaching for the system's radius would mean hard-coding a number Apple owns and changes
/// between releases, on a shape the app never declared — the same mistake as rounding by default,
/// arrived at from the other direction. A dialog gets its real corners; a sheet keeps a square
/// outline until the app itself rounds one.
///
/// Run on a simulator:
///   xcodebuild test -scheme LightSession -destination 'platform=iOS Simulator,name=iPhone 17' \
///     -only-testing:LightSessionTests/ModalCornerProbeTest
final class ModalCornerProbeTest: XCTestCase {

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// Every layer under `root`, with anything it declares about its corners.
    private func report(_ root: CALayer, depth: Int = 0, into lines: inout [String]) {
        let radius = root.cornerRadius
        let masked = root.maskedCorners.rawValue
        let name = String(describing: type(of: root))
        let delegate = root.delegate.map { String(describing: type(of: $0)) } ?? "—"
        lines.append(
            String(repeating: "  ", count: depth)
                + "\(name) delegate=\(delegate) r=\(radius) masked=\(masked) "
                + "bounds=\(Int(root.bounds.width))x\(Int(root.bounds.height))"
        )
        for sub in root.sublayers ?? [] {
            report(sub, depth: depth + 1, into: &lines)
        }
    }

    private func present(_ controller: UIViewController, from host: UIViewController) {
        host.present(controller, animated: false)
        spin(1.0)
    }

    private func makeWindow() -> (UIWindow, UIViewController) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        root.view.backgroundColor = .white
        window.rootViewController = root
        window.makeKeyAndVisible()
        return (window, root)
    }

    /// A UIKit alert — the platform's own dialog.
    func testWhereAnAlertDeclaresItsCorners() {
        let (window, root) = makeWindow()
        defer { window.isHidden = true }

        let alert = UIAlertController(title: "Title", message: "Message", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, from: root)

        var lines: [String] = []
        report(alert.view.layer, into: &lines)
        print("ALERT LAYERS:\n" + lines.joined(separator: "\n"))
        XCTAssertFalse(lines.isEmpty, "the probe found no layers at all; the presentation did not happen")
    }

    /// A sheet, which on this platform is rounded by the presentation controller rather than by
    /// anything the app itself set — the case most likely to report nothing readable.
    @available(iOS 15.0, *)
    func testWhereASheetDeclaresItsCorners() {
        let (window, root) = makeWindow()
        defer { window.isHidden = true }

        let sheet = UIViewController()
        sheet.view.backgroundColor = .systemBackground
        sheet.modalPresentationStyle = .pageSheet
        present(sheet, from: root)

        var lines: [String] = []
        report(sheet.view.layer, into: &lines)
        // The presentation container too: on this platform a sheet is rounded by the machinery
        // around the app's view, not by the app's view, and that difference is the whole question.
        if let container = sheet.presentationController?.containerView {
            lines.append("— container —")
            report(container.layer, into: &lines)
        }
        print("SHEET LAYERS:\n" + lines.joined(separator: "\n"))
        XCTAssertFalse(lines.isEmpty)
    }

    /// A view the app rounded itself — the case that must read, since it is the app's own
    /// declaration and the whole reason for measuring rather than assuming.
    func testAViewTheAppRoundedItselfReportsIt() {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 60))
        view.layer.cornerRadius = 12
        XCTAssertEqual(view.layer.cornerRadius, 12)
        XCTAssertEqual(
            view.layer.maskedCorners, .layerMinXMinYCorner.union(.layerMaxXMinYCorner)
                .union(.layerMinXMaxYCorner).union(.layerMaxXMaxYCorner),
            "all four by default, which is what an unqualified cornerRadius means"
        )
    }

    /// The mask constants, pinned. The reader maps them into visual order and a wrong constant
    /// would silently round the wrong two corners of every sheet.
    func testTheMaskedCornerConstantsAreWhatTheReaderAssumes() {
        XCTAssertEqual(CACornerMask.layerMinXMinYCorner.rawValue, 1, "top-left")
        XCTAssertEqual(CACornerMask.layerMaxXMinYCorner.rawValue, 2, "top-right")
        XCTAssertEqual(CACornerMask.layerMinXMaxYCorner.rawValue, 4, "bottom-left")
        XCTAssertEqual(CACornerMask.layerMaxXMaxYCorner.rawValue, 8, "bottom-right")
    }
}
#endif
