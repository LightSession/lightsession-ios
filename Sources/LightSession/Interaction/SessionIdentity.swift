import Foundation

/// Which session an event belongs to.
///
/// The iOS SDK had no notion of a session before this: it wrote screens and flows, which are keyed by
/// project and app version and need no session at all. An interaction does — `session_id` is the one field
/// the ingest service refuses a batch without.
///
/// Pure, and told the time rather than reading it, so the rotation rule can be tested by passing clocks
/// instead of by waiting.
public struct SessionIdentity: Sendable {

    /// How long a session survives with nothing happening.
    ///
    /// **Must match the server's `LS_SESSION__IDLE_TIMEOUT_SECS`.** The reaper on the server finalises a
    /// session once it has been idle that long; a client that rotates sooner produces two rows where the
    /// server counted one, and a client that rotates later attaches events to a session that has already
    /// been sealed. Thirty seconds is the server's default.
    public static let defaultIdleTimeoutMillis: Int64 = 30_000

    public private(set) var sessionId: String
    /// The stable per-install id, so a returning user is recognisable across sessions.
    public let anonymousId: String
    public private(set) var userId: String?
    public private(set) var lastActivityMillis: Int64

    private let idleTimeoutMillis: Int64

    public init(
        sessionId: String,
        anonymousId: String,
        startedAtMillis: Int64,
        idleTimeoutMillis: Int64 = SessionIdentity.defaultIdleTimeoutMillis
    ) {
        self.sessionId = sessionId
        self.anonymousId = anonymousId
        self.lastActivityMillis = startedAtMillis
        self.idleTimeoutMillis = idleTimeoutMillis
    }

    /// What the server is told the person is called: their id if they have one, the install's otherwise.
    public var reportedUserId: String { userId ?? anonymousId }
    public var userType: UserType { userId == nil ? .anonymous : .identified }

    /// Records activity, starting a new session first if the old one has gone stale.
    ///
    /// Returns the session id the caller should use, and whether it is new — the caller may want to log a
    /// rotation, and the batch numbering restarts with it.
    @discardableResult
    public mutating func touch(nowMillis: Int64, newSessionId: () -> String) -> (id: String, rotated: Bool) {
        let idleFor = nowMillis - lastActivityMillis
        var rotated = false
        // `>=` rather than `>`: a session idle for exactly the timeout has, by the server's own rule, been
        // reaped. Keeping it would attach events to a row that is already closed.
        if idleFor >= idleTimeoutMillis {
            sessionId = newSessionId()
            rotated = true
        }
        lastActivityMillis = nowMillis
        return (sessionId, rotated)
    }

    /// Attaches a person to everything recorded from now on.
    public mutating func identify(userId: String) {
        self.userId = userId
    }

    /// Forgets the person, keeping the install's own id.
    ///
    /// The anonymous id is deliberately not regenerated: the device is the same device, and a new one
    /// would make one person look like two.
    public mutating func reset() {
        userId = nil
    }
}
