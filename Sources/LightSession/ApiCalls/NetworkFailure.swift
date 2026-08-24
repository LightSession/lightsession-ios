import Foundation

/// Why a request failed, as one word from a closed set.
///
/// A word rather than a message, and the distinction is the whole point: `URLError` builds its
/// `localizedDescription` and its `failingURL` out of the request, so an error string carries the
/// URL — query, token and all — into the field a class name was supposed to occupy. The same
/// reasoning as the ingest's length cap on this column, one layer earlier.
///
/// The vocabulary is the Android SDK's, so a query can group both platforms: `timeout`, `dns`,
/// `tls`, `connect`, `connection_lost`, `cancelled`, `io`.
enum NetworkFailure {

    /// Every word this type may produce. The server's column is `LowCardinality(String)` on the
    /// strength of this set being closed.
    static let vocabulary: Set<String> = [
        "timeout", "dns", "tls", "connect", "connection_lost", "cancelled", "offline", "io",
    ]

    /// A class a *caller* chose, checked against the vocabulary.
    ///
    /// Needed because one caller does not have an `Error` to read: a request issued in JavaScript
    /// crosses the bridge as a word. Trusting that word would let the closed set be widened from
    /// outside — a typo, or a client on a newer version than the server, and the column that was
    /// promised low cardinality grows a value nobody planned. Anything unrecognised becomes `io`,
    /// which is the honest reading of "it failed and we cannot say how".
    static func validated(_ raw: String) -> String {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if word.isEmpty { return "" }
        return vocabulary.contains(word) ? word : "io"
    }

    /// The class for an error, or `""` when there was none.
    static func of(_ error: Error?) -> String {
        guard let error else { return "" }
        guard let code = urlErrorCode(error) else {
            // Not a transport failure: something the app's own client threw — a decode, a
            // validation. The kind is not knowable from here without reading the type's name, and a
            // type name is app code we would be publishing.
            return "io"
        }
        switch code {
        case .timedOut:
            return "timeout"

        case .cannotFindHost, .dnsLookupFailed:
            return "dns"

        case .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .serverCertificateUntrusted,
             .clientCertificateRejected,
             .clientCertificateRequired,
             .appTransportSecurityRequiresSecureConnection:
            return "tls"

        case .cannotConnectToHost:
            return "connect"

        case .networkConnectionLost:
            return "connection_lost"

        case .cancelled:
            return "cancelled"

        case .notConnectedToInternet, .internationalRoamingOff, .callIsActive, .dataNotAllowed:
            // Its own class, and deliberately not folded into one of the above. The device had no
            // network at all — nothing about the endpoint failed, so counting it against the
            // endpoint's failure rate would be a false accusation.
            //
            // Android reports this same condition as `dns`, because that is the exception its
            // platform raises with the radio off. The divergence is real and this side is the one
            // to keep: aligning means teaching Android to check connectivity, not blurring a
            // distinction here.
            return "offline"

        default:
            return "io"
        }
    }

    /// The `URLError.Code` behind an error, following `NSUnderlyingError` once.
    ///
    /// The hop exists because a client that wraps its failures — most of them do; the app this was
    /// measured against wraps every one in an `ApiError.network(underlying:)` — hands us an enum
    /// whose cause is the real transport error. Without the hop every timeout in such an app
    /// reports `io`, which is the same as reporting nothing.
    private static func urlErrorCode(_ error: Error) -> URLError.Code? {
        if let urlError = error as? URLError { return urlError.code }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain { return URLError.Code(rawValue: nsError.code) }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            if let urlError = underlying as? URLError { return urlError.code }
            let nested = underlying as NSError
            if nested.domain == NSURLErrorDomain { return URLError.Code(rawValue: nested.code) }
        }
        return nil
    }
}
