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
/// **Nothing is filtered here.** This used to drop the controllers that are not screens before the
/// tracker saw them, and the comment saying so was the only place the filtering was described — it
/// listed "Apple's private wrappers" among what it rejected, and the code rejected five container
/// classes and nothing else. What arrived in the map was UIKit's keyboard, one screen per part of it.
/// Deciding in one place, in `roleOfObservedController`, is what makes the rule readable and testable;
/// and one of the outcomes is not "ignore this" but "tell the developer their SwiftUI app is unnamed",
/// which is the tracker's to say because only the tracker knows whether the app has spoken.
final class ViewControllerObserver {

    /// Called with the controller that appeared, on the main thread.
    static var onAppear: ((UIViewController) -> Void)?

    /// Called before the transition, so a title can be read before the screen's data replaces it.
    static var onWillAppear: ((UIViewController) -> Void)?

    /// Called as a controller *starts* to go away, while its pixels are still the screen.
    ///
    /// This is the only moment a departing screen can be photographed. At `viewDidDisappear` the view
    /// is out of the hierarchy and a capture shows whatever replaced it — the exact mistake the
    /// screenshot pipeline was built to avoid. At `viewWillDisappear` the transition has not drawn its
    /// first frame: the window still renders the screen the person is leaving.
    static var onWillDisappear: ((UIViewController) -> Void)?

    /// Called when a controller goes away, which for a sheet is the only signal there is.
    ///
    /// A SwiftUI sheet is a page sheet: the screen underneath is never removed from the hierarchy, so
    /// closing the sheet emits no `viewWillAppear` and no `viewDidAppear` for the screen coming back.
    /// Without this the SDK stays on the sheet for the rest of the session — measured, and worse than
    /// a wrong name: the screenshot taken after the quiet period showed the screen underneath and was
    /// filed under the sheet.
    static var onDisappear: ((UIViewController) -> Void)?

    private static var installed = false

    static func install() {
        assert(Thread.isMainThread, "swizzling has to happen before any controller appears")
        guard !installed else { return }
        installed = true

        let cls = UIViewController.self

        // `viewWillAppear` as well as `viewDidAppear`, and the reason is a measurement.
        //
        // `viewDidAppear` fires when the push animation *finishes*, about 350 ms after it starts. A
        // detail screen fetching from a backend on the same machine has its answer in 50 ms — so by
        // the time the SDK is told the screen appeared, `.navigationTitle(doctor.name ?? "Médico")`
        // already says `Dr. Carlos Mendes`, and the screen is named after a record. Reading it a
        // moment earlier is not enough; the whole animation has to be beaten.
        //
        // `viewWillAppear` runs before the transition, with the title SwiftUI configured and the
        // request still in flight. Nothing is reported from there — it only remembers what the screen
        // called itself before it knew anything.
        if let willAppear = class_getInstanceMethod(cls, #selector(UIViewController.viewWillAppear(_:))),
           let replacement = class_getInstanceMethod(
               cls, #selector(UIViewController.lightSession_viewWillAppear(_:))
           ) {
            method_exchangeImplementations(willAppear, replacement)
        } else {
            LightSessionLog.error("could not hook viewWillAppear; SwiftUI titles may name records")
        }

        if let willDisappear = class_getInstanceMethod(
            cls, #selector(UIViewController.viewWillDisappear(_:))
        ),
            let replacement = class_getInstanceMethod(
                cls, #selector(UIViewController.lightSession_viewWillDisappear(_:))
            ) {
            method_exchangeImplementations(willDisappear, replacement)
        } else {
            LightSessionLog.error(
                "could not hook viewWillDisappear; a screen touched until the moment it is left will have no screenshot"
            )
        }

        if let didDisappear = class_getInstanceMethod(cls, #selector(UIViewController.viewDidDisappear(_:))),
           let replacement = class_getInstanceMethod(
               cls, #selector(UIViewController.lightSession_viewDidDisappear(_:))
           ) {
            method_exchangeImplementations(didDisappear, replacement)
        } else {
            LightSessionLog.error("could not hook viewDidDisappear; a closed sheet will not be noticed")
        }

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

extension UIWindow {
    /// The controller the user is actually looking at.
    ///
    /// Presented first, then children: a sheet is presented *by* the screen under it, and a tab bar's
    /// selected tab is a child. Walking in that order lands on the leaf rather than on a container.
    var lightSessionTopController: UIViewController? {
        var current = rootViewController
        while true {
            if let presented = current?.presentedViewController {
                current = presented
                continue
            }
            if let nav = current as? UINavigationController, let top = nav.topViewController {
                current = top
                continue
            }
            if let tabs = current as? UITabBarController, let selected = tabs.selectedViewController {
                current = selected
                continue
            }
            if let child = current?.children.last, child !== current {
                current = child
                continue
            }
            return current
        }
    }
}

extension UIViewController {
    @objc fileprivate func lightSession_viewDidAppear(_ animated: Bool) {
        // The implementations are exchanged, so this call reaches the original.
        lightSession_viewDidAppear(animated)

        ViewControllerObserver.onAppear?(self)
    }

    @objc fileprivate func lightSession_viewWillAppear(_ animated: Bool) {
        lightSession_viewWillAppear(animated)
        ViewControllerObserver.onWillAppear?(self)
    }

    @objc fileprivate func lightSession_viewWillDisappear(_ animated: Bool) {
        lightSession_viewWillDisappear(animated)
        ViewControllerObserver.onWillDisappear?(self)
    }

    @objc fileprivate func lightSession_viewDidDisappear(_ animated: Bool) {
        lightSession_viewDidDisappear(animated)
        ViewControllerObserver.onDisappear?(self)
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

    /// Whether this controller frames a screen rather than being one.
    ///
    /// A container's `viewDidAppear` fires alongside its child's, and the child is the screen. Alerts
    /// and action sheets are parts of the screen that presented them, which is what the sub-screen
    /// mechanism is for — the tracker names them `Parent › Alert` rather than as screens of their own.
    var isLightSessionContainer: Bool {
        self is UINavigationController
            || self is UITabBarController
            || self is UISplitViewController
            || self is UIPageViewController
            || self is UIAlertController
    }

    /// Whether the user can see this. `viewDidAppear` fires for a controller being torn down in the
    /// same run loop turn its window went away.
    var isLightSessionOnScreen: Bool {
        view.window != nil
    }

    /// Whether this was presented over something rather than navigated to.
    ///
    /// A pushed screen is a child of a navigation controller; a sheet, an alert or a cover is
    /// *presented*, and `presentingViewController` is the difference. It matters because an untitled
    /// sheet is not an unnamed screen — it is not a screen.
    var isLightSessionPresentedModally: Bool {
        presentingViewController != nil
    }

    /// The title on this screen, as the user reads it.
    ///
    /// `navigationItem.title` first and `title` second, which is the order that matters rather than a
    /// preference: setting `title` also sets `navigationItem.title`, but a screen can set the
    /// navigation item alone — SwiftUI's `.navigationTitle` does exactly that — and reading `title`
    /// first would come back empty for every SwiftUI screen there is.
    var lightSessionTitle: String? {
        for candidate in [navigationItem.title, title] {
            if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
               !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    /// Whether this controller's class is the app's own code.
    ///
    /// The question a screen map actually wants to ask, and the one that was never asked. Every
    /// `UIViewController` in the process passes through the hook — UIKit's, Safari's, the app's — and
    /// only the app has screens. A measured session against a real app mapped
    /// `UIPredictionViewController`, `UISystemInputAssistantViewController` and
    /// `_SFAppPasswordSavingViewController` as places the user had navigated to, because a text field
    /// had been tapped.
    ///
    /// `Bundle(for:)` answers it. It resolves a class to the bundle its code was loaded from, which for
    /// UIKit is `UIKitCore.framework` and for the app is the app. The `Foundation` documentation warns
    /// that it falls back to the main bundle for a class it cannot place, which would have made this
    /// silently useless — it was measured rather than assumed, and framework classes do resolve to
    /// their framework, including ones that come from the shared cache.
    ///
    /// Frameworks the app ships inside itself count as the app's, which is what a modular codebase
    /// needs: a screen in `Feature.framework` is still a screen.
    ///
    /// One thing is knowingly given up. A screen the *system* draws for the app — `SFSafariViewController`
    /// is the honest example — is no longer mapped. It is Apple's screen, rendered in another process,
    /// and the SDK could never see inside it anyway; an app that wants it in the graph can name it with
    /// `LightSession.setScreen(_:)`. That is a smaller loss than a map that cannot survive a keyboard.
    var isLightSessionOwnedByApp: Bool {
        Bundle(for: type(of: self)).isLightSessionInsideApp
    }
}

extension Bundle {

    /// Where the app itself lives, resolved once. Symlinks are resolved because the simulator's
    /// container paths go through several of them and two spellings of one directory would not match.
    private static let lightSessionAppPath: String =
        Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path

    /// Whether this bundle ships inside the app bundle.
    var isLightSessionInsideApp: Bool {
        isPathInsideApp(
            bundleURL.resolvingSymlinksInPath().standardizedFileURL.path,
            appPath: Bundle.lightSessionAppPath
        )
    }
}
#endif
