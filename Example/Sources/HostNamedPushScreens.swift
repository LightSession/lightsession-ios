import LightSession
import SwiftUI

/// A host-named app that *pushes* — with a text field, because the keyboard brings controllers of
/// its own.
///
/// The shape of a real login flow: a named screen, a field the person types into, and a push to the
/// next step. Reported against exactly this: going from login to the MFA step produced two extra
/// nodes named `Modal` and `Sheet`, edges and all, for a journey with no modal in it.
///
/// This exists because the modal-layer rule cannot be checked by reading it. What UIKit presents on
/// an app's behalf — keyboard hosts, input assistants, whatever a framework nests inside a
/// navigation stack — is not knowable from the documentation, and the SDK's answer must be measured
/// against it rather than assumed.
@available(iOS 16.0, *)
struct HostNamedPushScreens: View {

    @State private var path = NavigationPath()
    @State private var code = ""
    @FocusState private var focused: Bool

    private var script: [(after: Double, what: String, run: () -> Void)] {
        [
            (3, "focus the field -> keyboard up, expect no new node", { focused = true }),
            (7, "push -> expect Mfa and nothing else", { path.append("mfa") }),
            (12, "pop -> expect Login again", { if !path.isEmpty { path.removeLast() } }),
        ]
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 12) {
                Text("Login").font(.title2)
                TextField("Email", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .lightSessionScreen("Login")
            .navigationDestination(for: String.self) { _ in
                VStack(spacing: 12) {
                    Text("Mfa").font(.title2)
                    Text("A pushed step, not a modal.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .lightSessionScreen("Mfa")
            }
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
