#if canImport(UIKit)
import XCTest
@testable import LightSession

/// The whole late-content path, composed: a real window shows a shell around a spinner, the
/// wireframe goes out thin, the data "lands" as views joining the hierarchy, and a richer wireframe
/// follows into the same capture slot — with nobody touching the network.
///
/// This is the iOS counterpart of Android's `LateContentTest`, which stages the same flip in
/// miniature (14 rects before, 50 after). The unit tests beside this one cover each part — the
/// cache's ratchet, the geometry compare, the watch's latch — and none of them would catch the
/// parts being wired together wrong, which is precisely what happened to be untested the first
/// time someone asked "did you actually see it work".
///
/// UIKit-gated: run on a simulator.
final class LateContentIntegrationTests: XCTestCase {

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

    /// Spins the main run loop until [done] or the deadline — the settle's display link, the
    /// watch's timer and the sender callbacks all live there.
    private func spin(upTo seconds: TimeInterval, until done: () -> Bool) -> Bool {
        let end = Date(timeIntervalSinceNow: seconds)
        while Date() < end {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            if done() { return true }
        }
        return done()
    }

    func testASpinnerScreenIsResentRicherWhenItsContentArrives() {
        // A scene-less window: the package test host connects no UIWindowScene, which is exactly
        // why the tracker grew its `keyWindow` seam — the window under test is handed in below.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        let root = UIViewController()
        root.view.backgroundColor = .white
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        // Arrival state: the shell around a "spinner" — one small drawing view, which is all a
        // loading screen is to the builder.
        let spinner = UIView(frame: CGRect(x: 150, y: 310, width: 24, height: 24))
        spinner.backgroundColor = .systemGray
        root.view.addSubview(spinner)

        let sender = RecordingSender()
        let tracker = ScreenTracker(
            config: LightSessionConfig(
                apiKey: "test",
                apiURL: "http://localhost",
                screensReportedByHost: true,
                // Keeps the screenshot machinery out of a test about wireframes; it has its own.
                captureRealScreens: false,
                // Palette colours: sampling draws the window, and a scene-less test window has no
                // compositor behind it to draw from. Colour is not what this test measures.
                sampleWireframeColours: false
            ),
            sender: sender,
            cache: CaptureCache(storage: MemoryStorage(), appVersion: "1.0"),
            appVersionName: "1.0",
            appVersionCode: 1
        )
        tracker.keyWindow = { window }

        tracker.reported(screen: "metrics")

        XCTAssertTrue(
            spin(upTo: 4, until: { !sender.screens.isEmpty }),
            "the arrival wireframe never went out"
        )
        let first = sender.screens[0]

        // The data lands. To the builder, content arriving *is* views joining the hierarchy —
        // this is the moment the watch exists to notice.
        for i in 0..<12 {
            let label = UILabel(frame: CGRect(x: 16, y: CGFloat(60 + i * 44), width: 288, height: 32))
            label.text = "row \(i)"
            root.view.addSubview(label)
        }

        XCTAssertTrue(
            spin(upTo: 6, until: { sender.screens.count >= 2 }),
            "content arrived and no richer wireframe followed; the watch never fired"
        )
        let second = sender.screens[1]

        XCTAssertEqual(
            first.compositeId, second.compositeId,
            "the resend replaces the wireframe in its slot; a new id would mint a second capture"
        )
        let before = first.skeleton?.nodes.count ?? 0
        let after = second.skeleton?.nodes.count ?? 0
        XCTAssertGreaterThan(
            after, before,
            "the loaded screen must carry more than the spinner it replaced (got \(before) -> \(after))"
        )
    }
}
#endif
