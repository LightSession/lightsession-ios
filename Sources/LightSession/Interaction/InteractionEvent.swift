import Foundation

/// One interaction, as the ingest service reads it.
///
/// The field names are not a design; they are Android's, and Android's are what the worker parses and what
/// ClickHouse stores. `interaction_type` rather than `type` because a breadcrumb's own `type` is
/// `"interaction"` — Android renames the key while merging, and reproducing that rename is what makes an
/// iOS touch and an Android touch the same row.
public struct InteractionEvent: Breadcrumb, Equatable, Sendable {
    public let gesture: Gesture
    /// The screen the gesture happened on, by name.
    public let screen: String
    /// The capture the heatmap anchors to — the SDK's composite id.
    ///
    /// Optional because a touch can land before the first screen has been captured. Sent when known,
    /// omitted when not, rather than sent as a placeholder: Android learned that the hard way, where a
    /// missing id arrived as the literal string `"null"` and was stored as one.
    public let screenId: String?
    public let sequence: Int
    public let userId: String
    public let userType: UserType
    public let appVersion: String

    public init(
        gesture: Gesture,
        screen: String,
        screenId: String?,
        sequence: Int,
        userId: String,
        userType: UserType,
        appVersion: String
    ) {
        self.gesture = gesture
        self.screen = screen
        self.screenId = screenId
        self.sequence = sequence
        self.userId = userId
        self.userType = userType
        self.appVersion = appVersion
    }

    /// The breadcrumb object, matching what the Android SDK sends field for field.
    public var breadcrumb: [String: Any] {
        var crumb: [String: Any] = [
            "type": "interaction",
            "timestamp": gesture.endMillis,
            "sequence": sequence,
            "user_id": userId,
            "user_type": userType.rawValue,
            "app_version": appVersion,
            "interaction_type": gesture.kind.rawValue,
            "start_time": gesture.startMillis,
            "end_time": gesture.endMillis,
            "duration": gesture.durationMillis,
            "screen": screen,
            "points": gesture.points.map { point in
                [
                    "x": point.x,
                    "y": point.y,
                    "timestamp": point.timestampMillis,
                    // Measured from the gesture's own first point. Android shipped this as
                    // `timestamp - 123231` for a while, which made every interaction claim a
                    // `time_since_start` of about fifty-five years; nothing on the server reads it,
                    // which is why it went unnoticed rather than why it was harmless.
                    "time_since_start": point.timestampMillis - gesture.startMillis,
                    "screen": screen,
                ]
            },
        ]
        if let screenId { crumb["screen_id"] = screenId }
        return crumb
    }
}

/// Whether the person behind a session has a name yet.
public enum UserType: String, Sendable {
    case anonymous
    case identified
}
