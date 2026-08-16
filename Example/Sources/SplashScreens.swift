import LightSession
import SwiftUI

/// A splash that decides where to go and leaves — the shortest screen an app has.
///
/// The shape of every launch screen worth the name: it shows a logo, answers one cheap question —
/// is there a valid token — and replaces itself. Reported from two real apps as a node that exists
/// in the flow with no picture behind it, ever.
///
/// The dwell is settable because the failure is about time. A screen that leaves before the settle
/// detector has seen three steady frames is a screen the capture arrives too late for, and the
/// question this answers is where that boundary is rather than whether it exists.
@available(iOS 16.0, *)
struct SplashScreens: View {

    @State private var showLogin = false

    /// Milliseconds the splash stays up. Default is what a token check costs: almost nothing.
    private var dwell: Double {
        let ms = UserDefaults.standard.double(forKey: "demoSplashMs")
        return ms > 0 ? ms : 30
    }

    var body: some View {
        Group {
            if showLogin {
                VStack(spacing: 8) {
                    Text("Login").font(.title2)
                    Text("Where the splash sent us.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .lightSessionScreen("Login")
            } else {
                ZStack {
                    Color.indigo.ignoresSafeArea()
                    VStack(spacing: 12) {
                        Text("Monest").font(.system(size: 32, weight: .bold))
                        Text("A brand splash with content worth a wireframe.")
                            .font(.footnote)
                    }
                    .foregroundStyle(.white)
                }
                .lightSessionScreen("Splash")
            }
        }
        .onAppear {
            guard UserDefaults.standard.bool(forKey: "demoNav"), !showLogin else { return }
            print("[demo] splash up; leaving in \(Int(dwell))ms")
            DispatchQueue.main.asyncAfter(deadline: .now() + dwell / 1000) {
                print("[demo] splash -> login")
                showLogin = true
            }
        }
    }
}
