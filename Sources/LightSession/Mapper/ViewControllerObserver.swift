#if canImport(UIKit)
import UIKit

/// Hears about every `UIViewController` that comes on screen.
///
/// This is iOS's answer to `Application.ActivityLifecycleCallbacks`, and it has to be built rather
/// than registered: UIKit has no notification for "a view controller appeared". So `viewDidAppear` is
/// swizzled once, on `UIViewController` itself, and every controller in the app — the host's, UIKit's
/// own, a third party's — passes through it.
///
/// Three things are deliberate.
///
/// **The original is always called.** The replacement calls through first and observes afterwards, so
/// an app whose `viewDidAppear` does real work is never made to depend on this SDK's behaviour.
///
/// **It is installed exactly once**, guarded by a flag rather than by hoping. Swizzling twice swaps the
/// implementations back and produces infinite recursion the first time a screen appears.
///
/// **Controllers that are not screens are filtered here**, not by the tracker. `UIAlertController`,
/// navigation and tab containers, and Apple's private wrappers all call `viewDidAppear`; reporting them
/// would fill the map with nodes no user could name.
final class ViewControllerObserver {

    /// Called with the controller that appeared, on the main thread.
    static var onAppear: ((UIViewController) -> Void)?

    private static var installed = false

    static func install() {
        assert(Thread.isMainThread, "swizzling has to happen before any controller appears")
        guard !installed else { return }
        installed = true

        let cls = UIViewController.self
        let original = #selector(UIViewController.viewDidAppear(_:))
        let replacement = #selector(UIViewController.lightSession_viewDidAppear(_:))

        guard
            let originalMethod = class_getInstanceMethod(cls, original),
            let replacementMethod = class_getInstanceMethod(cls, replacement)
        else {
            // Not fatal on purpose: an SDK that crashes the host app because it could not install its
            // own hook has done more damage than the missing feature.
            LightSessionLog.error("could not install the view-controller hook; screens will not be observed")
            installed = false
            return
        }

        method_exchangeImplementations(originalMethod, replacementMethod)
    }
}

extension UIViewController {
    @objc fileprivate func lightSession_viewDidAppear(_ animated: Bool) {
        // The implementations are exchanged, so this call reaches the original.
        lightSession_viewDidAppear(animated)

        guard ViewControllerObserver.onAppear != nil, isLightSessionScreen else { return }
        ViewControllerObserver.onAppear?(self)
    }

    /// Whether this controller hosts SwiftUI content, including through a subclass of its own.
    ///
    /// The ancestry is walked rather than the class name tested, and the difference is not academic: a
    /// name test was written first and measured wrong. Apps subclass `UIHostingController` routinely — to
    /// set a title, to override an orientation — and `LightSessionExample.SwiftUIHostViewController`
    /// contains no trace of the word. The result was a fabricated node in the graph and an edge to it from
    /// the screen the app had just named correctly.
    ///
    /// This is the same rule the wireframe classifier follows for views: ask what a thing descends from,
    /// never what it is called. `UIHostingController` is generic, so there is no single class object to
    /// compare against — hence a walk, matching the name of each ancestor, where the *base* class's name
    /// really does contain it however the specialisation is mangled.
    var isLightSessionHostingController: Bool {
        var cls: AnyClass? = type(of: self)
        while let current = cls {
            if NSStringFromClass(current).contains("UIHostingController") { return true }
            cls = class_getSuperclass(current)
        }
        return false
    }

    /// Whether this controller is a place in the app, as opposed to a container or a system control.
    ///
    /// A container's `viewDidAppear` fires alongside its child's, and the child is the screen. Alerts
    /// and action sheets are parts of the screen that presented them, which is what the sub-screen
    /// mechanism is for — the tracker names them `Parent › Alert` rather than as screens of their own.
    var isLightSessionScreen: Bool {
        if self is UINavigationController { return false }
        if self is UITabBarController { return false }
        if self is UISplitViewController { return false }
        if self is UIPageViewController { return false }
        if self is UIAlertController { return false }

        // A controller with no window is not on screen. This happens: `viewDidAppear` fires for a
        // controller being torn down in the same run loop turn its window went away.
        guard view.window != nil else { return false }

        return true
    }
}
#endif
