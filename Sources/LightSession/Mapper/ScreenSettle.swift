#if canImport(UIKit)
import UIKit

/// Waits for a screen to stop changing before it is captured.
///
/// This is the single most expensive lesson from the Android SDK, so it is worth stating plainly:
/// **`viewDidAppear` is not when the screen is finished.** A UIKit controller appears before its
/// asynchronous content lands; a SwiftUI screen names itself during `body` evaluation, before layout
/// has happened at all. Capturing on the callback produced a wireframe of an empty screen — and on
/// Android the first attempt at fixing it settled 4 ms earlier than the broken version and produced a
/// byte-identical blank image. That near-miss was caught by comparing file sizes, not by looking, which
/// is why the stop condition here is a content count rather than "does the hierarchy exist".
///
/// The rule: sample the number of *drawing* views each frame, and settle once that number has held
/// steady for a few consecutive frames. A window is never empty — it always has a root view and a
/// safe-area container — so anything weaker than "content, unchanged" is always immediately true.
final class ScreenSettle {

    /// Consecutive frames with the same content count before the screen is called settled.
    ///
    /// Three at 60 Hz is about 50 ms. Two would fire between a table view's first cell and its second.
    private let stableFrames = 3

    /// Given up on after this long, and captured anyway.
    ///
    /// A screen that genuinely never stops changing — a spinner, an animation, a video — would
    /// otherwise never be captured at all, and no capture is worse than one taken mid-animation.
    private let timeout: TimeInterval = 2.0

    private var displayLink: CADisplayLink?
    private var startedAt: CFTimeInterval = 0
    private var lastCount = -1
    private var stableFor = 0
    private var contentCount: (() -> Int)?
    private var completion: ((Bool) -> Void)?

    /// Calls `onSettled` once, on the main thread, with whether it settled or timed out.
    ///
    /// Starting a second wait cancels the first: a screen that is replaced before it settled is a
    /// screen nobody saw, and capturing it would attribute the new screen's content to the old name.
    func await(contentCount: @escaping () -> Int, onSettled: @escaping (Bool) -> Void) {
        assert(Thread.isMainThread, "the view hierarchy may only be read on the main thread")
        cancel()
        self.contentCount = contentCount
        self.completion = onSettled
        self.lastCount = -1
        self.stableFor = 0
        self.startedAt = CACurrentMediaTime()

        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func cancel() {
        displayLink?.invalidate()
        displayLink = nil
        contentCount = nil
        completion = nil
    }

    @objc private func tick() {
        guard let contentCount, let completion else {
            cancel()
            return
        }

        let count = contentCount()
        if count == lastCount {
            stableFor += 1
        } else {
            lastCount = count
            stableFor = 0
        }

        // Content, and it has stopped moving. Both halves are required: a stable count of zero is a
        // window that has not laid out yet, not a screen that is ready.
        if count > 0 && stableFor >= stableFrames {
            finish(settled: true, completion)
            return
        }

        if CACurrentMediaTime() - startedAt >= timeout {
            finish(settled: false, completion)
        }
    }

    private func finish(settled: Bool, _ completion: @escaping (Bool) -> Void) {
        cancel()
        completion(settled)
    }
}
#endif
