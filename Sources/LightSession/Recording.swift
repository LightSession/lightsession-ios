import Foundation

/// Whether anything is being recorded right now.
///
/// One switch, read by every producer, so "stop recording" means the same thing to the frame loop and to the
/// touch observer. The alternative — a flag per recorder — is two switches that can disagree, and the one that
/// disagrees is the one still recording after someone asked it not to.
///
/// The default is on. An app that installed a recorder and called nothing expects it to record; making the
/// switch opt-in would mean an SDK that looks installed and captures nothing, which is the failure that takes
/// longest to notice.
///
/// Deliberately not `@MainActor`. It is read from the capture timer and written from a bridge call, and a lock
/// for one boolean would cost more than it protects — a read that lands a frame late is a frame, not a fault.
public final class Recording: @unchecked Sendable {

    public static let shared = Recording()

    private let lock = NSLock()
    private var enabled = true

    private init() {}

    public var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    /// Turns recording on. Returns whether this changed anything, so a caller can log a transition rather than
    /// a repeat — `startRecording` called on every screen is a normal thing for an app to do.
    @discardableResult
    public func start() -> Bool {
        set(true)
    }

    @discardableResult
    public func stop() -> Bool {
        set(false)
    }

    private func set(_ value: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard enabled != value else { return false }
        enabled = value
        return true
    }
}
