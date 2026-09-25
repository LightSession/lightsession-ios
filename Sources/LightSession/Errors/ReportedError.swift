import Foundation

/// One frame of an error this SDK did not see thrown, as the runtime that threw it describes it.
///
/// For `LightSession.recordError`. A Swift `Error` carries no frames of its own, and the runtimes
/// this exists for have frames the platform never sees: a Dart exception in a Flutter app, a
/// JavaScript one in React Native. Wrapped in a synthetic native error, both would lose the two
/// fields the server groups on — every error would carry the wrapper's type, and no frame would be
/// the app's — so the embedder hands over what its runtime knows, and it is sent in exactly the
/// shape a native frame takes.
public struct ErrorFrame: Equatable, Sendable {
    /// What the frame belongs to — the class of a method, or the library of a top-level function.
    /// Sent as `class`: the server keys a group on `class.method` of the first in-app frames.
    public var module: String
    /// The function or method, sent as `method`.
    public var function: String
    /// The source file as the runtime names it, when it names one.
    public var file: String?
    /// The line, when the runtime knows it. Never part of the grouping key.
    public var line: Int?
    /// Whether this frame is the app's own code. The embedder decides: it is the only side that
    /// knows what "the app's own code" means in its runtime.
    public var inApp: Bool
    /// Where the frame was in the build, for a build that kept no names — a Flutter release built
    /// with `--obfuscate` or `--split-debug-info`. Pass it with an empty [module] and [function],
    /// and the build as `symbols` on `recordError`; the server names the frame from the build's
    /// uploaded symbols. Sent as `addr`, in hex.
    public var address: UInt64?

    public init(
        module: String,
        function: String,
        file: String? = nil,
        line: Int? = nil,
        inApp: Bool = false,
        address: UInt64? = nil
    ) {
        self.module = module
        self.function = function
        self.file = file
        self.line = line
        self.inApp = inApp
        self.address = address
    }
}

/// The build whose symbols name an error's addresses, for `LightSession.recordError`.
///
/// A runtime that compiles its release builds without names reports an error's frames as addresses,
/// and prints a build id beside them. The server looks the build's uploaded symbols up by that id and
/// names the frames before it groups the error.
public struct ErrorSymbols: Equatable, Sendable {
    /// What kind of symbols they are. `dart` is the kind the server reads.
    public var kind: String
    /// The build id the runtime printed with the stack, in hex.
    public var buildId: String
    /// The architecture the runtime printed — `arm64`, `x64`. For the record only.
    public var arch: String?
    /// The app's own package, when the embedder knows it; the server marks named frames in-app by it.
    public var appPackage: String?

    public init(kind: String, buildId: String, arch: String? = nil, appPackage: String? = nil) {
        self.kind = kind
        self.buildId = buildId
        self.arch = arch
        self.appPackage = appPackage
    }

    /// The crumb's `symbols` block. The build id lowercased, as the server stores it and every
    /// runtime prints it.
    var wire: [String: Any] {
        var block: [String: Any] = ["kind": kind, "build_id": buildId.lowercased()]
        if let arch { block["arch"] = arch }
        if let appPackage { block["app_package"] = appPackage }
        return block
    }
}

extension ErrorCrumb {

    /// The exception chain of an error an embedder reports: one exception, in the shape a native one
    /// takes, held to the same bounds.
    ///
    /// One exception rather than a chain: the runtimes this serves do not carry a cause the way an
    /// `NSError` does, and inventing an empty one would make the server read the error as wrapped.
    static func reported(type: String, message: String?, frames: [ErrorFrame]) -> [[String: Any]] {
        var wireFrames: [[String: Any]] = frames.prefix(maxFrames).map { frame in
            var wire: [String: Any] = [
                "class": frame.module,
                "method": frame.function,
                "in_app": frame.inApp,
            ]
            if let file = frame.file { wire["file"] = file }
            if let line = frame.line { wire["line"] = line }
            if let address = frame.address { wire["addr"] = "0x" + String(address, radix: 16) }
            return wire
        }
        if frames.count > maxFrames {
            wireFrames.append([
                "class": "…",
                "method": "\(frames.count - maxFrames) frames elided",
                "in_app": false,
            ])
        }
        var exception: [String: Any] = ["type": type, "frames": wireFrames]
        if let message { exception["message"] = String(message.prefix(maxMessage)) }
        return [exception]
    }
}
