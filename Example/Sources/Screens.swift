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

    /// The routes, each with the slug the URL scheme uses. One list, so a screen reachable by tapping is
    /// reachable by script and the driver cannot drift from the app.
    static let routes: [(slug: String, title: String, make: () -> UIViewController)] = [
        ("pushed", "Pushed controller", { PushedViewController() }),
        ("form", "Form with text fields", { FormViewController() }),
        ("list", "Table of rows", { ListViewController() }),
        ("tabs", "Tab bar", { TabsViewController() }),
        ("swiftui", "SwiftUI screens", { SwiftUIHostViewController() }),
        // A *plain* `UIHostingController`, which is what a SwiftUI app that never touched UIKit has.
        // The class belongs to SwiftUI rather than to the app, and its name is a mangled generic that
        // changes with the iOS release — so this is the one route the SDK is expected to refuse to name.
        ("unnamed", "SwiftUI with no name", { UIHostingController(rootView: UnnamedSwiftUIScreen()) }),
        // Tabs and a navigation stack, every screen named by the app. Run it with
        // `-demoHostNamesScreens 1 -demoNav 1`, which is the configuration a SwiftUI app ships.
        // The shape a real SwiftUI app has and the one this feature is for: a NavigationStack whose
        // screens carry `.navigationTitle` and nothing else. No `.lightSessionScreen` anywhere — the
        // SDK is expected to read the titles the app already wrote for its users.
        ("titled", "A stack with titles and no annotations", {
            guard #available(iOS 16.0, *) else { return UIViewController() }
            return UIHostingController(rootView: TitledScreens())
        }),
        // A root that swaps its content, named by the app's route in one line. The shape that emits
        // no UIKit event at all.
        ("routed", "A root switch, named by its route", {
            guard #available(iOS 16.0, *) else { return UIViewController() }
            return UIHostingController(rootView: RoutedRootScreens())
        }),
        ("hostnamed", "Tabs and a stack, named", {
            guard #available(iOS 16.0, *) else { return UIViewController() }
            return UIHostingController(rootView: HostNamedScreens())
        }),
    ]

    static func route(named slug: String) -> UIViewController? {
        routes.first { $0.slug == slug }?.make()
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

        for route in Self.routes {
            let button = UIButton(type: .system)
            button.setTitle(route.title, for: .normal)
            button.contentHorizontalAlignment = .leading
            button.titleLabel?.font = .preferredFont(forTextStyle: .body)
            button.addAction(
                UIAction { [weak self] _ in
                    self?.navigationController?.pushViewController(route.make(), animated: true)
                },
                for: .touchUpInside
            )
            stack.addArrangedSubview(button)
        }

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
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
