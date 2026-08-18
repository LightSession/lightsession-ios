import UIKit
import SwiftUI
import LightSession

/// The screens exist to put a different shape in front of the mapper, not to be an app.
///
/// Each one answers a question the wireframe path could get wrong, and they are listed in the hub in the
/// order the questions matter:
///
///  * `PushedViewController`   — does a plain pushed controller get its own name and its own wireframe?
///  * `FormViewController`     — does `maskText` cover a `UITextField`, and does a field read as an input?
///  * `ListViewController`     — does a table come out as rows, or as one slab?
///  * `TabsViewController`     — a tab bar: the child is the screen, the container is not.
///  * `SwiftUIHostViewController` — SwiftUI screens, named by the app, with a sheet as a sub-screen.
///
/// The last one is the honest case: the platform cannot name a SwiftUI screen, so the app does.
final class HubViewController: UIViewController {

    /// One entry in the catalogue.
    ///
    /// `presented` exists because a `UISplitViewController` cannot be pushed onto a navigation stack —
    /// measured, it lays out nothing at all and the SDK sees no screen, which looks like a bug in the
    /// SDK and is a bug in the sample. A route says how it wants to be shown.
    struct Route {
        let slug: String
        let title: String
        let make: () -> UIViewController
        var presented: Bool = false

        init(_ slug: String, _ title: String, _ make: @escaping () -> UIViewController, presented: Bool = false) {
            self.slug = slug
            self.title = title
            self.make = make
            self.presented = presented
        }
    }

    /// Shows a route the way that route needs to be shown.
    func show(_ route: Route) {
        let destination = route.make()
        if route.presented {
            destination.modalPresentationStyle = .fullScreen
            present(destination, animated: true)
        } else {
            navigationController?.pushViewController(destination, animated: true)
        }
    }

    /// Every shape of screen and navigation this SDK has to read, each reachable by a slug so the
    /// same list drives a tap and a script.
    ///
    /// Grouped by the question each one asks, because the list is long enough that a flat catalogue
    /// stops being readable — and because the groups *are* the taxonomy: what a screen is made of,
    /// what merely contains one, what covers one, and what happens when nobody names anything.
    static let sections: [(title: String, routes: [Route])] = [
        ("UIKit content", [
            Route("pushed", "Pushed controller", { PushedViewController() }),
            Route("form", "Form with text fields", { FormViewController() }),
            Route("list", "Table of rows", { ListViewController() }),
            // `NodeKind.webView` existed and nothing produced one. A web view is also the one thing the
            // SDK cannot describe from inside: the page is another process.
            Route("web", "Web view", { WebViewScreen() }),
        ]),

        // Four controllers that hold screens without being one. All four call `viewDidAppear` next to
        // the screen they contain, and all four must be dropped.
        ("Containers, which are not screens", [
            Route("tabs", "Tab bar", { TabsViewController() }),
            Route("split", "Split view", { SplitViewScreens() }, presented: true),
            Route("paged", "Page view controller", { PagedScreens() }),
            Route("container", "A container the app wrote", { CustomContainerScreens() }),
        ]),

        // Three ways of covering a screen that behave differently underneath — see ModalScreens.
        ("Things that cover a screen", [
            Route("alert", "An alert over a screen", { AlertOverScreen() }),
            Route("fullmodal", "A full-screen modal", { FullScreenModalHost() }),
            Route("covers", "Sheet, cover and dialog", {
                guard #available(iOS 16.0, *) else { return UIViewController() }
                return UIHostingController(rootView: CoversScreens())
            }),
            Route("richsheet", "A sheet with a whole form in it", {
                guard #available(iOS 16.0, *) else { return UIViewController() }
                return UIHostingController(rootView: RichSheetScreens())
            }),
            Route("sheetreturn", "A sheet, and what comes after it", {
                guard #available(iOS 16.0, *) else { return UIViewController() }
                return UIHostingController(rootView: SheetReturnScreens())
            }),
        ]),

        ("SwiftUI, named by the app", [
            Route("swiftui", "Named, with a sheet as a sub-screen", { SwiftUIHostViewController() }),
            // Tabs and a stack, every screen named. Run with `-demoHostNamesScreens 1 -demoNav 1`.
            Route("hostnamed", "Tabs and a stack, named", {
                guard #available(iOS 16.0, *) else { return UIViewController() }
                return UIHostingController(rootView: HostNamedScreens())
            }),
            // A named screen that opens a sheet and an alert — the shape two field reports came
            // from. Run with `-demoHostNamesScreens 1 -demoNav 1`.
            Route("hostmodal", "Named screen with a sheet and an alert", {
                guard #available(iOS 16.0, *) else { return UIViewController() }
                return UIHostingController(rootView: HostNamedModalScreens())
            }),
            // A named screen that pushes, with a field — the shape that produced phantom modal
            // nodes. Run with `-demoHostNamesScreens 1 -demoNav 1`.
            Route("hostpush", "Named screen that pushes, with a keyboard", {
                guard #available(iOS 16.0, *) else { return UIViewController() }
                return UIHostingController(rootView: HostNamedPushScreens())
            }),
            // A sheet the app names itself, over a busier parent — the shape a company switcher
            // came in, and the one the late-content watch mishandles on the way out.
            Route("hostsheet", "Named sheet over a busier screen", {
                guard #available(iOS 16.0, *) else { return UIViewController() }
                return UIHostingController(rootView: HostNamedSheetScreens())
            }),
            // A screen that settles on a loading placeholder and fills in later — the shape a
            // stored capture froze in, in production.
            Route("lateload", "Placeholder first, real rows later", {
                guard #available(iOS 16.0, *) else { return UIViewController() }
                return UIHostingController(rootView: LateLoadingScreens())
            }),
            // The shortest screen an app has: a splash that decides and leaves.
            Route("splash", "A splash that leaves in milliseconds", {
                guard #available(iOS 16.0, *) else { return UIViewController() }
                return UIHostingController(rootView: SplashScreens())
            }),
            // A root that swaps its content: the one shape that emits no UIKit event at all.
            Route("routed", "A root switch, named by its route", {
                guard #available(iOS 16.0, *) else { return UIViewController() }
                return UIHostingController(rootView: RoutedRootScreens())
            }),
        ]),

        ("SwiftUI, naming itself or not at all", [
            // Titles only, no annotations: what the SDK reads from an app that changed nothing.
            Route("titled", "A stack with titles and no annotations", {
                guard #available(iOS 16.0, *) else { return UIViewController() }
                return UIHostingController(rootView: TitledScreens())
            }),
            // A plain `UIHostingController`: the class belongs to SwiftUI, and its name is a mangled
            // generic. The one route the SDK is expected to refuse to name.
            Route("unnamed", "SwiftUI with no name", { UIHostingController(rootView: UnnamedSwiftUIScreen()) }),
            // The integration deliberately missing, so the failure mode can be looked at.
            Route("untracked", "Navigation with nothing to name it", {
                guard #available(iOS 16.0, *) else { return UIViewController() }
                return UIHostingController(rootView: UntrackedNavigationScreens())
            }),
        ]),
    ]

    /// Flattened, for the driver and for `route(named:)`.
    static let routes: [Route] = sections.flatMap(\.routes)

    static func route(named slug: String) -> Route? {
        routes.first { $0.slug == slug }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "LightSession"
        view.backgroundColor = .systemBackground

        let heading = UILabel()
        heading.text = "UIKit views. Every screen below is a different shape the mapper has to read."
        heading.numberOfLines = 0
        heading.font = .preferredFont(forTextStyle: .subheadline)
        heading.textColor = .secondaryLabel

        let stack = UIStackView(arrangedSubviews: [heading])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        for section in Self.sections {
            let heading = UILabel()
            heading.text = section.title.uppercased()
            heading.font = .preferredFont(forTextStyle: .caption1)
            heading.textColor = .tertiaryLabel
            stack.addArrangedSubview(heading)
            stack.setCustomSpacing(4, after: heading)

            for route in section.routes {
                let button = UIButton(type: .system)
                button.setTitle(route.title, for: .normal)
                button.contentHorizontalAlignment = .leading
                button.titleLabel?.font = .preferredFont(forTextStyle: .body)
                button.addAction(
                    UIAction { [weak self] _ in self?.show(route) },
                    for: .touchUpInside
                )
                stack.addArrangedSubview(button)
            }
            stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)
        }

        // Scrollable, because the catalogue outgrew the screen the day it became a catalogue.
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
        ])
    }
}

/// A pushed controller, which is the ordinary case and therefore the one that must not need help.
final class PushedViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Pushed"
        view.backgroundColor = .systemBackground

        let label = UILabel()
        label.text = "A UILabel, which descends from the class the mapper dispatches on — so it is text "
            + "without the SDK knowing anything about this app."
        label.numberOfLines = 0

        let block = UIView()
        block.backgroundColor = .systemIndigo
        block.layer.cornerRadius = 12

        let image = UIImageView(image: UIImage(systemName: "square.grid.2x2"))
        image.tintColor = .systemTeal
        image.contentMode = .scaleAspectFit

        let stack = UIStackView(arrangedSubviews: [label, block, image])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            block.heightAnchor.constraint(equalToConstant: 80),
            image.heightAnchor.constraint(equalToConstant: 60),
        ])
    }
}

/// Real content in real fields, so the masking is tested against something worth masking.
final class FormViewController: UIViewController {

    private var fields: [UITextField] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Form"
        view.backgroundColor = .systemBackground

        let fields = ["Ada Lovelace", "ada@example.com", "+44 20 7946 0958"].map { value -> UITextField in
            let field = UITextField()
            field.text = value
            field.borderStyle = .roundedRect
            field.backgroundColor = .secondarySystemBackground
            return field
        }

        let note = UILabel()
        note.text = "These are UITextFields with content in them. With maskText on, the capture that "
            + "leaves the device has grey blocks where this text is."
        note.numberOfLines = 0
        note.font = .preferredFont(forTextStyle: .footnote)
        note.textColor = .secondaryLabel

        let stack = UIStackView(arrangedSubviews: fields + [note])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])

        self.fields = fields
    }

    /// Raises the keyboard on `-demoKeyboard 1`, because the keyboard is a test case.
    ///
    /// Tapping a text field brings six view controllers on screen that the app did not write — the
    /// prediction bar, the input assistant, the keyboard dock, the cursor accessory and the windows
    /// holding them — and each one calls `viewDidAppear`. A run against a real app mapped all of them
    /// as screens the user had navigated to. There is no way to tap a field from a script, so the
    /// sample offers to do it itself; the SDK knows nothing about this flag.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard UserDefaults.standard.bool(forKey: "demoKeyboard") else { return }
        fields.first?.becomeFirstResponder()
    }
}

/// Rows, to check a list does not collapse into one rectangle.
final class ListViewController: UIViewController, UITableViewDataSource {
    private let table = UITableView()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "List"
        view.backgroundColor = .systemBackground
        table.dataSource = self
        table.frame = view.bounds
        table.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(table)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 20 }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = "Row \(indexPath.row + 1)"
        cell.detailTextLabel?.text = "A subtitle, so each row has two text nodes"
        cell.imageView?.image = UIImage(systemName: "circle.fill")
        return cell
    }
}

/// A tab bar. The container is not a screen; each tab's controller is.
final class TabsViewController: UITabBarController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let overview = PushedViewController()
        overview.title = "Overview"
        overview.tabBarItem = UITabBarItem(title: "Overview", image: UIImage(systemName: "house"), tag: 0)

        let settings = FormViewController()
        settings.title = "Settings"
        settings.tabBarItem = UITabBarItem(title: "Settings", image: UIImage(systemName: "gear"), tag: 1)

        viewControllers = [overview, settings]
    }
}

// MARK: - SwiftUI

/// SwiftUI screens, named by the app because the platform cannot name them.
///
/// This controller is a `UIHostingController` subclass, and the SDK would otherwise report *it* for every
/// SwiftUI screen inside — which is the failure the advisory in the log describes.
final class SwiftUIHostViewController: UIHostingController<SwiftUIRoot> {
    init() {
        super.init(rootView: SwiftUIRoot())
        title = "SwiftUI"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// A SwiftUI screen with no name on it, hosted by SwiftUI's own controller.
///
/// The case a whole app can be built out of without noticing. It is here so the SDK's refusal to name it
/// is exercised by the sample rather than only by somebody's production app: what should be recorded is
/// one node called "SwiftUI (unnamed)", and a line in the log saying which call fixes it.
struct UnnamedSwiftUIScreen: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("No .lightSessionScreen here")
                .font(.headline)
            Text(
                "This is hosted by SwiftUI's own UIHostingController, whose class name is a mangled "
                    + "generic. The SDK maps it to one placeholder node instead of naming it."
            )
            .font(.footnote)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding()
    }
}

struct SwiftUIRoot: View {
    /// Opens with the sheet up when launched with `-demoSheet YES`.
    ///
    /// The same scaffolding as `-demoRoutes` and for the same reason: the simulator has no way to
    /// tap a button from a script, and masking a modal is exactly the case that can only be checked
    /// with the modal on screen. Nothing in the SDK knows this exists.
    @State private var showingSheet = UserDefaults.standard.bool(forKey: "demoSheet")

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("A SwiftUI screen")
                .font(.title2)
            Text(
                "Named with .lightSessionScreen(\"SwiftUIHome\"). Without it every SwiftUI screen in the "
                + "app would map to the one hosting controller."
            )
            .foregroundStyle(.secondary)

            Button("Open a sheet") { showingSheet = true }
                .buttonStyle(.borderedProminent)

            Rectangle()
                // A flat fill rather than `.gradient`, which is iOS 16. The package targets 15, and an
                // example that needs a newer OS than the library does is an example that misreports what
                // the library supports.
                .fill(Color.orange)
                .frame(height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            Spacer()
        }
        .padding(20)
        .lightSessionScreen("SwiftUIHome")
        .sheet(isPresented: $showingSheet) {
            VStack(spacing: 12) {
                Text("A sheet").font(.headline)
                Text("Declared as a part of the screen rather than a screen of its own, so it arrives as "
                     + "SwiftUIHome › Sheet.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Close") { showingSheet = false }
            }
            .padding(24)
            .lightSessionSubScreen("Sheet")
        }
    }
}
