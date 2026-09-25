#if canImport(UIKit)
import MapKit
import WebKit
import XCTest
@testable import LightSession

/// That the views whose content the walk cannot read are recognised on a real UIKit hierarchy — a web
/// page and a map — and covered whole in a capture.
final class UnreadableContentTests: XCTestCase {

    private final class AppMap: MKMapView {}

    private func window(with content: UIView) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        root.view.backgroundColor = .white
        content.frame = CGRect(x: 0, y: 100, width: 390, height: 500)
        root.view.addSubview(content)
        window.rootViewController = root
        window.makeKeyAndVisible()
        return window
    }

    private func node(of view: UIView, in window: UIWindow) -> ViewSnapshot? {
        func find(_ node: ViewSnapshot) -> ViewSnapshot? {
            if node.unreadable { return node }
            return node.children.lazy.compactMap(find).first
        }
        return find(window.lightSessionContent)
    }

    func testAWebViewIsUnreadableAndCovered() throws {
        let window = window(with: WKWebView())
        let web = try XCTUnwrap(node(of: window, in: window), "a web view the walk could not see into")
        XCTAssertEqual(web.kind, .webView, "the wireframe still draws it as the web view it is")
        XCTAssertTrue(
            MaskGeometry.rects(in: window.lightSessionContent, policy: .default, bounds: web.frame)
                .contains(web.frame)
        )
    }

    func testAMapAndAnAppsOwnSubclassOfOneAreUnreadable() throws {
        for map in [MKMapView(), AppMap()] {
            let window = window(with: map)
            XCTAssertNotNil(node(of: window, in: window), "\(type(of: map)) is a map")
        }
    }

    func testAnOrdinaryViewIsReadable() {
        let window = window(with: UIView())
        XCTAssertNil(node(of: window, in: window))
    }
}
#endif
