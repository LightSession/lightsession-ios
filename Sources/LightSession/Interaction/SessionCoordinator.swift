#if canImport(UIKit)
import UIKit

/// The one answer to "which session is this".
///
/// Extracted the moment replay arrived, because two recorders each owning a session is two sessions: the
/// touches would be filed under one id and the frames under another, and the product would show a replay
/// with no interactions beside a session with no video. Nothing in either payload says they belong together
/// except this string.
///
/// Rotation lives here for the same reason. A gap in activity has to end *both* streams at once, and it has
/// to flush what is buffered first — a batch that straddles two sessions is filed entirely under the newer
/// one, which silently moves events backwards in time.
final class SessionCoordinator {

    private var identity: SessionIdentity
    /// Called just before the id changes, so buffered work goes out under the old one.
    private var beforeRotation: [() -> Void] = []
    /// When the app went to the background, if it is there now.
    private var backgroundedAtMillis: Int64?

    init(anonymousId: String, idleTimeoutMillis: Int64) {
        identity = SessionIdentity(
            sessionId: UUID().uuidString,
            anonymousId: anonymousId,
            startedAtMillis: Self.nowMillis(),
            idleTimeoutMillis: idleTimeoutMillis
        )
    }

    var sessionId: String { identity.sessionId }
    var userId: String { identity.reportedUserId }
    var userType: UserType { identity.userType }

    /// Registers work to run before the session id changes.
    func onRotation(_ flush: @escaping () -> Void) {
        beforeRotation.append(flush)
    }

    /// Marks activity and rotates the session if it had gone stale.
    ///
    /// Called by anything that counts as the person being present: a touch, a frame that differs from the
    /// last, a screen change. Not called by a repeated-frame signal — a screen nobody is touching should be
    /// allowed to go idle, which is the whole point of the server's timeout.
    @discardableResult
    func markActive() -> String {
        let now = Self.nowMillis()
        let previous = identity.sessionId
        let result = identity.touch(nowMillis: now) { UUID().uuidString }
        if result.rotated {
            // Flushed with the *old* id still in hand: the callbacks read `sessionId`, so they have to run
            // before it changes. That ordering is the reason this is not just a computed property.
            identity = restore(identity, to: previous)
            for flush in beforeRotation { flush() }
            identity = SessionIdentity(
                sessionId: result.id,
                anonymousId: identity.anonymousId,
                startedAtMillis: now,
                idleTimeoutMillis: SessionIdentity.defaultIdleTimeoutMillis
            )
            if let userId = userIdOf(previousIdentity: identity) { identity.identify(userId: userId) }
            LightSessionLog.info("new session \(result.id) after an idle gap")
        }
        return identity.sessionId
    }

    func identify(userId: String) {
        identity.identify(userId: userId)
    }

    func reset() {
        // Flushed first: what is buffered belongs to the person who was signed in, and relabelling it with
        // the next person's id is wrong in the direction that matters.
        for flush in beforeRotation { flush() }
        identity.reset()
    }

    /// Records that the app left the foreground.
    func markBackgrounded() {
        backgroundedAtMillis = Self.nowMillis()
    }

    /// Called on return to the foreground. Rotates if the app was away longer than a session survives.
    func markForegrounded() {
        guard let away = backgroundedAtMillis else { return }
        backgroundedAtMillis = nil
        // Time in the background counts as idle time — the server's reaper does not care why nothing
        // arrived. Without this, a phone left in a pocket for an hour resumes into a session the server
        // sealed fifty-nine minutes ago.
        let idleFor = Self.nowMillis() - away
        if idleFor >= SessionIdentity.defaultIdleTimeoutMillis {
            markActive()
        }
    }

    static func nowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    // MARK: - Internals

    /// Puts the id back so the flush callbacks see the session their data belongs to.
    ///
    /// `SessionIdentity.touch` rotates in place, which is the right shape for the pure type and the wrong
    /// one for this ordering. Rebuilt rather than made mutable-in-reverse: two ways to change one id is how
    /// they come to disagree.
    private func restore(_ current: SessionIdentity, to sessionId: String) -> SessionIdentity {
        var restored = SessionIdentity(
            sessionId: sessionId,
            anonymousId: current.anonymousId,
            startedAtMillis: current.lastActivityMillis,
            idleTimeoutMillis: SessionIdentity.defaultIdleTimeoutMillis
        )
        if let userId = userIdOf(previousIdentity: current) { restored.identify(userId: userId) }
        return restored
    }

    private func userIdOf(previousIdentity: SessionIdentity) -> String? {
        previousIdentity.userType == .identified ? previousIdentity.reportedUserId : nil
    }
}
#endif
