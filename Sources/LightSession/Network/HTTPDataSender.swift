import Foundation

/// Uploads reports over HTTP.
///
/// `URLSession` and nothing else. A recorder that drags a networking dependency into every app that
/// installs it has already made itself expensive, and there is no request here that needs more.
public final class HTTPDataSender: DataSender {

    public enum SendError: LocalizedError {
        case notConfigured
        case badURL(String)
        case encoding(String)
        case rejected(status: Int, body: String)

        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "LightSession has no API key or base URL"
            case .badURL(let url):
                return "not a usable URL: \(url)"
            case .encoding(let what):
                return "could not encode \(what)"
            case .rejected(let status, let body):
                // The body is included because a 4xx from this API says which field was wrong, and
                // without it the report is "it failed" — which is how a missing required field survives.
                return "server rejected the request: \(status) \(body)"
            }
        }
    }

    /// Where the screen map lives under the product API.
    ///
    /// Appended by the SDK rather than asked of the app, so one `apiURL` configures Android, React Native
    /// and iOS identically — the Android SDK does exactly this. Asking each app to spell the prefix out
    /// would make the config platform-specific for no reason the app can see, and getting it wrong is a
    /// 404 on every capture: the SDK works perfectly and nothing is ever stored.
    static let screenMapPath = "api/v1/screenmap"

    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    /// - Parameter baseURL: the product API's root, as the app configured it. The screen-map prefix is
    ///   added here; passing a URL that already ends in it would double it.
    public init(baseURL: String, apiKey: String, session: URLSession? = nil) throws {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingTrailingSlashes()
        guard !trimmed.isEmpty, !apiKey.isEmpty else { throw SendError.notConfigured }
        // Tolerated rather than rejected: an app that read the Android setup and pasted the full URL is
        // configured correctly in every way that matters, and refusing it would be pedantry with a 404
        // as the punishment.
        if !trimmed.hasSuffix(Self.screenMapPath) {
            trimmed += "/" + Self.screenMapPath
        }
        guard let url = URL(string: trimmed) else { throw SendError.badURL(baseURL) }
        self.baseURL = url
        self.apiKey = apiKey
        self.session = session ?? {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            // Nothing here is worth delaying the app's own traffic for.
            config.networkServiceType = .background
            return URLSession(configuration: config)
        }()
    }

    public func send(screen: ScreenReport, completion: @escaping (Result<Void, Error>) -> Void) {
        perform(method: "POST", path: "screens", body: screen.createBody, completion: completion)
    }

    public func replaceScreenshot(screen: ScreenReport, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let body = screen.screenshotBody else {
            completion(.failure(SendError.encoding("a screenshot report with no image")))
            return
        }
        perform(method: "PUT", path: "screens/screenshot", body: body, completion: completion)
    }

    public func send(flow: FlowReport, completion: @escaping (Result<Void, Error>) -> Void) {
        let millis = Int64(Date().timeIntervalSince1970 * 1000)
        perform(method: "POST", path: "flows", body: flow.body(timestampMillis: millis), completion: completion)
    }

    // MARK: - Internals

    private func perform(
        method: String,
        path: String,
        body: [String: Any],
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(SendError.encoding(path)))
            return
        }

        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                completion(.failure(SendError.rejected(status: status, body: String(text.prefix(200)))))
                return
            }
            completion(.success(()))
        }.resume()
    }
}

extension String {
    func trimmingTrailingSlashes() -> String {
        var out = self
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }
}
