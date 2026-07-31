import Foundation

/// What a screen looks like on the wire.
///
/// The field names, casing and endpoints are fixed by the server and by the Android SDK, which already
/// writes into the same tables. Anything invented here would produce a second set of rows for the same
/// app rather than an error.
public struct ScreenReport: Equatable, Sendable {
    /// The SDK's composite. The server accepts it and ignores it — `name` is the identity there — but
    /// it is what this SDK's cache is keyed on.
    public let compositeId: String
    public let name: String
    public let kind: ScreenIdentity.Kind
    /// Geometry for the server to draw. Sent instead of an image, never alongside one.
    public let skeleton: SkeletonFrame?
    /// A real screenshot, base64. The alternative to `skeleton`.
    public let imageBase64: String?
    public let width: Int
    public let height: Int
    public let theme: Theme
    public let appVersionName: String
    public let appVersionCode: Int

    public init(
        compositeId: String,
        name: String,
        kind: ScreenIdentity.Kind,
        skeleton: SkeletonFrame?,
        imageBase64: String?,
        width: Int,
        height: Int,
        theme: Theme,
        appVersionName: String,
        appVersionCode: Int
    ) {
        self.compositeId = compositeId
        self.name = name
        self.kind = kind
        self.skeleton = skeleton
        self.imageBase64 = imageBase64
        self.width = width
        self.height = height
        self.theme = theme
        self.appVersionName = appVersionName
        self.appVersionCode = appVersionCode
    }
}

/// One step from one screen to another.
public struct FlowReport: Equatable, Sendable {
    public let from: String
    public let to: String
    /// Free text on the server. `push`, `pop`, `present`, `report` — what caused the move.
    public let transition: String
    public let appVersionName: String
    public let appVersionCode: Int

    public init(from: String, to: String, transition: String, appVersionName: String, appVersionCode: Int) {
        self.from = from
        self.to = to
        self.transition = transition
        self.appVersionName = appVersionName
        self.appVersionCode = appVersionCode
    }
}

/// Where reports go.
///
/// A protocol so the tracker can be exercised against a recorder in a test instead of against a
/// server. That is not hypothetical tidiness: the payload shape is the part most likely to be wrong in
/// a way no compiler catches, and on the Android side one required field was missing from a payload
/// for long enough that every call to that route returned 422 and nothing noticed, because its only
/// caller was dead code.
public protocol DataSender: AnyObject {
    func send(screen: ScreenReport, completion: @escaping (Result<Void, Error>) -> Void)
    func replaceScreenshot(screen: ScreenReport, completion: @escaping (Result<Void, Error>) -> Void)
    func send(flow: FlowReport, completion: @escaping (Result<Void, Error>) -> Void)
}

// MARK: - Payload building

extension ScreenReport {
    /// The body for `POST /screens`.
    ///
    /// `skeleton` and `bitmapBase64` are alternatives, and only the one that is present is written. The
    /// key is omitted rather than set to null: "absent" is the state the server reads, and depending on
    /// a null-handling rule in a serialiser is how a payload starts differing from what it looks like.
    public var createBody: [String: Any] {
        var body: [String: Any] = [
            "screenId": compositeId,
            "screenName": name,
            "screenType": kind.rawValue,
            "width": width,
            "height": height,
            "theme": theme.rawValue,
            "appVersionCode": appVersionCode,
            "appVersionName": appVersionName,
        ]
        if let skeleton { body["skeleton"] = skeleton.jsonObject }
        if let imageBase64 { body["bitmapBase64"] = imageBase64 }
        return body
    }

    /// The body for `PUT /screens/screenshot`.
    ///
    /// `screenName` is required here and its absence is not a validation nicety: without it the server
    /// rejects the request outright, which is exactly what happened on Android for as long as the only
    /// caller was unreachable.
    public var screenshotBody: [String: Any]? {
        guard let imageBase64 else { return nil }
        return [
            "screenId": compositeId,
            "screenName": name,
            "bitmapBase64": imageBase64,
            "width": width,
            "height": height,
            "theme": theme.rawValue,
            "appVersionCode": appVersionCode,
            "appVersionName": appVersionName,
        ]
    }
}

extension FlowReport {
    public func body(timestampMillis: Int64) -> [String: Any] {
        [
            "from": from,
            "to": to,
            "type": transition,
            "timestamp": timestampMillis,
            "appVersionCode": appVersionCode,
            "appVersionName": appVersionName,
        ]
    }
}
