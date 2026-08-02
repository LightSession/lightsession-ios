import Foundation

/// When a real screenshot of a screen may be taken.
///
/// The wireframe goes out as soon as the hierarchy stops changing. The screenshot waits, and the wait is what
/// gives it its worth: animations finish, images load, network content arrives. Anything captured before that is
/// a screen mid-build rather than the screen.
///
/// This was measured wrong before it was written. iOS sent both at the same moment, so a screenshot could show
/// an empty `UIImageView` where a photo was about to appear — the settle detector counts *views*, and an image
/// arriving later changes pixels without changing the count. Android has always waited; the two platforms
/// disagreed about what a screenshot of a screen even is.
public enum ScreenshotTiming {

    /// How long a screen must sit untouched before it is captured for real.
    ///
    /// Android's constant, to the millisecond, because the two platforms fill the same slot in the same product
    /// and a screenshot taken at a different moment is a different picture of the same screen. Long enough for a
    /// network round trip; short enough that someone reading the screen is still on it.
    public static let quietPeriod: TimeInterval = 5.5

    /// Why a scheduled screenshot did not happen.
    public enum Cancellation: Equatable, Sendable {
        /// The transition out is being driven by a finger.
        ///
        /// Only the departure capture can meet this one. A swipe-back is a screen sliding under a
        /// finger, and a capture taken then is a smear of two screens — worse than no capture, because
        /// it is stored as *the* picture of the screen. Skipped rather than retried: if the gesture is
        /// cancelled the screen stays, still owed, and the next departure tries again.
        case interactiveTransition
        /// The person touched the screen.
        ///
        /// **Cancelled, not postponed**, and that is the decision worth being exact about — the obvious reading
        /// of "untouched for five seconds" is a timer that restarts, and Android does not restart it. If they
        /// interacted, the screen is no longer the one they arrived at, so a later capture would record a state
        /// nobody navigated to. The next visit schedules a fresh one.
        case touched
        /// They left for another screen.
        case navigatedAway
        /// Recording was turned off in the seconds between scheduling and firing.
        case recordingStopped
    }

    /// Whether a screenshot scheduled for `screen` should still be taken.
    ///
    /// Every reason is checked at fire time rather than trusted from schedule time, because several seconds pass
    /// in between — which is the whole point of the delay and also the whole risk of it.
    public static func decide(
        scheduledFor screen: String,
        currentScreen: String?,
        wasTouched: Bool,
        isRecording: Bool
    ) -> Cancellation? {
        if !isRecording { return .recordingStopped }
        if wasTouched { return .touched }
        if currentScreen != screen { return .navigatedAway }
        return nil
    }

    /// Whether a screen still owed its screenshot may be captured at the moment it leaves.
    ///
    /// The quiet period has a blind spot, and it is not a corner case — it is the most-touched screens
    /// in the app. A login form is touched from arrival to departure: every keystroke cancels the
    /// capture, and then the person leaves, so the screen everyone's session starts on is the one
    /// screen with no real picture. Measured on a real app: its `Login` never got a screenshot in any
    /// session, ever.
    ///
    /// Departure closes it, because leaving is itself the quiet moment the rule was waiting for: the
    /// finger is up, the layout is final, and nothing the person does can change the screen again. The
    /// touch rule's own reasoning — "if they interacted, the screen is no longer the one they arrived
    /// at" — is an argument *for* capturing now: what they turned it into is the screen as they used
    /// it, and it is the last chance to record that.
    ///
    /// `wasTouched` is deliberately not a parameter. The touched case is not tolerated here, it is the
    /// case this exists for.
    public static func decideOnDeparture(
        owedFor screen: String,
        currentScreen: String?,
        isRecording: Bool,
        isInteractive: Bool
    ) -> Cancellation? {
        if !isRecording { return .recordingStopped }
        if isInteractive { return .interactiveTransition }
        // A stray disappearance arriving after the next screen was reported. What is owed belongs to a
        // screen no longer current, and `capture` for the new one has already cancelled it.
        if currentScreen != screen { return .navigatedAway }
        return nil
    }
}
