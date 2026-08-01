import LightSession
import SwiftUI

/// A SwiftUI app that never heard of this SDK.
///
/// No `.lightSessionScreen`, no `screensReportedByHost`, nothing. Two screens with the titles their
/// author wrote for the people using the app, which is what nineteen of one real app's twenty-one
/// screens already had. If the SDK can read those, integrating is one call and nothing else.
///
/// It is deliberately the *whole* shape rather than one screen: a `NavigationStack` inside a hosting
/// controller is three or four nested controllers, only the innermost of which has the title, and the
/// outer ones appearing first is exactly what makes this harder than reading a property.
@available(iOS 16.0, *)
struct TitledScreens: View {

    @State private var path = NavigationPath()

    private var script: [(after: Double, what: String, run: () -> Void)] {
        [
            (2, #"push record A -> expect "Message""#, { path.append("Ada Lovelace") }),
            // The round trip that broke it in the real app: by the time the user comes back from
            // editing, the screen's title is the record's name and `viewDidAppear` fires again.
            (5, #"push edit -> expect "Edit""#, { path.append("edit") }),
            (8, #"back -> must still be "Message", not "Ada Lovelace""#,
             { if !path.isEmpty { path.removeLast() } }),
            (11, "pop to the list", { if !path.isEmpty { path.removeLast() } }),
            (13, #"push record B -> still one "Message" node"#, { path.append("Grace Hopper") }),
        ]
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 8) {
                Text("Nothing here names this screen.").font(.headline)
                Text("The only name it has is the one in the navigation bar.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .navigationTitle("Inbox")
            .navigationDestination(for: String.self) { which in
                if which == "edit" {
                    Text("Editing. Going back re-appears the screen underneath.")
                        .padding()
                        .navigationTitle("Edit")
                } else {
                    LoadsItsTitle(record: which)
                }
            }
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

/// A screen whose title is a placeholder until its data arrives, which is how detail screens are
/// written and is the case that broke naming by title.
///
/// `.navigationTitle(record?.name ?? "Message")` is titled `Message` when it appears and titled
/// `Ada Lovelace` a second later. Measured on a real app, the map grew a node per record — and it
/// grew them slowly, because `viewDidAppear` fires again on the way back rather than at the moment
/// the title changes, so the wrong nodes appeared minutes apart and looked like real navigation.
///
/// What should be recorded is one node called `Message`, however many records are opened.
@available(iOS 16.0, *)
struct LoadsItsTitle: View {

    let record: String

    @State private var loaded: String?

    var body: some View {
        VStack(spacing: 8) {
            Text(loaded ?? "Loading…").font(.headline)
            Text("This screen's title becomes the record's name a second from now.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .navigationTitle(loaded ?? "Message")
        .task {
            // 50 ms, which is what a backend on this machine answers in. The first version of this
            // test waited a second, and a second is longer than the SDK's grace for a title to
            // appear — so the test passed by being slower than the bug.
            try? await Task.sleep(nanoseconds: 50_000_000)
            loaded = record
            print("[demo] title is now \(record)")
        }
    }
}
