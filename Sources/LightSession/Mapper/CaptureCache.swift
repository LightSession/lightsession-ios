import Foundation

/// Remembers what has already been uploaded, so a screen is captured once rather than once per visit.
///
/// The cost of getting this wrong is asymmetric, and the direction matters. Caching too little means
/// re-uploading a wireframe the server already has: wasteful, invisible, harmless. Caching too much
/// means a screen that never arrives at all.
///
/// There is a known gap, and it is written down here rather than discovered later: **this cache has no
/// way to learn that the server lost something.** Delete a project's data server-side and every
/// existing install keeps saying "already sent" forever. It was watched happening — a full navigation
/// of a wiped project produced a perfect log and an empty database — and the only cure available today
/// is a version bump, because the app version is part of every key below.
public protocol CaptureCacheStorage: AnyObject {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
    func removeAll(withPrefix prefix: String)
}

public final class CaptureCache {

    /// What has been stored for a given capture.
    public struct State: Equatable, Sendable {
        public var hasWireframe: Bool
        public var hasScreenshot: Bool

        public static let none = State(hasWireframe: false, hasScreenshot: false)
    }

    private static let prefix = "com.lightsession.capture."
    private static let flowPrefix = "com.lightsession.flow."
    private static let versionKey = "com.lightsession.appVersion"

    private let storage: CaptureCacheStorage

    /// Drops everything when the app version changed.
    ///
    /// A new build is a new set of screens: the same name can have a different layout, and a wireframe
    /// from the previous version is a picture of software the user is no longer running. The version is
    /// also part of every key, so this is belt and braces — but it keeps the store from growing by one
    /// generation of keys per release.
    public init(storage: CaptureCacheStorage, appVersion: String) {
        self.storage = storage
        if storage.string(forKey: Self.versionKey) != appVersion {
            storage.removeAll(withPrefix: Self.prefix)
            storage.removeAll(withPrefix: Self.flowPrefix)
            storage.set(appVersion, forKey: Self.versionKey)
        }
    }

    public func state(forCapture compositeId: String) -> State {
        switch storage.string(forKey: Self.prefix + compositeId) {
        case "full": return State(hasWireframe: true, hasScreenshot: true)
        case "wireframe": return State(hasWireframe: true, hasScreenshot: false)
        default: return .none
        }
    }

    public func recordWireframe(forCapture compositeId: String) {
        // Not downgraded: a wireframe reported after a screenshot has already landed would otherwise
        // erase the knowledge that the real screen is up there, and the SDK would replace it again.
        guard !state(forCapture: compositeId).hasScreenshot else { return }
        storage.set("wireframe", forKey: Self.prefix + compositeId)
    }

    public func recordScreenshot(forCapture compositeId: String) {
        storage.set("full", forKey: Self.prefix + compositeId)
    }

    /// Whether this exact step has already been reported.
    ///
    /// Flows are deduplicated because a user walks the same path repeatedly and the server only needs
    /// the edge once. The key includes both endpoints so `A → B` and `B → A` stay distinct: they are
    /// different edges and the graph draws them as such.
    public func hasFlow(from: String, to: String) -> Bool {
        storage.string(forKey: Self.flowPrefix + from + "->" + to) != nil
    }

    public func recordFlow(from: String, to: String) {
        storage.set("1", forKey: Self.flowPrefix + from + "->" + to)
    }
}

#if canImport(Foundation)
/// `UserDefaults`, which is the right store for this: a few hundred short keys that should survive a
/// relaunch and are worthless if they do not.
public final class UserDefaultsCacheStorage: CaptureCacheStorage {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func set(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    public func removeAll(withPrefix prefix: String) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
#endif
