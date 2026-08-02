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
    @State private var sheetUp = false

    var body: some View {
        Group {
            switch route {
            case .loading:
                Text("Splash").font(.largeTitle)
            case .login:
                // A sheet raised from a screen the *route* names, which is the combination that broke.
                // The screen underneath has no name of its own — the app names it — so re-reading the
                // controller after the sheet closes finds nothing, and the SDK used to stay on the
                // sheet. Measured on a real app: `Login -> Esqueci minha senha -> Ativar conta`, no way
                // back, and the second sheet's screenshot was a picture of the login screen.
                VStack(spacing: 12) { Text("Login").font(.largeTitle); Text("email") }
                    .sheet(isPresented: $sheetUp) {
                        NavigationStack {
                            Text("Forgot your password?")
                                .padding().navigationTitle("Forgot password")
                        }
                    }
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
        // A sheet up and down while the route stays `.login`, before anything else happens.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            print("[demo] sheet up over the routed login")
            sheetUp = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            print("[demo] sheet down — must come back to login")
            sheetUp = false
        }

        let script: [(Double, Route)] = [
            (2, .login),
            (7, .doctorDetail("dr-carlos")),
            (9, .doctorDetail("dra-ana")),
            (11, .home),
            // Back to a route while a titled screen is mounted — the logout shape. The stack under
            // `.home` is torn down, which fires `viewDidDisappear` with its titled controller briefly
            // still on top. Reading it there reported the screen the user had just left and undid the
            // route change: measured on a real app as `Perfil -> Login` followed, in the same second,
            // by `Login -> Perfil`.
            (17, .login),
        ]
        for (after, next) in script {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                print("[demo] route -> \(next)")
                route = next
            }
        }
        // Once inside the stack, push a titled screen: the route has been named, and the title must
        // still be read.
        DispatchQueue.main.asyncAfter(deadline: .now() + 14) {
            print("[demo] push inside the stack -> expect \"Message\"")
            path.append("detail")
        }
    }
}
