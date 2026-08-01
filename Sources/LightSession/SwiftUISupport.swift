#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// SwiftUI support, which is one modifier because one is all that is needed.
public extension View {

    /// Names this view as a screen.
    ///
    /// ```swift
    /// NavigationStack {
    ///     HomeView().lightSessionScreen("Home")
    /// }
    /// ```
    ///
    /// Reported on `onAppear`, not during `body`. A `body` runs whenever SwiftUI decides to re-evaluate
    /// it — off screen, speculatively, several times for one appearance — and reporting from there would
    /// name screens the user never reached. `onAppear` fires when the view is actually on screen, which
    /// is the question being asked.
    ///
    /// It fires before layout is finished, and that is handled rather than assumed: the capture waits
    /// for the hierarchy to stop changing before it reads anything.
    func lightSessionScreen(_ name: String) -> some View {
        onAppear { LightSession.setScreen(name) }
    }

    /// Names screens from the value the app routes on, for every case at once.
    ///
    /// ## When to reach for this
    ///
    /// Use it on a view that **switches between screens itself** — the classic shape being the root of
    /// a SwiftUI app:
    ///
    /// ```swift
    /// WindowGroup {
    ///     Group {
    ///         switch session.route {
    ///         case .loading: SplashView()
    ///         case .login:   LoginView()
    ///         case .rep:     RepRootView()
    ///         case .manager: ManagerRootView()
    ///         }
    ///     }
    ///     .lightSessionScreen(for: session.route)
    /// }
    /// ```
    ///
    /// Do **not** reach for it on a screen pushed by a `NavigationStack` or shown as a titled sheet.
    /// Those are named already, from their `navigationTitle`, with nothing asked of the app. This is
    /// for the one shape that cannot be observed at all — see the long note in `ScreenSource.swift`
    /// for the ten ways that were tried and where each one dies.
    ///
    /// ## What the name comes out as
    ///
    /// The enum case, with any payload dropped:
    ///
    /// ```swift
    /// .loading                      ->  "loading"
    /// .doctorDetail("dr-carlos")    ->  "doctorDetail"      // not one node per doctor
    /// ```
    ///
    /// Nothing is capitalised or reworded. An app that writes `.login` gets `login`, so the name in the
    /// dashboard is a string that can be searched for in the app's own source.
    ///
    /// ## Routes that are not screens
    ///
    /// Most apps have at least one route that selects a *shell* rather than a place — `.manager`
    /// choosing a `TabView` whose tabs are the real screens. Reported as a screen, a shell becomes a
    /// node with no capture, sitting between the login and the first tab in the same second. Use the
    /// overload below to return nil for those.
    ///
    /// ```swift
    /// Group {
    ///     switch session.route {
    ///     case .loading: SplashView()
    ///     case .login:   LoginView()
    ///     case .rep:     RepRootView()
    ///     case .manager: ManagerRootView()
    ///     }
    /// }
    /// .lightSessionScreen(for: session.route)
    /// ```
    ///
    /// One line for four screens, and a fifth case names itself the day it is added. There is no string
    /// literal to fall out of date, because the name *is* the case.
    ///
    /// ## Why this exists instead of reading the view
    ///
    /// A root that switches its content is the one shape nothing can observe. The screens share a
    /// hosting controller, share a view type, and the change emits no UIKit callback — `viewWillAppear`
    /// and `viewDidAppear` both stay silent, measured on the same object identity before and after. Ten
    /// ways of digging the answer out of SwiftUI's internals were tried and all of them end at
    /// AttributeGraph, where the live state is kept.
    ///
    /// The app has the answer in its own model, which is also the better answer: `.login` is what the
    /// team calls that screen, and it survives renaming the view that draws it.
    ///
    /// An enum's payload is dropped — `.doctorDetail(id)` maps to `doctorDetail` — so routing that
    /// carries a record does not grow a node per record.
    func lightSessionScreen<Route: Equatable>(for route: Route) -> some View {
        modifier(LightSessionRouteScreen(route: route, name: screenName(forRoute:)))
    }

    /// The same, for an app whose routes are not all screens.
    ///
    /// Returning nil says *this route is not a place*, and nothing is reported for it. That is the
    /// common shape and it is worth spelling out: a route like `.manager` usually selects a shell — a
    /// `TabView` holding four tabs — and the screen the user is looking at is the tab inside it, which
    /// names itself. Reported as a screen, the shell becomes a node with no capture, sitting between
    /// the login and the first tab, in the same session and the same second.
    ///
    /// It is the same rule the SDK applies to `UITabBarController` and `UINavigationController`: a
    /// container is not a place. Nothing outside the app can tell which of its routes are containers,
    /// so the app says.
    ///
    /// ```swift
    /// .lightSessionScreen(for: session.route) { route in
    ///     switch route {
    ///     case .loading:       "Splash"
    ///     case .login:         "Login"
    ///     case .rep, .manager: nil     // shells; the tabs inside name themselves
    ///     }
    /// }
    /// ```
    func lightSessionScreen<Route: Equatable>(
        for route: Route,
        name: @escaping (Route) -> String?
    ) -> some View {
        modifier(LightSessionRouteScreen(route: route, name: name))
    }

    /// Declares this view as a part of the current screen that is a place of its own — a sheet, a tab, a
    /// step. Cleared when it goes away.
    ///
    /// Paired on purpose. A sheet that names itself on appear and never clears leaves the screen wearing
    /// its name after it closes, and every later capture is filed under a modal that is not on screen.
    func lightSessionSubScreen(_ name: String) -> some View {
        onAppear { LightSession.setSubScreen(name) }
            .onDisappear { LightSession.clearSubScreen(name) }
    }
}

/// Reports the screen whenever the routing value changes, and once when it first appears.
///
/// The first report matters as much as the changes: `onChange` does not fire for the value a view opens
/// with, and the screen a session starts on is the one screen every user is guaranteed to have seen.
///
/// Two spellings of `onChange` because the one-argument form is deprecated from iOS 17 and the
/// two-argument form does not exist before it. Both are the same call; splitting them keeps the SDK from
/// emitting a deprecation warning into somebody else's build log.
private struct LightSessionRouteScreen<Route: Equatable>: ViewModifier {

    let route: Route
    let name: (Route) -> String?

    func body(content: Content) -> some View {
        if #available(iOS 17.0, tvOS 17.0, *) {
            content.onChange(of: route, initial: true) { _, now in report(now) }
        } else {
            content
                .onAppear { report(route) }
                .onChange(of: route) { now in report(now) }
        }
    }

    private func report(_ value: Route) {
        guard let screen = name(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !screen.isEmpty
        else { return }
        LightSession.setScreen(screen)
    }
}
#endif
