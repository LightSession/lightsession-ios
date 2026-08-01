#if canImport(UIKit)
import UIKit

/// Uploads what is on disk, oldest first, deleting each entry only once the server has taken it.
///
/// The one place that talks to the network for sessions. Both recorders write to the spool and neither uploads,
/// which is what makes a failure survivable: recording is done when the file is written, and the request
/// becomes somebody else's problem.
///
/// Two rules are load-bearing:
///
///  * **Single-flight.** The ticker, a backgrounding and a rotation can all ask for a drain, and three at once
///    would upload the same entries three times.
///  * **Stop on the first failure.** A network error means the next entry would fail too, and hammering a dead
///    connection wastes the battery this SDK exists to protect. The entry stays on disk and the next tick tries
///    again.
final class SpoolDrain {

    private let spool: BatchSpool
    private let breadcrumbs: BreadcrumbSender
    private let frames: FrameSender
    /// Both of these are read and written on the main queue only — see [onMain].
    private var isDraining = false
    private var waiting: [() -> Void] = []
    private var timer: Timer?

    init(spool: BatchSpool, breadcrumbs: BreadcrumbSender, frames: FrameSender) {
        self.spool = spool
        self.breadcrumbs = breadcrumbs
        self.frames = frames
    }

    func start() {
        // Every tick also retries what is still on disk, so a batch that failed during a dead spot goes out as
        // soon as there is signal again rather than waiting for new data to push it.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.drain()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        drain()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Uploads what is on disk, and says when there is nothing left to do.
    ///
    /// - Parameter completion: called on the main queue once the spool is empty or an upload failed — which
    ///   are the two ways this stops. Asked for by the backgrounding path, which holds the process alive until
    ///   then; everything else fires and forgets. A caller who asks while a drain is already running is added
    ///   to the same answer rather than starting a second one.
    func drain(completion: (() -> Void)? = nil) {
        onMain {
            if let completion { self.waiting.append(completion) }
            guard !self.isDraining else { return }
            let pending = self.spool.pending()
            guard !pending.isEmpty else { return self.settle() }
            self.isDraining = true
            self.upload(pending, at: 0)
        }
    }

    /// Recursive rather than a loop because each upload is asynchronous, and the next must not start until this
    /// one has answered — otherwise "stop on the first failure" cannot be honoured.
    private func upload(_ entries: [BatchSpool.Entry], at index: Int) {
        guard index < entries.count else {
            // A pass works from the list it started with, so anything written while it ran — the batch a
            // backgrounding just flushed, most of all — is not in `entries`. Another pass picks it up, and this
            // terminates because a pass that gets this far has emptied what it was given.
            let more = spool.pending()
            guard more.isEmpty else { return upload(more, at: 0) }
            isDraining = false
            settle()
            return
        }
        let entry = entries[index]

        let finish: (Result<Void, Error>) -> Void = { [weak self] result in
            // Hopped to the main queue because the sender answers on the session's own queue, and the
            // bookkeeping below — and the caller waiting on `completion` — must not be touched from two
            // threads at once.
            self?.onMain {
                guard let self else { return }
                switch result {
                case .success:
                    // Deleted only now. This is what "the server has it" means, and doing it before the answer is
                    // how a batch is lost to a request that never landed.
                    self.spool.remove(entry)
                    self.upload(entries, at: index + 1)
                case .failure(let error):
                    LightSessionLog.debug(
                        "\(entry.kind.rawValue) batch \(entry.sequence) will be retried: \(error.localizedDescription)"
                    )
                    self.isDraining = false
                    self.settle()
                }
            }
        }

        switch entry.kind {
        case .breadcrumbs:
            guard let fields = spool.fields(of: entry) else {
                // Unreadable rather than unsent: keeping it would mean retrying it for ever.
                LightSessionLog.error("breadcrumb batch \(entry.sequence) is unreadable; discarded")
                spool.remove(entry)
                upload(entries, at: index + 1)
                return
            }
            breadcrumbs.send(fields: fields, completion: finish)

        case .frames:
            guard let payload = spool.frames(of: entry), !payload.frames.isEmpty else {
                LightSessionLog.error("frame batch \(entry.sequence) is unreadable; discarded")
                spool.remove(entry)
                upload(entries, at: index + 1)
                return
            }
            frames.send(metadata: payload.metadata, frames: payload.frames, completion: finish)
        }
    }

    /// Tells everyone who asked that there is nothing more this can do right now.
    private func settle() {
        let callbacks = waiting
        waiting = []
        for callback in callbacks { callback() }
    }

    /// Runs on the main queue, now if that is already where we are.
    ///
    /// `async` unconditionally would turn `drain()` from the flush path into something that happens *after* the
    /// caller returns, which is the one ordering the backgrounding path cannot have.
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    deinit {
        timer?.invalidate()
    }
}

extension BatchSpool {
    /// Where the spool lives.
    ///
    /// `Library/Caches`, and the choice matters both ways. Not `Documents` or `Application Support`: those are
    /// backed up, and a user's iCloud backup is no place for telemetry about them. Caches can be evicted by the
    /// system under storage pressure, which is the right trade — losing a queued batch is better than the OS
    /// deciding the app is the problem.
    static func defaultRoot() throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return caches.appendingPathComponent("com.lightsession/spool", isDirectory: true)
    }
}
#endif
