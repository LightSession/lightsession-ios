import LightSession
import SwiftUI

/// The one shape nothing could observe: two screens sharing a hosting controller, swapped by state.
///
/// No `viewWillAppear`, no `viewDidAppear`, one object identity before and after — measured. The single
/// line at the bottom is what names both, from the app's own idea of where the user is.
@available(iOS 16.0, *)
struct RoutedRootScreens: View {

    enum Route: Equatable {
        case loading
        case login
        case doctorDetail(String)
        case home
    }

    @State private var route = Route.loading
    @State private var path = NavigationPath()

    var body: some View {
        Group {
            switch route {
            case .loading:
                Text("Splash").font(.largeTitle)
            case .login:
                VStack(spacing: 12) { Text("Login").font(.largeTitle); Text("email") }
            case .doctorDetail(let id):
                VStack { Text("Doctor").font(.largeTitle); Text(id) }
            case .home:
                // A stack whose screens carry only titles, under a root that names its routes. Both
                // sources at once, which is what a real app looks like — and the combination that a
                // guard on `hostHasReported` silently broke: naming the route turned off naming by
                // title, and nineteen screens went missing.
                NavigationStack(path: $path) {
                    Text("Inbox").navigationTitle("Inbox")
                        .navigationDestination(for: String.self) { _ in
                            Text("Message").navigationTitle("Message")
                        }
                }
            }
        }
        .lightSessionScreen(for: route)
        .onAppear(perform: walkIfAsked)
    }

    /// Walks the states the way a user would: splash, then login, then two different records — the last
    /// two to prove a payload does not become a node of its own.
    private func walkIfAsked() {
        guard UserDefaults.standard.bool(forKey: "demoNav") else { return }
        let script: [(Double, Route)] = [
            (2, .login),
            (4, .doctorDetail("dr-carlos")),
            (6, .doctorDetail("dra-ana")),
            (8, .home),
        ]
        for (after, next) in script {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                print("[demo] route -> \(next)")
                route = next
            }
        }
        // Once inside the stack, push a titled screen: the route has been named, and the title must
        // still be read.
        DispatchQueue.main.asyncAfter(deadline: .now() + 11) {
            print("[demo] push inside the stack -> expect \"Message\"")
            path.append("detail")
        }
    }
}
