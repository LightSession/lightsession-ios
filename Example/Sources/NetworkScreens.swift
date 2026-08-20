import UIKit
import LightSession

/// The network capture, exercised against a real server with real sockets.
///
/// Every case here is one that mattered somewhere: a path with an id in it, a query with a token in
/// it, a request that never connects, and a burst — which is the case that proves each call carries
/// its own sequence, because the server's natural key includes it and two calls sharing one
/// collapse into a single row.
///
/// Driven by `-demoRootRoute network -demoNetworkAction <case>` so a script can run one case at a
/// time and the database can be read afterwards.
final class NetworkPlaygroundViewController: UIViewController {

    /// Our own local API. `127.0.0.1` reaches the host from the simulator — the Android sample needs
    /// `10.0.2.2` for the same thing, which is the one line of that playground that does not port.
    private static let base = "http://127.0.0.1:3002"

    /// The app's own client, with our delegate on it. This is the whole integration: an app with no
    /// delegate of its own adds one argument to a call it already makes.
    private lazy var session = URLSession(
        configuration: .default,
        delegate: LightSessionURLSessionDelegate(),
        delegateQueue: nil
    )

    private let log = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Network"
        view.backgroundColor = .systemBackground

        log.isEditable = false
        log.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        log.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: cases.map(button(for:)))
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        view.addSubview(log)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            log.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 16),
            log.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            log.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            log.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let requested = UserDefaults.standard.string(forKey: "demoNetworkAction") else { return }
        // A beat after the screen settles, so the call is attributed to a screen the SDK has already
        // named rather than to whatever it had at `viewDidAppear`.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.run(requested)
        }
    }

    private var cases: [(String, String)] {
        [
            ("ok", "GET /health — 200"),
            ("notfound", "GET a path with an id in it — 404"),
            ("secret", "GET with a token in the query"),
            ("post", "POST with a body"),
            ("fail", "a port nothing listens on"),
            ("burst", "six at once"),
        ]
    }

    private func button(for item: (String, String)) -> UIButton {
        var configuration = UIButton.Configuration.bordered()
        configuration.title = item.1
        let action = UIAction { [weak self] _ in self?.run(item.0) }
        return UIButton(configuration: configuration, primaryAction: action)
    }

    private func run(_ action: String) {
        switch action {
        case "ok":
            get("\(Self.base)/health")

        case "notfound":
            // `84321` has to arrive as `{id}`. If the raw number reaches the database, the collapsing
            // did not run on the device and every id in the app is in our storage.
            get("\(Self.base)/api/v1/projects/84321/x")

        case "secret":
            // A token and a document number, deliberately. Neither may appear anywhere in the row.
            get("\(Self.base)/api/v1/session?token=eyJhbGciOiJIUzI1NiJ9.abc.def&cpf=12345678900")

        case "post":
            post("\(Self.base)/api/v1/auth/validate", body: #"{"probe":"lightsession-network-demo"}"#)

        case "fail":
            // Nothing listens on port 9. A request with no answer has no status, and `0` plus a
            // failure class is what that has to look like.
            get("http://127.0.0.1:9/never")

        case "burst":
            // Six at once, all collapsing to one endpoint. Each needs its own sequence or the
            // server's `(session, kind, seq, ts)` key folds them into one row — and a burst is
            // exactly when a shared sequence and a shared millisecond happen together.
            for index in 1...6 {
                get("\(Self.base)/api/v1/projects/\(index)/x")
            }

        default:
            append("unknown action \(action)")
        }
    }

    private func get(_ url: String) {
        guard let target = URL(string: url) else { return }
        // The body is read back every time, on purpose. On Android the equivalent check is load
        // bearing — an interceptor that reads a body consumes it and the app gets nothing. Here it
        // cannot happen by construction, and reading anyway is what turns "cannot" into "did not".
        session.dataTask(with: target) { [weak self] data, response, error in
            self?.report(url, data, response, error)
        }.resume()
    }

    private func post(_ url: String, body: String) {
        guard let target = URL(string: url) else { return }
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        session.dataTask(with: request) { [weak self] data, response, error in
            self?.report(url, data, response, error)
        }.resume()
    }

    private func report(_ url: String, _ data: Data?, _ response: URLResponse?, _ error: Error?) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let read = data?.count ?? 0
        let path = URL(string: url)?.path ?? url
        if let error {
            append("\(path) failed: \((error as NSError).code)")
        } else {
            append("\(path) -> \(status), read \(read) bytes")
        }
    }

    private func append(_ line: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            log.text = (log.text ?? "") + line + "\n"
            print("[demo] \(line)")
        }
    }
}
