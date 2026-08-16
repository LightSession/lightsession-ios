#if canImport(UIKit)
import XCTest
@testable import LightSession

/// A screen that leaves before it settles still gets a wireframe.
///
/// The screen this is about is a splash: it shows a logo, answers one cheap question and replaces
/// itself, inside a few milliseconds. The settle detector wants three steady frames — by then the
/// screen is gone and the capture is dropped, correctly, because uploading it would file the *next*
/// screen's content under this name. So the node sat in the flow with nothing behind it, in two
/// apps, permanently.
///
/// It was invisible as well as wrong: starting a settle cancels the previous one, so the callback
/// that would have logged "left before it settled" never ran. Nothing in a log said a capture had
/// been lost.
///
/// Driven through the tracker rather than a pure function, because what broke is the *sequence* —
/// report, replace, and what is owed in between — and a pure function has no sequence to get wrong.
final class ShortScreenCaptureTests: XCTestCase {

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
        func removeAll(withPrefix prefix: String) {
            values = values.filter { !$0.key.hasPrefix(prefix) }
        }
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// A window with something drawable in it, so a wireframe has nodes to carry.
    private func makeWindow() -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        root.view.backgroundColor = .systemIndigo
        let label = UILabel(frame: CGRect(x: 40, y: 380, width: 300, height: 40))
        label.text = "Monest"
        root.view.addSubview(label)
        window.rootViewController = root
        window.makeKeyAndVisible()
        return window
    }

    private func makeTracker(_ sender: RecordingSender, window: UIWindow) -> ScreenTracker {
        let tracker = ScreenTracker(
            config: LightSessionConfig(
                apiKey: "test",
                apiURL: "http://localhost",
                screensReportedByHost: true,
                captureRealScreens: false,
                // A scene-less test window has no compositor to sample from, and colour is not what
                // this measures.
                sampleWireframeColours: false
            ),
            sender: sender,
            cache: CaptureCache(storage: MemoryStorage(), appVersion: "1.0"),
            appVersionName: "1.0",
            appVersionCode: 1
        )
        tracker.keyWindow = { window }
        return tracker
    }

    func testAScreenReplacedBeforeItSettlesIsStillSent() {
        let window = makeWindow()
        defer { window.isHidden = true }
        let sender = RecordingSender()
        let tracker = makeTracker(sender, window: window)

        // The splash, replaced immediately — the settle detector never gets its three steady frames.
        tracker.reported(screen: "Splash")
        tracker.reported(screen: "Login")

        XCTAssertTrue(
            spinUntil(4) { sender.screens.contains { $0.name == "Splash" } },
            "a screen that left before settling was never sent at all; the node had no picture"
        )
        let splash = sender.screens.first { $0.name == "Splash" }
        XCTAssertNotNil(splash?.skeleton)
        XCTAssertGreaterThan(
            splash?.skeleton?.nodes.count ?? 0, 0,
            "an empty wireframe is the thing being fixed, not the fix"
        )
    }

    /// The other half: a screen that *does* settle must send the settled wireframe, not the thinner
    /// copy taken when it was named — `onAppear` fires before layout, so that copy is poorer by
    /// construction.
    func testAScreenThatSettlesSendsOneWireframe() {
        let window = makeWindow()
        defer { window.isHidden = true }
        let sender = RecordingSender()
        let tracker = makeTracker(sender, window: window)

        tracker.reported(screen: "Home")
        XCTAssertTrue(spinUntil(4) { !sender.screens.isEmpty })
        spin(0.5)

        XCTAssertEqual(
            sender.screens.filter { $0.name == "Home" }.count, 1,
            "the held copy is superseded by the settled one, not sent beside it"
        )
    }

    /// And the held copy must not overwrite a richer wireframe the screen already has: a splash
    /// captured properly on a slower launch stays, rather than being replaced by the three nodes a
    /// faster one managed.
    func testTheHeldCopyDoesNotOverwriteARicherOne() {
        let window = makeWindow()
        defer { window.isHidden = true }
        let sender = RecordingSender()
        let storage = MemoryStorage()
        let tracker = ScreenTracker(
            config: LightSessionConfig(
                apiKey: "test", apiURL: "http://localhost",
                screensReportedByHost: true, captureRealScreens: false,
                sampleWireframeColours: false
            ),
            sender: sender,
            cache: CaptureCache(storage: storage, appVersion: "1.0"),
            appVersionName: "1.0",
            appVersionCode: 1
        )
        tracker.keyWindow = { window }

        // A visit that settled and stored a rich wireframe.
        tracker.reported(screen: "Splash")
        XCTAssertTrue(spinUntil(4) { !sender.screens.isEmpty })
        spin(0.5)
        let rich = sender.screens.count

        // A later launch where it leaves at once. Nothing more should go out.
        tracker.reported(screen: "Login")
        tracker.reported(screen: "Splash")
        tracker.reported(screen: "Login")
        spin(1.0)

        XCTAssertEqual(
            sender.screens.filter { $0.name == "Splash" }.count, rich,
            "the bar protects a stored wireframe from being replaced by a poorer one"
        )
    }

    // MARK: - Whose content the held copy is

    /// The held copy is read from the arriving screen's own view, never from the window.
    ///
    /// This is the half that was wrong first. Reading the window one turn after `onAppear` looked
    /// right and measured right — the node count went from 3 to 36 — and the 36 were the *previous*
    /// screen: a splash pushed onto the hub was read mid-animation, while the hub was still in the
    /// window, and its rectangles were filed under the splash's name. A richer wrong answer scores
    /// better than a poor right one on every check except this one.
    ///
    /// The window is still correct for a settled capture, and `UIWindow.lightSessionContent` says
    /// why: a sheet over a screen belongs to what is on the glass. The difference is that a settled
    /// capture is taken when nothing is moving.
    func testTheHeldCopyIsReadFromTheScreenNotTheWindow() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        defer { window.isHidden = true }
        let pushed = UIViewController()
        let navigation = UINavigationController(rootViewController: UIViewController())
        navigation.pushViewController(pushed, animated: false)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        // The screen being captured is by definition on the glass, so its view is loaded and
        // attached. A window that has never laid out is not that state.
        window.layoutIfNeeded()

        let tracker = makeTracker(RecordingSender(), window: window)
        XCTAssertTrue(
            tracker.arrivalRoot(in: window) === pushed.view,
            "the arriving screen is the pushed one; the stack under it is a different screen"
        )
    }

    /// Reading the screen's own view decides *what* is drawn, never *how big the screen is*.
    ///
    /// Caught in the sample rather than reasoned about, and it was the same mistake wearing a
    /// different hat: scoping the read to the top controller's view also scoped the reported size to
    /// it, so the hub's held copy went up as 516×960. A capture is keyed by its size, so the server
    /// did not overwrite the hub — it stored a second one, and the screen gained a variant at a
    /// resolution no device has.
    func testTheHeldCopyIsAlwaysTheSizeOfTheWindow() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        defer { window.isHidden = true }
        let sender = RecordingSender()
        let inner = UIViewController()
        let label = UILabel(frame: CGRect(x: 10, y: 10, width: 100, height: 20))
        label.text = "Monest"
        inner.view.addSubview(label)
        let navigation = UINavigationController(rootViewController: UIViewController())
        navigation.pushViewController(inner, animated: false)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        // Mid-transition, in the one form that survives a layout pass. Setting a frame does not:
        // the navigation controller lays its child back out to fill, and the test then measures
        // nothing. UIKit animates a push by transforming the incoming view, so this is also the
        // shape the real 516×960 came in.
        inner.view.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)

        let tracker = makeTracker(sender, window: window)
        tracker.reported(screen: "Splash")
        tracker.reported(screen: "Login")
        XCTAssertTrue(spinUntil(4) { sender.screens.contains { $0.name == "Splash" } })

        let splash = sender.screens.first { $0.name == "Splash" }
        let scale = Int(window.screen.scale)
        XCTAssertEqual(splash?.width, 390 * scale, "a screen is the width of the window it fills")
        XCTAssertEqual(splash?.height, 844 * scale, "a screen is the height of the window it fills")
    }

    func testTheSelectedTabIsTheScreen() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        defer { window.isHidden = true }
        let first = UIViewController(), second = UIViewController()
        let tabs = UITabBarController()
        tabs.viewControllers = [first, second]
        tabs.selectedIndex = 1
        window.rootViewController = tabs
        window.makeKeyAndVisible()

        let tracker = makeTracker(RecordingSender(), window: window)
        XCTAssertTrue(tracker.arrivalRoot(in: window) === second.view)
    }

    func testAPlainRootIsItsOwnScreen() {
        let window = makeWindow()
        defer { window.isHidden = true }
        let tracker = makeTracker(RecordingSender(), window: window)
        XCTAssertTrue(tracker.arrivalRoot(in: window) === window.rootViewController?.view)
    }

    /// No root at all — between a scene connecting and its window being populated. The window is the
    /// only thing left to read, and reading it is better than holding nothing.
    func testAWindowWithNoRootFallsBackToItself() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        defer { window.isHidden = true }
        let tracker = makeTracker(RecordingSender(), window: window)
        XCTAssertTrue(tracker.arrivalRoot(in: window) === window)
    }

    private func spinUntil(_ seconds: TimeInterval, _ done: () -> Bool) -> Bool {
        let end = Date(timeIntervalSinceNow: seconds)
        while Date() < end {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            if done() { return true }
        }
        return done()
    }
}
#endif
