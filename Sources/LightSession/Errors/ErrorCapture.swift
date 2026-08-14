import Foundation

/// Captures uncaught `NSException`s — by installing itself, once, and never owning the crash.
///
/// ## The discipline
///
/// An SDK swallowing its host's crashes is worse than one that lets them through. So:
///
///  * The previous handler is **always** invoked, with the **original** exception, after ours ran —
///    the runtime's own path (the crash log, the abort) and any reporter installed before this SDK
///    behave as if it were absent. This SDK adds an observer, not an owner. Installation reads
///    whatever handler is registered *at that moment* and chains to it, so it is happy anywhere in
///    the chain; whoever installs last runs first.
///  * The capture is one-shot. A second thread crashing while the first crash is being written —
///    or the capture path raising into itself — falls straight through to the previous handler
///    rather than re-entering. Apple documents nothing about this handler's threading or
///    reentrancy, which is a reason for the latch, not against it.
///
/// ## What this does not catch, stated rather than implied
///
/// Only Objective-C exceptions reach `NSSetUncaughtExceptionHandler`. A Swift `fatalError`, a force
/// unwrap of nil, an array out of bounds — those trap straight to a signal and die without touching
/// this. Catching them means signal and Mach-exception handlers, which are the half of crash
/// reporting where a bug *creates* crashes; that half is deliberately not here until it can be done
/// with the care it demands. What this catches is the ObjC layer the app stands on: UIKit
/// assertions, KVC on a missing key, unrecognized selectors — which in practice is most of what an
/// iOS app dies of above the runtime.
///
/// ## What a crash costs
///
/// Nothing here talks to the network. The capture closure builds the crumb and writes it to the
/// spool synchronously on the crashing thread — one file write and one rename, the same write every
/// batch already trusts — and the upload happens on the next launch, when the drain finds it.
/// Uploading during a crash would be theatre: the process dies when the handler returns.
enum ErrorCapture {

    private static let lock = NSLock()
    private static var installed = false
    /// One capture per process death. See the type doc.
    private static var crashed = false

    /// What runs on the one capture. Injected so the handler stays a latch and a chain,
    /// walkable by a test.
    private static var capture: ((NSException) -> Void)?

    /// The handler that was installed before this one, wrapped so a test can stand one in.
    private static var previous: ((NSException) -> Void)?

    /// Starts capturing. Idempotent; the second caller updates the capture and changes nothing else.
    static func install(capture: @escaping (NSException) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        Self.capture = capture
        guard !installed else { return }
        installed = true

        // Only when nothing holds the slot: in production that is always, because `previous` starts
        // nil and this runs once. A test that stubbed a previous handler keeps it — the test host's
        // own global handler (XCTest installs one on some platforms) must not displace the stub, or
        // the chaining assertions measure the host instead of the chain.
        if previous == nil, let existing = NSGetUncaughtExceptionHandler() {
            previous = { exception in existing(exception) }
        }
        NSSetUncaughtExceptionHandler { exception in
            ErrorCapture.handle(exception)
        }
        LightSessionLog.debug(
            "uncaught exception handler installed"
                + (previous == nil ? "" : ", chaining to the one already there")
        )
    }

    /// The handler body, separate from the registration so the invariants are testable — they only
    /// ever run while the process is dying, which is the worst possible place to discover them
    /// wrong.
    static func handle(_ exception: NSException) {
        let first: Bool = {
            lock.lock()
            defer { lock.unlock() }
            if crashed { return false }
            crashed = true
            return true
        }()

        if first {
            capture?(exception)
        }
        // The original exception, not anything of ours: the runtime's crash log and every reporter
        // behind us must see the crash the app actually had.
        previous?(exception)
    }

    /// For tests. Production installs once and never looks back.
    static func resetForTest(previous stub: ((NSException) -> Void)? = nil) {
        lock.lock()
        defer { lock.unlock() }
        crashed = false
        capture = nil
        previous = stub
    }
}
