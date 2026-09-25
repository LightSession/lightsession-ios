#if canImport(UIKit)
import XCTest
@testable import LightSession

/// A screen an embedder described is drawn from the description, under the view it describes, and
/// only in the wireframe.
///
/// The host here is a plain view with nothing in it, which is all a `FlutterView` is to the walk.
/// UIKit-gated: run on a simulator.
final class DescribedScreenTests: XCTestCase {

    override func tearDown() {
        // Process-wide state: a description left here would reach every later wireframe.
        SuppliedScreen.clear()
        super.tearDown()
    }

    private func makeWindow() -> (UIWindow, host: UIView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        root.view.backgroundColor = .white
        window.rootViewController = root
        window.makeKeyAndVisible()
        let host = UIView(frame: root.view.bounds)
        root.view.addSubview(host)
        return (window, host)
    }

    private func text(_ top: Double) -> ViewSnapshot {
        ViewSnapshot(frame: Rect(left: 16, top: top, right: 200, bottom: top + 24), kind: .text)
    }

    private func screen(_ children: [ViewSnapshot]) -> ViewSnapshot {
        ViewSnapshot(frame: Rect(left: 0, top: 0, right: 390, bottom: 844), kind: .container, children: children)
    }

    private func wireframe(_ window: UIWindow, for name: String) -> SkeletonFrame {
        SkeletonBuilder.build(root: window.lightSessionWireframeContent(for: name), scale: 1, background: nil)!
    }

    private func texts(_ frame: SkeletonFrame?) -> [Int] {
        (frame?.nodes ?? []).filter { $0.kind == .text }.map(\.top)
    }

    func testTheDescriptionIsDrawnWhereTheWalkFoundNothing() {
        let (window, host) = makeWindow()
        defer { window.isHidden = true }
        XCTAssertEqual(texts(wireframe(window, for: "home")), [], "one empty view, as a Flutter screen is")

        SuppliedScreen.set(root: screen([text(100), text(200)]), host: host, screenName: "home")
        XCTAssertEqual(texts(wireframe(window, for: "home")), [100, 200])
    }

    func testADescriptionOfAnotherScreenIsNotDrawn() {
        let (window, host) = makeWindow()
        defer { window.isHidden = true }
        SuppliedScreen.set(root: screen([text(100)]), host: host, screenName: "gallery")
        XCTAssertEqual(
            texts(wireframe(window, for: "home")), [],
            "the screen just left, filed under the one arrived at"
        )
    }

    /// A native view inside the host is drawn over the toolkit's content, and hides what it covers.
    func testWhatTheHostHoldsIsPaintedOverTheDescription() {
        let (window, host) = makeWindow()
        defer { window.isHidden = true }
        let native = UIView(frame: CGRect(x: 0, y: 380, width: 390, height: 80))
        native.backgroundColor = .red
        host.addSubview(native)

        SuppliedScreen.set(root: screen([text(100), text(400)]), host: host, screenName: "home")
        let frame = wireframe(window, for: "home")
        XCTAssertEqual(texts(frame), [100], "the text under the opaque native view is not on the glass")
        let order = frame.nodes.map { $0.kind == .text ? "text" : "\($0.top)" }
        XCTAssertEqual(order.last, "380", "the native view paints last, over the description")
    }

    /// The description is a second old at best, and a mask a frame old sits beside the text.
    func testMaskingReadsTheWalkAsItWas() {
        let (window, host) = makeWindow()
        defer { window.isHidden = true }
        let before = window.lightSessionContent
        SuppliedScreen.set(root: screen([text(100)]), host: host, screenName: nil)
        XCTAssertEqual(window.lightSessionContent, before)
        XCTAssertEqual(texts(wireframe(window, for: "home")), [100])
    }

    // MARK: - Composed, through the tracker

    private final class RecordingSender: DataSender {
        var screens: [ScreenReport] = []
        func send(screen: ScreenReport, completion: @escaping (Result<Void, Error>) -> Void) {
            screens.append(screen)
            completion(.success(()))
        }
        func replaceScreenshot(screen: ScreenReport, completion: @escaping (Result<Void, Error>) -> Void) {
            completion(.success(()))
        }
        func send(flow: FlowReport, completion: @escaping (Result<Void, Error>) -> Void) {
            completion(.success(()))
        }
    }

    private final class MemoryStorage: CaptureCacheStorage {
        var values: [String: String] = [:]
        func string(forKey key: String) -> String? { values[key] }
        func set(_ value: String?, forKey key: String) { values[key] = value }
        func removeAll(withPrefix prefix: String) { values = values.filter { !$0.key.hasPrefix(prefix) } }
    }

    private func spin(upTo seconds: TimeInterval, until done: () -> Bool) -> Bool {
        let end = Date(timeIntervalSinceNow: seconds)
        while Date() < end {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            if done() { return true }
        }
        return done()
    }

    /// Every step a Flutter screen's wireframe goes through: out as the empty walk, upgraded when the
    /// description lands, replaced by a newer and *smaller* one, silent on a revisit that changed
    /// nothing, and resent on a revisit whose description did change.
    func testADescribedScreenFollowsItsDescription() {
        let (window, host) = makeWindow()
        defer { window.isHidden = true }
        let sender = RecordingSender()
        let tracker = ScreenTracker(
            config: LightSessionConfig(
                apiKey: "test",
                apiURL: "http://localhost",
                screensReportedByHost: true,
                reportedScreenKind: .flutter,
                captureRealScreens: false,
                sampleWireframeColours: false
            ),
            sender: sender,
            cache: CaptureCache(storage: MemoryStorage(), appVersion: "1.0"),
            appVersionName: "1.0",
            appVersionCode: 1
        )
        tracker.keyWindow = { window }
        let home: () -> [ScreenReport] = { sender.screens.filter { $0.name == "home" } }
        let rows: (Int) -> [ViewSnapshot] = { count in (0..<count).map { self.text(Double(100 + $0 * 40)) } }

        tracker.reported(screen: "home")
        guard spin(upTo: 4, until: { home().count == 1 }) else { return XCTFail("the first wireframe never went out") }
        XCTAssertEqual(texts(home()[0].skeleton), [], "sent before the description, from the walk")

        SuppliedScreen.set(root: screen(rows(6)), host: host, screenName: "home")
        guard spin(upTo: 6, until: { home().count == 2 }) else {
            return XCTFail("the description never reached the wireframe")
        }
        XCTAssertEqual(texts(home()[1].skeleton).count, 6)

        SuppliedScreen.set(root: screen(rows(2)), host: host, screenName: "home")
        guard spin(upTo: 6, until: { home().count == 3 }) else {
            return XCTFail("a newer, simpler description was refused")
        }
        XCTAssertEqual(texts(home()[2].skeleton).count, 2)

        tracker.reported(screen: "other")
        XCTAssertTrue(spin(upTo: 4, until: { sender.screens.contains { $0.name == "other" } }))
        XCTAssertEqual(
            texts(sender.screens.last { $0.name == "other" }?.skeleton), [],
            "a description of home is not other's"
        )
        tracker.reported(screen: "home")
        XCTAssertFalse(
            spin(upTo: 2.5, until: { home().count > 3 }),
            "a revisit that changed nothing sent the same wireframe again"
        )

        tracker.reported(screen: "other")
        SuppliedScreen.set(root: screen(rows(3)), host: host, screenName: "home")
        tracker.reported(screen: "home")
        guard spin(upTo: 4, until: { home().count == 4 }) else {
            return XCTFail("a revisit with a new description under the bar was refused, as a walk's would be")
        }
        XCTAssertEqual(texts(home()[3].skeleton).count, 3)
        XCTAssertEqual(Set(home().map(\.compositeId)).count, 1, "every send replaces the one slot")
    }
}
#endif
