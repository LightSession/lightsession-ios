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

        /// How many rectangles the richest wireframe ever sent for this capture carried. 0 = unknown.
        ///
        /// ## The ratchet
        ///
        /// "Sent" used to be the whole memory: a boolean, so whatever wireframe went out first was
        /// the capture's picture for the life of the install. That is exactly wrong for the screens
        /// that matter — a loading screen's first capture is a spinner in a shell, and the settle
        /// detector is *right* to allow it: an indeterminate spinner animates without changing the
        /// content signature, so the screen genuinely looks finished. Android measured the same
        /// screen at 37 rectangles with the spinner up against 81 loaded.
        ///
        /// Remembering the count turns "sent" into a bar to clear. A later capture is sent only when
        /// it carries strictly more rectangles, and a successful send raises the bar. Strictly more
        /// is what converges: a screen whose data varies between visits does not ping-pong, because
        /// equal-or-poorer captures are silence, and the count can only rise as many times as there
        /// are new maxima. It also means an SDK upgrade whose reader finds more of the screen heals
        /// every stored wireframe by itself on the next visit — which retires part of the standing
        /// defect documented at the top of this file: the cache is invalidated by *app* version while
        /// wireframe quality changes with *SDK* version.
        ///
        /// A count and not a hash, deliberately. The question the map asks is "is this a more
        /// complete picture", not "is this a different picture" — a hash resends on every data
        /// change forever.
        ///
        /// 0 for a capture stored before this existed, which makes any wireframe with a single
        /// rectangle "richer": every legacy install resends each stale screen once, records the bar,
        /// and goes quiet. That one send per screen is the healing, not a bug.
        public var wireframeRects: Int

        public static let none = State(hasWireframe: false, hasScreenshot: false, wireframeRects: 0)

        public init(hasWireframe: Bool, hasScreenshot: Bool, wireframeRects: Int = 0) {
            self.hasWireframe = hasWireframe
            self.hasScreenshot = hasScreenshot
            self.wireframeRects = wireframeRects
        }
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

    /// Stored as `wireframe` / `full`, optionally suffixed `:<rects>` — `wireframe:81`. A value
    /// without the suffix is a legacy entry from before the bar existed and parses as 0, which is
    /// what triggers its one healing resend.
    public func state(forCapture compositeId: String) -> State {
        guard let value = storage.string(forKey: Self.prefix + compositeId) else { return .none }
        let parts = value.split(separator: ":", maxSplits: 1)
        let rects = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
        switch parts.first {
        case "full": return State(hasWireframe: true, hasScreenshot: true, wireframeRects: rects)
        case "wireframe": return State(hasWireframe: true, hasScreenshot: false, wireframeRects: rects)
        default: return .none
        }
    }

    /// Records that a wireframe of [rects] rectangles landed, raising the bar and never lowering it.
    ///
    /// Monotonic under any completion order, which matters because sends race: the first capture's
    /// send and a late-content upgrade can complete out of order, and letting the smaller count win
    /// would schedule a pointless re-upgrade on the next visit.
    public func recordWireframe(forCapture compositeId: String, rects: Int) {
        let current = state(forCapture: compositeId)
        let bar = max(current.wireframeRects, rects)
        // The screenshot marker survives a wireframe send: a wireframe reported after a screenshot
        // has already landed must not erase the knowledge that the real screen is up there, or the
        // SDK would replace it again. Only the label is protected — the bar still rises, because it
        // describes the wireframe layer, which the screenshot does not displace server-side.
        let label = current.hasScreenshot ? "full" : "wireframe"
        storage.set("\(label):\(bar)", forKey: Self.prefix + compositeId)
    }

    public func recordScreenshot(forCapture compositeId: String) {
        // The bar is carried across, not reset: the wireframe layer keeps existing beside the
        // screenshot server-side, and forgetting its richness would resend it on the next visit.
        let bar = state(forCapture: compositeId).wireframeRects
        storage.set("full:\(bar)", forKey: Self.prefix + compositeId)
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
