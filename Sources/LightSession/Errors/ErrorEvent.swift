import Foundation

/// What an error looked like where it was caught, before the recorder knows anything about it.
///
/// Split from [ErrorEvent] because the two halves are captured at different moments by different
/// code: the stack, the thread and the attributes exist only at the capture site, while the
/// sequence, the identity and the screen belong to the recorder — the handled path hops to the main
/// thread between the two, and anything built after the hop would describe the wrong thread.
struct ErrorDetails {
    let handled: Bool
    let threadName: String
    let threadId: UInt
    let exceptions: [[String: Any]]
    let attributes: [String: Any]
    let timestampMillis: Int64

    /// The thread the capture is running on, named the way the wire expects.
    static func currentThread() -> (name: String, id: UInt) {
        let id = UInt(pthread_mach_thread_np(pthread_self()))
        if Thread.isMainThread { return ("main", id) }
        let name = Thread.current.name ?? ""
        return (name.isEmpty ? "background" : name, id)
    }
}

/// An error on the session's timeline — a breadcrumb of type `error`, field for field what the
/// Android SDK sends, riding the batch the taps and screen changes already ride.
///
/// A breadcrumb rather than its own upload for the reasons the Android commit lists: the spool, the
/// retry and the ordering already exist, and the spool never evicts breadcrumbs — durability is
/// inherited, not built. The ingest needs no release either: unknown crumb types are preserved
/// verbatim and land queryable.
public struct ErrorEvent: Breadcrumb {
    public let sequence: Int
    let details: ErrorDetails
    let userId: String
    let userType: UserType
    let appVersion: String
    /// Where in the app it broke, which is the product: not what broke but where.
    let screen: String?
    let screenId: String?

    public var breadcrumb: [String: Any] {
        var crumb: [String: Any] = [
            "type": "error",
            "timestamp": details.timestampMillis,
            "sequence": sequence,
            "user_id": userId,
            "user_type": userType.rawValue,
            "app_version": appVersion,
            "handled": details.handled,
            "thread": details.threadName,
            "thread_id": details.threadId,
            "exceptions": details.exceptions,
        ]
        // The names the ingest parser already reads off any crumb, so an error is attributed to its
        // screen even by a server that has never heard of the type.
        if let screen { crumb["screen"] = screen }
        if let screenId { crumb["screen_id"] = screenId }
        let scalars = Self.scalars(details.attributes)
        if !scalars.isEmpty { crumb["attributes"] = scalars }
        return crumb
    }

    /// Attributes, keeping only what JSON can carry.
    ///
    /// Anything else is dropped with a warning rather than stringified: `String(describing:)` on a
    /// domain object produces `MyApp.User(id: …)` with whatever that type happens to print, which
    /// would be stored, indexed and displayed as if it meant something.
    static func scalars(_ attributes: [String: Any]) -> [String: Any] {
        attributes.compactMapValues { value in
            switch value {
            case is String, is NSNumber, is Bool, is Int, is Double, is Float:
                return value
            default:
                LightSessionLog.info(
                    "error attribute of type \(type(of: value)) dropped; "
                        + "send a string, number or boolean"
                )
                return nil
            }
        }
    }
}
