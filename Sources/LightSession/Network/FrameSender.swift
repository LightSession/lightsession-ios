import Foundation

/// Where replay frames go.
public protocol FrameSender: AnyObject {
    func send(
        metadata: [String: String],
        frames: [ReplayFrame],
        completion: @escaping (Result<Void, Error>) -> Void
    )
}

/// Uploads a frame batch as `multipart/form-data` to `POST {ingestURL}/upload_batch`.
///
/// The part naming is the contract and it is positional: `metadata`, then `frame_0`, `frame_0_metadata`,
/// `frame_1`, and so on. The server pairs a body with its metadata by that index, so a gap in the numbering
/// silently detaches a frame from its timestamp.
public final class HTTPFrameSender: FrameSender {

    private let url: URL
    private let apiKey: String
    private let session: URLSession

    public init(ingestURL: String, apiKey: String, session: URLSession? = nil) throws {
        let trimmed = ingestURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingTrailingSlashes()
        guard !trimmed.isEmpty, !apiKey.isEmpty else { throw HTTPDataSender.SendError.notConfigured }
        guard let base = URL(string: trimmed) else { throw HTTPDataSender.SendError.badURL(ingestURL) }
        self.url = base.appendingPathComponent("upload_batch")
        self.apiKey = apiKey
        self.session = session ?? {
            let config = URLSessionConfiguration.default
            // Longer than the API's: a batch is two dozen JPEGs, and a slow network that would have
            // succeeded in forty seconds should not have the upload thrown away at thirty.
            config.timeoutIntervalForRequest = 60
            config.networkServiceType = .background
            return URLSession(configuration: config)
        }()
    }

    public func send(
        metadata: [String: String],
        frames: [ReplayFrame],
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let boundary = "LightSession-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        guard let metadataJSON = Self.json(metadata) else {
            completion(.failure(HTTPDataSender.SendError.encoding("frame batch metadata")))
            return
        }
        request.httpBody = Self.body(
            metadataJSON: metadataJSON,
            frames: frames,
            boundary: boundary
        )

        // Frame batches are the 91% of upstream this exists for: masked flat-UI JPEG still
        // shrinks 37%, measured on Android with real captures. See `Compression`.
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

    /// Internal so a test can read the body back without a server.
    static func body(metadataJSON: String, frames: [ReplayFrame], boundary: String) -> Data {
        var data = Data()

        data.appendField(name: "type", value: "frame_batch", boundary: boundary)
        data.appendField(name: "metadata", value: metadataJSON, boundary: boundary)

        for (index, frame) in frames.enumerated() {
            data.append("--\(boundary)\r\n")
            data.append(
                "Content-Disposition: form-data; name=\"frame_\(index)\"; filename=\"\(frame.fileName)\"\r\n"
            )
            data.append("Content-Type: \(frame.contentType)\r\n\r\n")
            data.append(frame.data)
            data.append("\r\n")

            if let json = json(frame.metadata(index: index)) {
                data.appendField(name: "frame_\(index)_metadata", value: json, boundary: boundary)
            }
        }

        data.append("--\(boundary)--\r\n")
        return data
    }

    static func json(_ value: [String: String]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }

    mutating func appendField(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append(value)
        append("\r\n")
    }
}
