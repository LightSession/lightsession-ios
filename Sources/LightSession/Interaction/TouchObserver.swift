#if canImport(UIKit)
import UIKit

/// Watches every touch in a window without being able to affect one.
///
/// This is the piece that had to be designed rather than ported. Android reads `MotionEvent` by wrapping
/// `Window.Callback`, and getting that wrong is not a missing capture: the delegation to the host is the
/// last line of the method, so a thrown exception both crashes the app *and* swallows the touch. That bug
/// existed, and presented as an unresponsive screen a moment before the crash.
///
/// iOS's equivalent entry point is `UIWindow.sendEvent(_:)`, and swizzling it would reproduce exactly that
/// risk — every touch in the app passing through SDK code that must not fail and must not forget to call
/// through. So it is not swizzled.
///
/// Instead: a `UIGestureRecognizer` subclass that **never recognises anything**. It stays in `.possible`
/// and its touch callbacks are pure observation. UIKit's own contract does the safety work:
///
///  * `cancelsTouchesInView = false` — the views underneath receive every touch regardless.
///  * `delaysTouchesBegan` and `delaysTouchesEnded` false — nothing is held back waiting on us.
///  * never transitioning to `.began` — the recognizer cannot win a conflict against the app's own
///    recognizers, because it never enters one.
///
/// The failure mode of a bug in here is therefore a missing interaction, not a frozen app. That is the
/// trade being made, and it is the right way round.
final class TouchObserver: NSObject {

    /// Called with each finished gesture, on the main thread.
    var onGesture: ((Gesture) -> Void)?

    /// Whether a gesture is worth recording at all right now.
    var isEnabled: () -> Bool = { true }

    /// Points to pixels. The wire format is pixels because captures are.
    private var scale: Double = 1
    private var recorder = GestureRecorder()
    private weak var attachedWindow: UIWindow?
    private lazy var recognizer: PassiveTouchRecognizer = {
        let recognizer = PassiveTouchRecognizer(target: self, action: #selector(recognizerFired))
        recognizer.observer = self
        return recognizer
    }()

    /// Attaches to a window, moving from any previous one.
    ///
    /// Idempotent for the same window, because this is called on every screen change: a window that
    /// accumulated one recognizer per screen would report each touch as many times as the app has
    /// navigated.
    func attach(to window: UIWindow) {
        assert(Thread.isMainThread, "gesture recognizers are main-thread only")
        guard attachedWindow !== window else { return }
        if let previous = attachedWindow {
            previous.removeGestureRecognizer(recognizer)
        }
        scale = Double(window.screen.scale)
        window.addGestureRecognizer(recognizer)
        attachedWindow = window
        LightSessionLog.debug("watching touches in this window")
    }

    func detach() {
        attachedWindow?.removeGestureRecognizer(recognizer)
        attachedWindow = nil
        recorder.cancel()
    }

    // MARK: - Touch handling

    fileprivate func began(_ touches: Set<UITouch>) {
        guard isEnabled() else { return }
        guard let point = pixelPoint(from: touches) else { return }
        recorder.begin(at: point)
    }

    fileprivate func moved(_ touches: Set<UITouch>) {
        guard let point = pixelPoint(from: touches) else { return }
        if isEnabled() {
            recorder.move(to: point)
        } else if recorder.isTracking {
            // Recording went off mid-gesture. The points so far are dropped rather than left in place,
            // where they would be sent as the beginning of whatever gesture happened next.
            recorder.cancel()
        }
    }

    fileprivate func ended(_ touches: Set<UITouch>) {
        guard let point = pixelPoint(from: touches) else { return }
        guard let gesture = recorder.end(at: point), isEnabled() else { return }
        onGesture?(gesture)
    }

    fileprivate func cancelled() {
        recorder.cancel()
    }

    /// The first touch's position, in device pixels of the attached window.
    ///
    /// One finger. A pinch or a two-finger scroll reports whichever touch the set yields first, which is
    /// arbitrary — recorded here as a known simplification rather than pretended away. A heatmap of
    /// multi-touch gestures is not what the feature is for, and the alternative is a path that jumps
    /// between fingers, which is worse than one finger's path.
    private func pixelPoint(from touches: Set<UITouch>) -> TouchPoint? {
        guard let touch = touches.first, let window = attachedWindow else { return nil }
        let location = touch.location(in: window)
        return TouchPoint(
            x: location.x * scale,
            y: location.y * scale,
            timestampMillis: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }

    /// Never called: the recognizer never recognises. Present because `UIGestureRecognizer` requires a
    /// target and action, and a nil action would mean it is never added to the responder chain properly.
    @objc private func recognizerFired() {}
}

/// A recognizer that observes and never wins.
///
/// It deliberately does not call `super` for the touch methods and never sets `state`, so it stays in
/// `.possible` for the life of every touch sequence and is reset by UIKit at the end. Anything that made it
/// `.began` would let it cancel touches in the views beneath, which is the one thing this must not do.
private final class PassiveTouchRecognizer: UIGestureRecognizer {
    weak var observer: TouchObserver?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        observe { observer?.began(touches) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        observe { observer?.moved(touches) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        observe { observer?.ended(touches) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        observe { observer?.cancelled() }
    }

    /// Runs the SDK's own work where a failure in it cannot reach the app.
    ///
    /// Swift cannot catch an `NSException` and there is nothing here that throws a Swift error, so this is
    /// not a `try`. What it is, is the place to keep that reasoning: the body touches only this SDK's
    /// state, does no parsing of untrusted values, and performs no arithmetic that can trap. Android's
    /// equivalent needed a real catch because it built JSON inline, and `JSONObject.put` throws on a NaN
    /// coordinate — which a touch event can carry.
    private func observe(_ body: () -> Void) {
        body()
    }
}
#endif
