import UIKit
import LightSession

/// The whole integration for a UIKit app: one call, and no screen in this file knows the SDK exists.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        LightSession.start(
            .init(
                // 127.0.0.1 works from the iOS simulator: it shares the host's network stack, unlike the
                // Android emulator, which needs 10.0.2.2. A real device needs this machine's LAN address.
                apiKey: UserDefaults.standard.string(forKey: "demoApiKey") ?? "dev-key",
                apiURL: "http://127.0.0.1:3002",
                // A different service from the API: interaction batches go to the ingest, and pointing one
                // at the other 404s everything it carries.
                ingestURL: "http://127.0.0.1:5055",
                // Off by default because this sample is mostly UIKit and UIKit names its own screens.
                // `-demoHostNamesScreens 1` turns it on, which is what a SwiftUI app ships and therefore
                // what has to be exercised: with it on the swizzle is not installed at all, and every
                // name in the map has to have come from `.lightSessionScreen`.
                screensReportedByHost: UserDefaults.standard.bool(forKey: "demoHostNamesScreens"),
                // 300 ms instead of the default second: a smoother replay, and the frame budget it costs
                // is the point of measuring it rather than guessing.
                captureIntervalMillis: 300
            ),
            verbose: true
        )

        return true
    }
}

/// The window, which on iPadOS has to come from a scene.
///
/// This used to be three lines in `didFinishLaunching` around `UIScreen.main.bounds`, which is fine on a
/// phone and is why nobody noticed. An app with no `UIApplicationSceneManifest` does not get a native
/// window on an iPad: iPadOS runs it in the legacy 320×480 compatibility box, floating in the middle of
/// the display with window chrome around it. It looks like a blank iPad with a sliver of app on it, and
/// the SDK reported the screen as 640×960 because that genuinely was the window.
///
/// Adopting scenes is also what lets the sample be a size other than a phone, which is the point of
/// running it on an iPad at all.
/// Named for Objective-C so the plist can name it back.
///
/// A scene delegate is found by string, and Xcode writes `$(PRODUCT_MODULE_NAME).SceneDelegate` because it
/// substitutes that at build time. This sample is built by `swiftc` with no such substitution, so the plist
/// would carry the literal text and UIKit would find nothing. `@objc` gives the class a name with no module
/// in front of it, which is a name a plist can state without knowing how the app was built.
@objc(SceneDelegate)
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var navigation: UINavigationController?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)

        // `-demoRootRoute splash` puts a route on the glass as the app's own first screen, with no
        // hub under it and no push.
        //
        // Not a convenience. A splash is the shape it is *because* it is the root: it is the first
        // thing drawn, nothing precedes it, and it replaces itself in place. Reached the ordinary
        // way — pushed from the hub — a splash is measured through a push animation with the hub
        // still on screen behind it, which is a different screen, a different timing and the wrong
        // question. Both were measured here and they do not agree.
        if let slug = UserDefaults.standard.string(forKey: "demoRootRoute"),
           let route = HubViewController.route(named: slug) {
            window.rootViewController = route.make()
            window.makeKeyAndVisible()
            self.window = window
            return
        }

        let navigation = UINavigationController(rootViewController: HubViewController())
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        self.window = window
        self.navigation = navigation

        walkRoutesIfAsked()
    }

    /// Walks a list of screens on its own, when launched with `-demoRoutes pushed,form,list`.
    ///
    /// Here so the sample can be driven from a script rather than by clicking at coordinates: the iOS
    /// simulator has no equivalent of `uiautomator`, and a driver that taps where a button *was* silently
    /// stops testing anything the day the layout changes.
    ///
    /// A URL scheme was the first attempt and does not work for this. iOS asks the user to confirm before
    /// handing a URL to an app — the sample sat behind an "Open with…" alert while the script reported
    /// every step as sent — so the trigger has to be something the app reads itself.
    ///
    /// It is test scaffolding, and it lives in the sample: nothing in the SDK knows it exists.
    private func walkRoutesIfAsked() {
        guard let list = UserDefaults.standard.string(forKey: "demoRoutes") else { return }
        let slugs = list.split(separator: ",").map(String.init)
        // Long enough for a screen to lay out, settle and upload before the next one replaces it. The SDK
        // drops a capture whose screen has already been left, which is correct and would make a faster
        // walk measure nothing.
        let step = UserDefaults.standard.double(forKey: "demoInterval") > 0
            ? UserDefaults.standard.double(forKey: "demoInterval")
            : 4.0

        var delay = step
        for slug in slugs {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let navigation = self?.navigation else { return }
                if slug == "back" {
                    navigation.popViewController(animated: true)
                } else if let route = HubViewController.route(named: slug),
                          let hub = navigation.viewControllers.first as? HubViewController {
                    // Through the hub, so a route that must be presented rather than pushed is shown
                    // the same way from a script as from a tap.
                    navigation.popToRootViewController(animated: false)
                    hub.presentedViewController?.dismiss(animated: false)
                    hub.show(route)
                } else {
                    print("[demo] no route named \(slug)")
                }
            }
            delay += step
        }
    }
}
