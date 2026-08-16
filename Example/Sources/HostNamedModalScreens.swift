import LightSession
import SwiftUI

/// A SwiftUI app that names its own screens and opens modals from them.
///
/// This is the shape a real app reported problems from, reproduced: `screensReportedByHost` on, a
/// detail screen named by the app, and a `.sheet` and an alert raised out of it. Two failures were
/// reported against exactly this and neither is visible in any other sample screen:
///
///  * the sheet is never mapped — no node of its own, ever;
///  * and its contents appear inside the *parent* screen's wireframe instead.
///
/// Driven on a timer rather than by taps, for the reason `HostNamedScreens` gives: the simulator
/// cannot be told to tap, and a driver that taps coordinates stops testing anything the day the
/// layout moves. Long dwells on purpose — the late-content watch ticks at one hertz, so a modal has
/// to stay up for several ticks before a race against it can happen at all.
@available(iOS 16.0, *)
struct HostNamedModalScreens: View {

    @State private var sheet = false
    @State private var alert = false

    /// What the walk does. The dwell after each step is what makes a race reproducible rather than
    /// occasional.
    private var script: [(after: Double, what: String, run: () -> Void)] {
        [
            (4, "sheet up -> expect a sub-screen of Detail", { sheet = true }),
            (12, "sheet down -> expect Detail alone again", { sheet = false }),
            (17, "alert up -> expect another sub-screen", { alert = true }),
            (25, "alert down", { alert = false }),
        ]
    }

    var body: some View {
        VStack(spacing: 8) {
            Text("Detail").font(.title2)
            Text("A named screen that opens modals.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .lightSessionScreen("Detail")
        .sheet(isPresented: $sheet) {
            // Deliberately not annotated with `.lightSessionSubScreen`. The question is what the SDK
            // does on its own for an app that opens a sheet without knowing the modifier exists —
            // which is every app until someone reads the documentation.
            VStack(spacing: 12) {
                Text("Sheet").font(.title3)
                Text("Filter by status").font(.body)
                Text("This content must not end up in Detail's wireframe.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .alert("Delete this?", isPresented: $alert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {}
        } message: {
            Text("An alert raised from a host-named screen.")
        }
        .onAppear {
            guard UserDefaults.standard.bool(forKey: "demoNav") else { return }
            for step in script {
                DispatchQueue.main.asyncAfter(deadline: .now() + step.after) {
                    print("[demo] \(step.what)")
                    step.run()
                }
            }
        }
    }
}
