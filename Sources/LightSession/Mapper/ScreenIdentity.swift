import Foundation

/// How a screen gets its name, and how a name becomes a wire identity.
///
/// Kept apart from anything that touches UIKit so the rules can be read and tested as rules. Every
/// one of them exists because of a name that came out wrong somewhere.
public enum ScreenIdentity {

    /// The kinds the server understands. Sent as `screenType`.
    ///
    /// Deliberately not reusing Android's words. `ACTIVITY` and `CONVENTIONAL` describe Android
    /// mechanisms, and a screen labelled `ACTIVITY` on an iPhone would be a lie that reads as a bug.
    public enum Kind: String, Sendable {
        /// A `UIViewController` the SDK saw appear.
        case uiKit = "UIKIT"
        /// A SwiftUI screen: one the app named, or the placeholder node an app that named none is
        /// collapsed onto.
        case swiftUI = "SWIFTUI"
        /// A screen a JavaScript navigator named.
        ///
        /// The same word the Android SDK sends for React Native, so one app's iOS and Android builds land on
        /// the same node in the graph rather than on two that differ only by platform. Without this a React
        /// Native screen arrived labelled `SWIFTUI`, which is a lie that reads as a bug — the host reports it
        /// through the same call a SwiftUI app uses, and the call cannot tell who is on the other end.
        case reactNative = "REACT_NATIVE"

        /// A screen a Dart navigator named.
        ///
        /// Flutter has React Native's problem and one more. It is one view controller, so nothing UIKit
        /// offers distinguishes its screens — that part is identical. It also renders to a single
        /// surface, so unlike React Native there is no view tree underneath either: the wireframe and
        /// the mask have to come from the app as well as the name.
        ///
        /// Its own value rather than reusing `reactNative`, for the reason `reactNative` exists at all:
        /// a label that names the wrong framework is a lie that reads as a bug.
        case flutter = "FLUTTER"
    }

    /// Turns a view controller's type name into a screen name.
    ///
    /// Swift type names arrive module-qualified from `NSStringFromClass` — `Example.HomeViewController`
    /// — and the module is noise that would also change the identity of every screen the day someone
    /// renames the target. Generic parameters get stripped for the same reason.
    ///
    /// The `ViewController` suffix stays. It is tempting to remove it, and wrong: `SettingsViewController`
    /// and a SwiftUI screen the app names `Settings` are different screens, and collapsing them would
    /// merge two nodes in the graph that have nothing to do with each other. Noise that is stable
    /// beats tidiness that collides.
    public static func screenName(fromTypeName raw: String) -> String {
        var name = raw
        // `Example.Home<Int>` -> `Example.Home`
        if let angle = name.firstIndex(of: "<") {
            name = String(name[name.startIndex..<angle])
        }
        // Last component: nested types arrive as `Module.Outer.Inner`, and `Inner` is the screen.
        if let dot = name.lastIndex(of: ".") {
            name = String(name[name.index(after: dot)...])
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unknown" : trimmed
    }

    /// The separator between a screen and a part of it that is a place of its own.
    ///
    /// Matches the Android SDK byte for byte, because both write into the same graph: a modal on iOS
    /// and a dialog on Android should read the same way in the product, and a different separator
    /// would make them different nodes for no reason a user could see.
    public static let subScreenSeparator = " › "

    /// `Parent › Part`, or just the parent when there is no part.
    public static func compose(screen: String, subScreen: String?) -> String {
        guard let sub = subScreen?.trimmingCharacters(in: .whitespacesAndNewlines), !sub.isEmpty else {
            return screen
        }
        return screen + subScreenSeparator + sub
    }

    /// The composite the SDK sends as `screenId`.
    ///
    /// The server accepts it and ignores it — `screenName` is the identity there, and this encodes
    /// resolution and version into what should be stable. It is still sent, and still built the same
    /// way as Android's, because it is what the SDK's own cache is keyed on: two captures of one
    /// screen at different sizes or themes are different captures, and the cache has to be able to
    /// say so without asking the server.
    public static func compositeId(
        name: String,
        appVersionName: String,
        appVersionCode: Int,
        width: Int,
        height: Int,
        theme: Theme
    ) -> String {
        "\(name)_\(appVersionName)_\(appVersionCode)_\(width)_\(height)_\(theme.rawValue)"
    }
}

/// Light or dark, as the server spells it.
///
/// Capitalised because that is what Android sends and what the server stores; sending `"light"` here
/// would split every screen into two rows that differ only in case.
public enum Theme: String, Sendable {
    case light = "Light"
    case dark = "Dark"
}
