#if canImport(UIKit)
import XCTest
@testable import LightSession

/// A part of a screen is part of that screen, and is reported as the kind of screen it is part of.
///
/// A Flutter app names its screens and declares their parts, and every part — a tab, a sheet — was
/// reported as UIKit, so its graph held UIKit screens it never had.
final class SubScreenKindTests: XCTestCase {

    private final class NullSender: DataSender {
        func send(screen: ScreenReport, completion: @escaping (Result<Void, Error>) -> Void) {
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

    private func tracker(kind: ScreenIdentity.Kind) -> ScreenTracker {
        ScreenTracker(
            config: LightSessionConfig(
                apiKey: "test",
                apiURL: "http://localhost",
                screensReportedByHost: true,
                reportedScreenKind: kind,
                captureRealScreens: false,
                sampleWireframeColours: false
            ),
            sender: NullSender(),
            cache: CaptureCache(storage: MemoryStorage(), appVersion: "1.0"),
            appVersionName: "1.0",
            appVersionCode: 1
        )
    }

    func testADeclaredPartOfAFlutterScreenIsAFlutterScreen() {
        let tracker = tracker(kind: .flutter)
        var reported: [(String, ScreenIdentity.Kind)] = []
        tracker.onScreenChange = { _, to, kind, _ in reported.append((to, kind)) }

        tracker.reported(screen: "/tabs")
        tracker.setSubScreen("Inbox")
        tracker.clearSubScreen("Inbox")

        XCTAssertEqual(reported.map(\.0), ["/tabs", "/tabs › Inbox", "/tabs"])
        XCTAssertEqual(reported.map(\.1), [.flutter, .flutter, .flutter])
    }

    func testAPartOfAReactNativeScreenIsAReactNativeScreen() {
        let tracker = tracker(kind: .reactNative)
        var kinds: [ScreenIdentity.Kind] = []
        tracker.onScreenChange = { _, _, kind, _ in kinds.append(kind) }
        tracker.reported(screen: "Home")
        tracker.setSubScreen("Filters")
        XCTAssertEqual(kinds, [.reactNative, .reactNative])
    }
}
#endif
