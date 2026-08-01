import UIKit

/// The controllers that hold screens without being one.
///
/// Every one of these calls `viewDidAppear` alongside the screen it contains, and reporting them would
/// put a node in the graph that no user could name — `UISplitViewController` is not a place, the
/// detail pane is. The SDK drops them by class, and these routes are what proves it still does.
///
/// They are grouped in one file because they are one rule, not four features.

/// Two panes. On a phone the secondary is pushed; on an iPad both are on screen at once.
///
/// Worth having for the iPad, where a container holding *two* screens at the same time is a shape a
/// phone never produces — the SDK reports the one it considers on top, and this is where that choice
/// is visible.
final class SplitViewScreens: UISplitViewController {

    init() {
        super.init(style: .doubleColumn)
        preferredDisplayMode = .oneBesideSecondary
        setViewController(SidebarViewController(), for: .primary)
        setViewController(DetailPaneViewController(), for: .secondary)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

final class SidebarViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Sidebar"
        view.backgroundColor = .secondarySystemBackground
        addCentredLabel("Sidebar — the primary column.")
    }
}

final class DetailPaneViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Detail"
        view.backgroundColor = .systemBackground
        addCentredLabel("Detail — the secondary column, and the screen a person would name.")
    }
}

/// Swipeable pages. The container is not a screen; each page is.
final class PagedScreens: UIPageViewController {

    private lazy var pages: [UIViewController] = (1...3).map { PageContentViewController(number: $0) }

    init() {
        super.init(transitionStyle: .scroll, navigationOrientation: .horizontal)
        dataSource = self
        setViewControllers([pages[0]], direction: .forward, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

extension PagedScreens: UIPageViewControllerDataSource {
    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerBefore viewController: UIViewController
    ) -> UIViewController? {
        guard let index = pages.firstIndex(of: viewController), index > 0 else { return nil }
        return pages[index - 1]
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
        guard let index = pages.firstIndex(of: viewController), index < pages.count - 1 else { return nil }
        return pages[index + 1]
    }
}

/// A container an app wrote itself, with `addChild`.
///
/// This one is here because it is the case the SDK gets **wrong**, and the sample is where that should
/// be visible rather than discovered by a customer. Measured: both the parent and its child are
/// reported, with an edge between them —
///
///     HubViewController -> CustomContainerScreens -> EmbeddedChildViewController
///
/// — when a person navigated once and saw one screen.
///
/// The five containers the SDK drops are dropped by class, which is exact and needs no maintenance. A
/// container the app wrote has no such marker. The obvious generalisation — *a controller with an
/// on-screen child is a container* — is not safe: a detail screen that embeds a map or a header
/// controller is still the screen, and that rule would delete it from the map. Losing a real screen is
/// worse than an extra node next to one.
///
/// So it stands, documented, until there is a signal that separates the two. An app that hits it can
/// name the child with `LightSession.setScreen`, and the repeated parent stops mattering.
final class CustomContainerScreens: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Custom container"
        view.backgroundColor = .systemBackground

        let child = EmbeddedChildViewController()
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40),
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -40),
        ])
        child.didMove(toParent: self)
    }
}

final class EmbeddedChildViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Embedded child"
        view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius = 16
        addCentredLabel("The embedded child, which is the screen. Its parent only holds it.")
    }
}

/// An alert over a screen.
///
/// `UIAlertController` is dropped by class: an alert is a part of the screen that raised it, which is
/// what the sub-screen mechanism describes as `Parent › Alert`. Reported as a screen it would be a node
/// with no way back, since dismissing an alert navigates nowhere.
final class AlertOverScreen: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Screen with an alert"
        view.backgroundColor = .systemBackground
        addCentredLabel("An alert appears in two seconds and closes two seconds later.")

        guard UserDefaults.standard.bool(forKey: "demoNav") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            print("[demo] alert up")
            let alert = UIAlertController(
                title: "Delete this?",
                message: "An alert is a part of the screen underneath, not a screen.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            self.present(alert, animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                print("[demo] alert down")
                alert.dismiss(animated: true)
            }
        }
    }
}

extension UIViewController {
    /// A label in the middle, which is all most of these screens need to be distinguishable.
    func addCentredLabel(_ text: String) {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .body)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
    }
}


/// One page, as a class the app owns.
///
/// The first version of this used a bare `UIViewController()` and produced nothing at all — correctly,
/// and instructively: `UIViewController` is UIKit's class, so the ownership rule files it as system
/// furniture. An app that uses a bare controller as a page gets no screen for it, which is a real
/// consequence of that rule and worth knowing. Subclassing is what an app does anyway.
final class PageContentViewController: UIViewController {

    private let number: Int

    init(number: Int) {
        self.number = number
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Page \(number)"
        let tints: [UIColor] = [.systemTeal, .systemIndigo, .systemPink]
        view.backgroundColor = tints[number - 1].withAlphaComponent(0.15)
        addCentredLabel("Page \(number) of 3 — swipe sideways.")
    }
}
