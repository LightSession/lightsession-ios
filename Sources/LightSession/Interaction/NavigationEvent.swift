import Foundation

/// A screen change, on the session's timeline.
///
/// Not the same thing as the flow the screen map already records, and finding that out is what prompted this
/// file: the map's edges go to the product API and answer "which screens lead where", across every session
/// there has ever been. This goes to the ingest and answers "when did the screen change *in this session*",
/// which is what puts a marker on a replay.
///
/// Measured before it was written: a replay of 168 frames arrived with `navigation_count = 0`, because the
/// flows had been sent and these had not. The frames were all there and nothing said where one screen ended
/// and the next began.
public struct NavigationEvent: Breadcrumb, Equatable, Sendable {
    public let from: String
    public let to: String
    /// The kind of screen arrived at — `UIKIT` or `SWIFTUI`.
    public let screenKind: ScreenIdentity.Kind
    /// What caused the move. `appear`, `report`, `subscreen`.
    public let transition: String
    public let sequence: Int
    public let timestampMillis: Int64
    public let userId: String
    public let userType: UserType
    public let appVersion: String

    public init(
        from: String,
        to: String,
        screenKind: ScreenIdentity.Kind,
        transition: String,
        sequence: Int,
        timestampMillis: Int64,
        userId: String,
        userType: UserType,
        appVersion: String
    ) {
        self.from = from
        self.to = to
        self.screenKind = screenKind
        self.transition = transition
        self.sequence = sequence
        self.timestampMillis = timestampMillis
        self.userId = userId
        self.userType = userType
        self.appVersion = appVersion
    }

    /// The breadcrumb, matching Android's shape.
    ///
    /// Note the nested `data`: a navigation's fields live one level down while an interaction's are flat.
    /// That is not a design anyone would choose, and it is what the worker parses — so it is what this sends.
    public var breadcrumb: [String: Any] {
        [
            "type": "navigation",
            "timestamp": timestampMillis,
            "sequence": sequence,
            "user_id": userId,
            "user_type": userType.rawValue,
            "app_version": appVersion,
            "data": [
                "from": from,
                "to": to,
                "screenType": screenKind.rawValue,
                "transitionType": transition,
            ],
        ]
    }
}
