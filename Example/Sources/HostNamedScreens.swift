import LightSession
import SwiftUI

/// The shape a real SwiftUI app has: tabs, a `NavigationStack` in each, every screen named by the app.
///
/// This exists to answer a question the SDK cannot answer by reading its own code. `.lightSessionScreen`
/// reports on `onAppear`, and nothing else ever un-reports it — so the map is only correct if SwiftUI runs
/// `onAppear` **again** when the user comes back to a screen. Push a detail and pop it: if the root does
/// not re-appear, the app is still called `Detail` while the user looks at the list, and every capture and
/// every tap from then on is filed under a screen that is not on the glass. Same for switching tabs away
/// and back.
///
/// Driven by bindings on a timer rather than by taps, because the iOS simulator cannot be told to tap and
/// a driver that taps coordinates stops testing anything the day the layout moves. The script is a list of
/// steps so what is being exercised can be read in one place.
///
/// None of this is in the SDK. It is the sample proving a claim about the platform.
///
/// `NavigationStack` is iOS 16, and the sample supports 15. Gated rather than rewritten against
/// `NavigationView`, because `NavigationView` is not the thing whose behaviour is in question.
@available(iOS 16.0, *)
struct HostNamedScreens: View {

    @State private var tab = 0
    @State private var path = NavigationPath()

    /// What the walk does, and what the log should say after each step.
    ///
    /// The two `pop` and `tab back` steps are the whole point: they are the ones that fail silently if
    /// SwiftUI does not re-run `onAppear`.
    private var script: [(after: Double, what: String, run: () -> Void)] {
        [
            (3, #"push -> expect "Detail""#, { path.append("detail") }),
            (6, #"pop -> expect "Home" again"#, { if !path.isEmpty { path.removeLast() } }),
            (9, #"tab 2 -> expect "Second""#, { tab = 1 }),
            (12, #"tab 1 -> expect "Home" again"#, { tab = 0 }),
            (15, #"push from tab 1 -> expect "Detail""#, { path.append("detail") }),
        ]
    }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack(path: $path) {
                VStack(spacing: 8) {
                    Text("Home").font(.title2)
                    Text("Named by the app, not by the platform.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .navigationDestination(for: String.self) { _ in
                    VStack(spacing: 8) {
                        Text("Detail").font(.title2)
                        Text("Popping this must give the name back to Home.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .lightSessionScreen("Detail")
                }
                .lightSessionScreen("Home")
            }
            .tabItem { Label("Home", systemImage: "house") }
            .tag(0)

            NavigationStack {
                Text("Second").font(.title2).lightSessionScreen("Second")
            }
            .tabItem { Label("Second", systemImage: "square.grid.2x2") }
            .tag(1)
        }
        .onAppear(perform: walkIfAsked)
    }

    private func walkIfAsked() {
        guard UserDefaults.standard.bool(forKey: "demoNav") else { return }
        for step in script {
            DispatchQueue.main.asyncAfter(deadline: .now() + step.after) {
                print("[demo] \(step.what)")
                step.run()
            }
        }
    }
}
