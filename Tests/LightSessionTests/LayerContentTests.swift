import QuartzCore
import XCTest
@testable import LightSession

/// A layer whose name ends the way SwiftUI's text layer's does. The suffix is the point: the real
/// class arrives mangled with a module prefix, so the check has to survive one.
private final class TestCGDrawingLayer: CALayer {}

final class LayerContentTests: XCTestCase {

    /// The iOS 27 beta's text layer draws from a display callback without setting `contents`, so the
    /// structural "it draws" check cannot see it. If this stops passing, SwiftUI text is not in the
    /// wireframe on that OS — and not under the mask either, which is the half that matters.
    func testSwiftUIsTextLayerIsTextEvenWithoutContents() {
        let layer = TestCGDrawingLayer()
        XCTAssertNil(layer.contents, "the premise: no contents at all")
        XCTAssertEqual(LayerContent.kind(of: layer), .text)
    }

    /// A plain layer with nothing set still draws nothing. The name check must not loosen that.
    func testAPlainEmptyLayerStillDrawsNothing() {
        XCTAssertNil(LayerContent.kind(of: CALayer()))
    }
}
