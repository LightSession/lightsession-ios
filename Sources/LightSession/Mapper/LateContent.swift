#if canImport(UIKit)
import UIKit

/// Fires once when a screen's content changes after its wireframe was already taken.
///
/// ## The screen this exists for
///
/// A screen that loads is two screens: the spinner it shows on arrival and the content it becomes
/// when the data lands. The wireframe is taken from the first one, and the settle detector is
/// *right* to allow it — an indeterminate spinner animates without adding views or moving frames, so
/// the content signature holds still and the screen genuinely looks finished. The Android SDK
/// measured it on a production screen: settled 139 ms after navigation, 37 rectangles sent with the
/// spinner up against the 81 the loaded screen carries. No amount of waiting fixes that honestly;
/// the screenshot path's flat quiet-period is a guess about every app's network encoded as a
/// constant in this SDK.
///
/// ## Why this polls, when Android does not
///
/// On Android the data landing announces itself: content cannot appear on a Compose screen without a
/// state write, every state write is a snapshot apply, and the runtime exposes exactly that event —
/// so the watch there costs one volatile read until the moment worth recapturing at. UIKit has no
/// such event. Content arriving here ends as views added or frames moved, which is precisely what
/// [ContentSignature] measures — so the honest equivalent is to re-ask the signature on a cadence.
/// One hertz, because the replay recorder already walks the same hierarchy once a second for frames:
/// this watch never makes the SDK's ambient cost more than double what it already pays, and a second
/// of latency on a map upgrade is invisible next to the network wait that caused the spinner.
///
/// The expensive part — recapture, recolour, resend — is not the poll's to spend. The signature is
/// the tripwire; the caller decides on the budget.
///
/// ## What ends the watch
///
/// Events, and one of them is its own: a fresh `arm` replaces the previous watch (a screen can only
/// be waiting for one arrival at a time), `cancel` disarms it from the same touch and navigation
/// hooks that already cancel a pending screenshot, the app going to background disarms it here —
/// there is nothing worth photographing back there, and the poll should not outlive the screen it
/// watches — and a signature closure returning `nil` means the window is gone, which disarms too.
final class LateContentWatch {

    /// One second, with tolerance: the tick is a tripwire, not a deadline, and the system saves
    /// power coalescing timers that admit they do not care exactly when they fire. Injectable so a
    /// test is not built out of multi-second sleeps; production takes the default.
    private let cadence: TimeInterval

    private var timer: Timer?
    private var baseline: ContentSignature?
    private var signature: (() -> ContentSignature?)?
    private var onChanged: (() -> Void)?
    private var backgroundObserver: NSObjectProtocol?

    init(cadence: TimeInterval = 1.0) {
        self.cadence = cadence
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.cancel()
        }
    }

    deinit {
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
        timer?.invalidate()
    }

    /// Arms for exactly one change. Replaces any previous arm.
    ///
    /// - Parameters:
    ///   - baseline: the signature the screen settled at when its wireframe was taken.
    ///   - signature: re-reads the current signature; `nil` ends the watch (the window is gone).
    ///   - onChanged: called once, on the main thread, when the signature stops matching.
    func arm(
        baseline: ContentSignature,
        signature: @escaping () -> ContentSignature?,
        onChanged: @escaping () -> Void
    ) {
        assert(Thread.isMainThread, "the view hierarchy may only be read on the main thread")
        cancel()
        self.baseline = baseline
        self.signature = signature
        self.onChanged = onChanged

        let timer = Timer(timeInterval: cadence, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = cadence / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Disarms without firing. Idempotent; called from the touch and navigation hooks.
    func cancel() {
        timer?.invalidate()
        timer = nil
        baseline = nil
        signature = nil
        onChanged = nil
    }

    private func tick() {
        guard let signature, let baseline else {
            cancel()
            return
        }
        guard let current = signature() else {
            cancel()
            return
        }
        guard current != baseline else { return }

        // Claim-then-run: the watch is one-shot, and the callback re-arms through the caller if it
        // decides the change was worth nothing. Cancelling before invoking means a callback that
        // navigates — which cancels this watch by another path — finds it already disarmed.
        let fire = onChanged
        cancel()
        fire?()
    }
}
#endif
