import Foundation

/// One HTTP request the app made, reduced to what may leave the device.
///
/// The reduction is the type. Everything is either a number or a value from a closed vocabulary,
/// except `host` and `path` — and `path` has been through `PathTemplate`, which is why this struct
/// cannot be built with a raw URL: the collapsing is not optional, and a type that accepted a URL
/// would let a caller skip it.
///
/// ## What is not here
///
/// No bodies. No headers. No query. Not "redacted" — absent, with no field to hold them, so no
/// future edit adds one by loosening a filter. The request body of a login is a password and the
/// response body of a profile is a name; neither is needed to answer "which endpoint is slow", and
/// storing them would put the customer's users' secrets in our database for thirteen months.
struct ApiCall {
    let method: String
    let host: String
    /// Already collapsed. `/v1/orders/{id}/items`, never `/v1/orders/84321/items`.
    let path: String
    /// The HTTP status, or `0` when the request never got one — a DNS failure has no status, and
    /// `0` is the value the ingest and the rollup already read as "failed before answering".
    let status: Int
    let durationMillis: Int64
    let requestBytes: Int64
    let responseBytes: Int64
    /// A word from a closed set, or `""` for a request that completed. Never a message: an error
    /// description on this platform interpolates the URL, so `error.localizedDescription` is a
    /// token leak wearing a diagnostic's clothes.
    let failure: String

    /// Builds the facts from a URL, collapsing the path and refusing anything that is not one.
    ///
    /// The `host` is the authority with no credentials and no port — a `user:pass@` in a URL is a
    /// password, and it has appeared in real code.
    init(
        method: String,
        url: URL?,
        status: Int,
        durationMillis: Int64,
        requestBytes: Int64,
        responseBytes: Int64,
        failure: String
    ) {
        let components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        self.method = Self.method(method)
        self.host = Self.host(components?.host)
        self.path = PathTemplate.of(components?.percentEncodedPath ?? "")
        self.status = (100...599).contains(status) ? status : 0
        self.durationMillis = max(0, durationMillis)
        self.requestBytes = max(0, requestBytes)
        self.responseBytes = max(0, responseBytes)
        self.failure = failure
    }

    /// Uppercased, letters only. A method is a fixed vocabulary; anything else came from a caller
    /// passing something that is not one, and `LowCardinality(String)` on the server is a promise
    /// about how few distinct values arrive.
    private static func method(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard !trimmed.isEmpty, trimmed.count <= 12, trimmed.allSatisfy(\.isLetter) else { return "" }
        return trimmed
    }

    private static func host(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty, raw.count <= 253 else { return "" }
        // `URLComponents.host` already excludes the port and the credentials. Re-checked rather
        // than trusted, because this is the field where being wrong publishes a password.
        guard !raw.contains("@"), !raw.contains(":") else { return "" }
        return raw.lowercased()
    }
}

/// An API call on the session's timeline — a breadcrumb of type `api`, field for field what the
/// Android SDK sends, riding the batch the taps, navigations and errors already ride.
///
/// A breadcrumb for the reasons `ErrorEvent` lists: the spool, the retry and the ordering exist
/// already, and the spool never evicts breadcrumbs. The `sequence` matters more here than anywhere
/// else — the server's natural key includes it, so two requests that finish in the same millisecond
/// with the same sequence are one row, and a burst is exactly when this happens.
struct ApiCallEvent: Breadcrumb {
    let sequence: Int
    let call: ApiCall
    let timestampMillis: Int64
    let userId: String
    let userType: UserType
    let appVersion: String
    /// Which screen was waiting on it, which is most of the value: "checkout is slow" is a product
    /// answer, "POST /v1/orders is slow" is only half of one.
    let screen: String?
    let screenId: String?

    var breadcrumb: [String: Any] {
        var crumb: [String: Any] = [
            "type": "api",
            "timestamp": timestampMillis,
            "sequence": sequence,
            "user_id": userId,
            "user_type": userType.rawValue,
            "app_version": appVersion,
            // Latency at the top level, beside the timestamp, because that is where the ingest
            // reads it for every crumb type — not inside `data`.
            "duration": call.durationMillis,
            "data": [
                "method": call.method,
                "host": call.host,
                "path": call.path,
                "status": call.status,
                "request_bytes": call.requestBytes,
                "response_bytes": call.responseBytes,
                "error": call.failure,
            ] as [String: Any],
        ]
        // The names the ingest parser already reads off any crumb.
        if let screen { crumb["screen"] = screen }
        if let screenId { crumb["screen_id"] = screenId }
        return crumb
    }
}
