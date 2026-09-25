import Foundation

/// A screen described by an embedder, for a screen the view walk cannot read.
///
/// ## Why an embedder describes its own screen
///
/// `SkeletonBuilder` draws a wireframe from the view walk, and a toolkit that paints into a layer of
/// its own — Flutter draws its whole screen into one `FlutterView` — gives that walk one node with
/// nothing in it. Nothing fails and nothing logs: the walk finds one view, and the wireframe of every
/// such screen is a single rectangle the size of the display. The party that knows what is on such a
/// screen is the toolkit that painted it, so it says so through this — the same shape of seam as
/// `SuppliedMasks`, which says what to cover where this says what to draw.
///
/// ## Where the description goes
///
/// Under the view that hosts it, as that view's first children, in place of the nothing the walk
/// found there. Not in place of the whole walk: a view the platform draws over the toolkit's content
/// — an alert a plugin presented, a native view embedded in the screen — is still on the glass and
/// is still walked, painted after the description and covering it where it is opaque.
///
/// Only into the wireframe. Masking keeps the walk it has and the rectangles `SuppliedMasks` is
/// handed per frame: a description is taken at most once a second, and a text node from a second
/// ago would put a mask where the text was.
///
/// ## Which screen it describes
///
/// A description is one standing fact and a navigation is instant, so the two can disagree: the
/// description of the screen being left, read while the screen being arrived at is the one being
/// drawn, would file one screen's layout under another's name. So a description carries the name
/// of the screen it describes, and is used only for that screen. One that names none — sent before
/// the embedder named its first screen — makes no claim, and is used for whichever screen is
/// current. The Android SDK measured the failure before it had this: a gallery screen was filed with
/// the hub's fourteen icons.
///
/// Rectangles are in the window's coordinate space, in points, as the walk's are.
public enum SuppliedScreen {

    /// A description, and the view it describes the inside of.
    struct Graft {
        /// Compared by identity against the views the walk visits. Weak in the standing copy, so an
        /// embedder that went away takes its description with it.
        let host: AnyObject
        let root: ViewSnapshot
    }

    private struct Standing {
        weak var host: AnyObject?
        let root: ViewSnapshot
        let screenName: String?
    }

    private static let lock = NSLock()
    private static var current: Standing?
    private static var appearance: Bool?

    /// The appearance the embedder draws in, or nil to follow the platform's.
    ///
    /// A capture is filed under a theme, read from the window's trait — which is the app's too for
    /// a native app, since a native app that forces dark mode does it through the trait. A toolkit
    /// can draw dark on its own: a Flutter app with `ThemeMode.dark` paints dark on a device in light
    /// mode, and nothing in UIKit says so. Measured with such an app on a simulator: its screen, dark
    /// to the pixel, was filed as `Light`, wireframe and screenshot both, in the slot its light
    /// rendering would take.
    ///
    /// App-wide rather than per screen, unlike the description: an app's theme is not a property of
    /// one screen, and a new screen is captured before its description arrives.
    static var dark: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return appearance
    }

    /// Sets it; nil follows the platform again.
    public static func setDark(_ dark: Bool?) {
        lock.lock()
        defer { lock.unlock() }
        appearance = dark
    }

    /// Replaces the standing description.
    ///
    /// - Parameters:
    ///   - root: the described content, in window points. Drawn by the same rules as a walked view:
    ///     a container is drawn only with a colour of its own, a text or an image in the palette's.
    ///   - host: the view whose inside this describes.
    ///   - screenName: the screen it describes, as the embedder named it; nil for no claim.
    public static func set(root: ViewSnapshot, host: AnyObject, screenName: String?) {
        lock.lock()
        defer { lock.unlock() }
        current = Standing(host: host, root: root, screenName: screenName)
    }

    /// Forgets the standing description, and the appearance with it; the walk and the platform are
    /// the whole answer again.
    public static func clear() {
        lock.lock()
        defer { lock.unlock() }
        current = nil
        appearance = nil
    }

    /// The description to draw `screen` with, or nil when there is none, its host has gone, or it
    /// describes another screen.
    static func graft(for screen: String?) -> Graft? {
        lock.lock()
        defer { lock.unlock() }
        guard let standing = current, let host = standing.host else { return nil }
        if let described = standing.screenName, described != screen { return nil }
        return Graft(host: host, root: standing.root)
    }
}
