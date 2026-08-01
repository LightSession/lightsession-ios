import SwiftUI
import UIKit
import WebKit

/// A screen that is mostly a web view.
///
/// `NodeKind.webView` exists in the wireframe vocabulary and nothing in this sample produced one, which
/// means the branch that emits it was never exercised on a device. A web view is also the one piece of
/// content the SDK cannot describe from the inside: the page's text lives in another process, so the
/// wireframe has a single rectangle where a person sees a document. Worth seeing rather than assuming.
///
/// The page is loaded from a string, so the sample needs no network and produces the same screen every
/// time — a screenshot that changes with someone's connection is not a fixture.
final class WebViewScreen: UIViewController {

    private let web = WKWebView()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Web view"
        view.backgroundColor = .systemBackground

        let caption = UILabel()
        caption.text = "Below is a WKWebView. Its text is drawn by another process, so the wireframe "
            + "has one rectangle where you can read a paragraph."
        caption.numberOfLines = 0
        caption.font = .preferredFont(forTextStyle: .footnote)
        caption.textColor = .secondaryLabel

        for subview in [caption, web] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            caption.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            caption.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            caption.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            web.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 16),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        web.loadHTMLString(
            """
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <body style="font: 17px -apple-system; padding: 24px; color: #16181d">
              <h2>A document</h2>
              <p>This paragraph is rendered by WebKit. The SDK sees a web view and nothing inside it.</p>
              <p>Sensitive text here would not be covered by the mask scanner, which is the reason a
                 web view is worth its own kind rather than being drawn as a plain container.</p>
            </body>
            """,
            baseURL: nil
        )
    }
}

/// Several SwiftUI screens with the integration **deliberately missing**.
///
/// Note the absence: no `.lightSessionScreen`, no `navigationTitle`, no route reported. Every other
/// SwiftUI route in this sample gives the SDK something to work with; this one gives it nothing, so it
/// shows what a developer who integrated and stopped there actually gets — one placeholder node for
/// three screens, and a line in the log naming the call that fixes it.
///
/// The Android sample carries the same deliberate hole for the same reason: the failure mode is worth
/// being able to look at, and a sample where everything works teaches nobody what going wrong looks
/// like.
@available(iOS 16.0, *)
struct UntrackedNavigationScreens: View {

    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 10) {
                Text("Untracked").font(.largeTitle)
                Text("No title, no annotation. Three screens that will share one node.")
                    .font(.footnote).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal)
            }
            .navigationDestination(for: Int.self) { step in
                VStack(spacing: 10) {
                    Text("Step \(step)").font(.largeTitle)
                    Text("Also unnamed.").font(.footnote).foregroundColor(.secondary)
                }
            }
        }
        .onAppear(perform: walkIfAsked)
    }

    private func walkIfAsked() {
        guard UserDefaults.standard.bool(forKey: "demoNav") else { return }
        for (after, step) in [(2.0, 1), (4.0, 2)] {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                print("[demo] pushing step \(step) — still nothing to name it with")
                path.append(step)
            }
        }
    }
}
