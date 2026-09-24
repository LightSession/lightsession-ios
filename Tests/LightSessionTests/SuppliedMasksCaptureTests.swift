#if canImport(UIKit)
import XCTest
@testable import LightSession

/// That a capture covers what an embedder reported, and takes no picture when the report says it
/// could not measure.
///
/// A scene-less test window has no compositor, so `drawHierarchy` may draw nothing here; the mask is
/// painted by the SDK itself on top of whatever was drawn, which is exactly the part under test.
final class SuppliedMasksCaptureTests: XCTestCase {

    override func tearDown() {
        // Process-wide state: a report left here would reach every later capture in the run.
        SuppliedMasks.clear()
        super.tearDown()
    }

    private func makeWindow() -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        // One view with nothing in it for the walk, which is what a Flutter screen is to it.
        root.view.backgroundColor = .white
        window.rootViewController = root
        window.makeKeyAndVisible()
        return window
    }

    private func capture(_ window: UIWindow) -> ScreenshotRenderer.Captured? {
        ScreenshotRenderer.capture(
            window: window,
            snapshot: window.lightSessionContent,
            policy: .default,
            scale: 1
        )
    }

    /// The pixel at (x, y), as 0…255 components.
    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }

    private func isMaskGrey(_ p: (r: Int, g: Int, b: Int)) -> Bool {
        let grey = Recolour.maskFillLight
        return abs(p.r - Int(grey.red)) <= 2 && abs(p.g - Int(grey.green)) <= 2
            && abs(p.b - Int(grey.blue)) <= 2
    }

    func testTheEmbeddersRectanglesAreCovered() throws {
        let window = makeWindow()
        // Long enough ago that the frame is on screen: the plan covers it at once.
        SuppliedMasks.set(
            generation: 1,
            rects: [Rect(left: 100, top: 200, right: 300, bottom: 260)],
            nowMillis: 0
        )

        let captured = try XCTUnwrap(capture(window))
        XCTAssertNotNil(captured.supplied, "a capture an embedder covered carries its plan, to be checked after")
        XCTAssertTrue(isMaskGrey(pixel(captured.image, x: 200, y: 230)), "inside the reported rectangle")
        XCTAssertFalse(isMaskGrey(pixel(captured.image, x: 50, y: 50)), "outside it")
    }

    func testAReportThatCouldNotMeasureTakesNoPicture() {
        let window = makeWindow()
        SuppliedMasks.set(generation: 1, rects: nil, nowMillis: 0)
        XCTAssertNil(capture(window), "a screen whose masks are unknown is not photographed")
    }

    func testMasksStillMovingTakeNoPicture() {
        let window = makeWindow()
        let now = SuppliedMasks.nowMillis()
        SuppliedMasks.set(generation: 1, rects: [Rect(left: 0, top: 0, right: 10, bottom: 10)], nowMillis: now)
        SuppliedMasks.set(generation: 2, rects: [Rect(left: 0, top: 40, right: 10, bottom: 50)], nowMillis: now)
        XCTAssertNil(capture(window), "frame 1's pixels may be what the screen shows, with its text elsewhere")
    }

    func testWithoutAnEmbedderACaptureIsAsItWas() throws {
        let window = makeWindow()
        let captured = try XCTUnwrap(capture(window))
        XCTAssertNil(captured.supplied, "nothing to check afterwards, so nothing is delayed")
    }
}
#endif
