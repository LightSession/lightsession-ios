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

    /// A string fit to become part of a screen name, or nil.
    ///
    /// The same rules as the Android SDK's `SubScreens.sanitize`, for the same reasons. Screen names
    /// are keys — the server rows a screen by name, the device caches by a hash of it — so the same
    /// part has to produce a byte-identical string every time: whitespace is collapsed rather than
    /// trusted, because a label wrapped across two lines arrives with a newline in it. And anything
    /// much longer than a label means the caller grabbed body text, which is per-user — "Delete Dr.
    /// Silva?" would mint a screen per doctor. Truncating would keep that bug and hide it, so an
    /// over-long label is rejected outright.
    public static func subScreenLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw
            .replacingOccurrences(of: subScreenSeparator, with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty, collapsed.count <= 32 else { return nil }
        return collapsed
    }

    /// `Parent › Part › Part`, innermost last.
    ///
    /// Plural because the parts are layers, not alternatives — the shape this replaced on Android was
    /// measured wrong there: a dialog *replaced* the tab it was raised from, so the same dialog opened
    /// from three tabs was one node with three screens' heatmaps piled onto it. On iOS the layers are
    /// the declared part and the modal; tabs never appear here because a real iOS tab is its own view
    /// controller and already a whole screen.
    ///
    /// A part that merely repeats the name built so far is dropped — see `isRedundantPart` — which is
    /// also what keeps a modal named like the panel it covers from stuttering: `Filter › Filter`
    /// folds to `Filter`.
    public static func compose(screen: String, parts: [String]) -> String {
        var name = screen
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !isRedundantPart(of: name, trimmed) else { continue }
            name += subScreenSeparator + trimmed
        }
        return name
    }

    /// `Parent › Part`, or just the parent when there is no part.
    public static func compose(screen: String, subScreen: String?) -> String {
        compose(screen: screen, parts: [subScreen ?? ""])
    }

    /// Whether a part only repeats the leaf of the name built so far.
    ///
    /// The Android SDK's rule, spelling for spelling: the leaf is what follows the last route slash or
    /// the last separator, and `home_feed` repeating as `Home Feed` is still a repeat.
    static func isRedundantPart(of name: String, _ part: String) -> Bool {
        let leaf = name
            .components(separatedBy: "/").last!
            .components(separatedBy: subScreenSeparator).last!
        if leaf.caseInsensitiveCompare(part) == .orderedSame { return true }
        func folded(_ s: String) -> String {
            s.lowercased()
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "-", with: "")
        }
        return folded(leaf) == folded(part)
    }

    /// A name for an alert that stays the same every time that alert opens.
    ///
    /// The trap is the obvious answer, and it is the one the Android SDK documented before this: the
    /// alert's title is right there, and naming the part after it means "Delete Dr. Silva?" and
    /// "Delete Dr. Souza?" become two screens — a list of two hundred doctors becomes two hundred
    /// screens. Content cannot be the identity, so no text the alert displays is read here at all.
    ///
    /// What is read instead, in order:
    ///
    ///  * an `accessibilityIdentifier` the app set on the alert's view — the developer naming the
    ///    thing, which is fixed by definition and the way out of every collision below;
    ///  * the alert's **structure**: presentation style, each action's style in order, and the field
    ///    count. Stable across data changes, different for structurally different alerts, and blind
    ///    to what any of it says. Two alerts with the same shape — title, message, two buttons is a
    ///    common one — collide onto one node, and that is the right way to be wrong: a collision
    ///    merges two parts and is visible, where content-naming splits one part into hundreds and
    ///    is not.
    public static func alertName(
        identifier: String?,
        styleRaw: Int,
        actionStyleRaws: [Int],
        textFieldCount: Int
    ) -> String {
        if let named = subScreenLabel(identifier) { return named }
        var hash: Int64 = 17
        func mix(_ value: Int) { hash = hash &* 31 &+ Int64(value) }
        mix(styleRaw)
        mix(actionStyleRaws.count)
        for raw in actionStyleRaws { mix(raw) }
        mix(textFieldCount)
        return "alert-" + String(format: "%06x", hash & 0xFFFFFF)
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
