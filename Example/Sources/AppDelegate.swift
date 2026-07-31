import UIKit
import LightSession

/// The whole integration for a UIKit app: one call, and no screen in this file knows the SDK exists.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var navigation: UINavigationController?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        LightSession.start(
            .init(
                // 127.0.0.1 works from the iOS simulator: it shares the host's network stack, unlike the
                // Android emulator, which needs 10.0.2.2.
                apiKey: "dev-key",
                apiURL: "http://127.0.0.1:3002",
                // A different service from the API: interaction batches go to the ingest, and pointing one
                // at the other 404s everything it carries.
                ingestURL: "http://127.0.0.1:5055",
                // 300 ms instead of the default second: a smoother replay, and the frame budget it costs
                // is the point of measuring it rather than guessing.
                captureIntervalMillis: 300
            ),
            verbose: true
        )

        let navigation = UINavigationController(rootViewController: HubViewController())
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        self.window = window
        self.navigation = navigation

        walkRoutesIfAsked()
        return true
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
                } else if let destination = HubViewController.route(named: slug) {
                    navigation.pushViewController(destination, animated: true)
                } else {
                    print("[demo] no route named \(slug)")
                }
            }
            delay += step
        }
    }
}
