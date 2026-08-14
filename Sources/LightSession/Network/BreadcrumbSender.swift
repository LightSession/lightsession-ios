import Foundation

/// Where interaction batches go.
public protocol BreadcrumbSender: AnyObject {
    func send(fields: [String: String], completion: @escaping (Result<Void, Error>) -> Void)
}

/// Uploads a breadcrumb batch as `multipart/form-data`.
///
/// Multipart rather than JSON because that is what the endpoint reads, and the endpoint reads it because
/// the same route also carries frame batches with binary parts. Hand-built rather than through a library:
/// it is a boundary, a few fields, and no files.
public final class HTTPBreadcrumbSender: BreadcrumbSender {

    private let url: URL
    private let apiKey: String
    private let session: URLSession

    /// - Parameter ingestURL: the ingest service's root, as the app configured it. This is a *different*
    ///   service from the product API the screen map talks to, which is why it is a separate setting: on
    ///   Android they are `ingestUrl` and `apiUrl`, and pointing one at the other fails with a 404 on
    ///   everything.
    public init(ingestURL: String, apiKey: String, session: URLSession? = nil) throws {
        let trimmed = ingestURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingTrailingSlashes()
        guard !trimmed.isEmpty, !apiKey.isEmpty else { throw HTTPDataSender.SendError.notConfigured }
        guard let base = URL(string: trimmed) else { throw HTTPDataSender.SendError.badURL(ingestURL) }
        self.url = base.appendingPathComponent("breadcrumb_batch")
        self.apiKey = apiKey
        self.session = session ?? {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.networkServiceType = .background
            return URLSession(configuration: config)
        }()
    }

    public func send(fields: [String: String], completion: @escaping (Result<Void, Error>) -> Void) {
        let boundary = "LightSession-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.body(fields: fields, boundary: boundary)

        // Breadcrumbs are small JSON in multipart, the best case gzip has: 87% measured. See
        // `Compression`.
        session.dataTask(with: Compression.prepared(request)) { data, response, error in
            Compression.noteResponse(response)
            if let error {
                completion(.failure(error))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                completion(.failure(
                    HTTPDataSender.SendError.rejected(status: status, body: String(text.prefix(200)))
                ))
                return
            }
            completion(.success(()))
        }.resume()
    }

    /// The multipart body.
    ///
    /// Internal so a test can read it back without a server. Field order is sorted rather than dictionary
    /// order, which is arbitrary in Swift — not because the server cares, but because a payload that
    /// differs between runs is a payload that cannot be compared when something goes wrong.
    static func body(fields: [String: String], boundary: String) -> Data {
        var data = Data()
        for key in fields.keys.sorted() {
            guard let value = fields[key] else { continue }
            data.append("--\(boundary)\r\n")
            data.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            data.append(value)
            data.append("\r\n")
        }
        data.append("--\(boundary)--\r\n")
        return data
    }
}

private extension Data {
    mutating func append(_ string: String) {
        // UTF-8 cannot fail for a Swift string, so this is not an optional path worth branching on. It is
        // worth naming: breadcrumb JSON carries screen names, and screen names carry whatever the app calls
        // its screens.
        append(Data(string.utf8))
    }
}
