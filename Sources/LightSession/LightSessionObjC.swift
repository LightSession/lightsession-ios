#if canImport(UIKit)
import UIKit

/// The SDK as Objective-C sees it.
///
/// Swift's own API is the real one — `LightSession.start(_:)` takes a typed struct, which is what an app should
/// use. This exists because two callers cannot: an Objective-C app, and React Native's iOS bridge, whose
/// TurboModule is Objective-C++ and cannot see a Swift `enum` with static methods at all.
///
/// It is a translation layer and nothing else. Every method forwards, the dictionary is read leniently, and no
/// state lives here — a second copy of the SDK's state would be a second thing to disagree with it.
@objc(LightSessionBridge)
public final class LightSessionBridge: NSObject {

    /// Starts the SDK from a dictionary, which is what crosses a bridge.
    ///
    /// Absent keys fall back to the Swift default rather than to a literal repeated here. A second copy of a
    /// default is a second thing to update, and it goes stale silently: the reader sees a number and cannot
    /// tell it is out of date.
    @objc
    public static func start(_ config: [String: Any], verbose: Bool) {
        // `apiUrl` first, because that is what the JavaScript API has always been called and what the Android
        // SDK reads. `apiURL` is accepted too, because Swift's own API spells it that way and someone reading
        // those docs will pass it.
        //
        // This was nearly a runtime-only bug: one config object is meant to configure both platforms, and a
        // bridge that read only Swift's spelling would have worked on Android and refused to start on iOS.
        guard
            let apiKey = config.trimmedString("apiKey"),
            let apiURL = config.firstString("apiUrl", "apiURL")
        else {
            // Named individually. "Invalid config" sends the reader to check both.
            let missing = [
                config.trimmedString("apiKey") == nil ? "apiKey" : nil,
                config.firstString("apiUrl", "apiURL") == nil ? "apiUrl" : nil,
            ].compactMap { $0 }
            LightSessionLog.error("start needs \(missing.joined(separator: " and ")); not started")
            return
        }

        let defaults = LightSessionConfig(apiKey: apiKey, apiURL: apiURL)
        let settings = LightSessionConfig(
            apiKey: apiKey,
            apiURL: apiURL,
            ingestURL: config.firstString("ingestUrl", "ingestURL"),
            screensReportedByHost: config.bool("screensReportedByHost", defaults.screensReportedByHost),
            reportedScreenKind: ScreenIdentity.Kind(rawValue: config.trimmedString("reportedScreenKind") ?? "")
                ?? defaults.reportedScreenKind,
            captureRealScreens: config.bool("captureRealScreens", defaults.captureRealScreens),
            maskText: config.bool("maskText", defaults.maskText),
            maskImages: config.bool("maskImages", defaults.maskImages),
            trackInteractions: config.bool("trackInteractions", defaults.trackInteractions),
            enableReplay: config.bool("enableReplay", defaults.enableReplay),
            captureIntervalMillis: config.millis("captureIntervalMillis", defaults.captureIntervalMillis),
            interactionCaptureIntervalMillis: config.millis(
                "interactionCaptureIntervalMillis", defaults.interactionCaptureIntervalMillis
            ),
            sessionTimeoutMillis: config.millis("sessionTimeoutMillis", defaults.sessionTimeoutMillis)
        )
        LightSession.start(settings, verbose: verbose)
    }

    @objc public static func setScreen(_ name: String) { LightSession.setScreen(name) }
    @objc public static func setSubScreen(_ name: String) { LightSession.setSubScreen(name) }
    @objc public static func clearSubScreen(_ name: String) { LightSession.clearSubScreen(name) }
    @objc public static func identify(_ userId: String) { LightSession.identify(userId: userId) }
    @objc public static func reset() { LightSession.reset() }
    @objc public static func startRecording() { LightSession.startRecording() }
    @objc public static func stopRecording() { LightSession.stopRecording() }
    /// Whether anything is being recorded — not merely whether the SDK was configured.
    @objc public static var isRecording: Bool { LightSession.isRecording }
    @objc public static var isStarted: Bool { LightSession.isStarted }
    /// `nil` when nothing is being recorded, which Objective-C reads as `nil` rather than as an empty string.
    @objc public static var currentSessionId: String? { LightSession.currentSessionId }
}

private extension [String: Any] {
    /// The first of these keys that holds a usable string.
    ///
    /// Exists because one config object configures two platforms and the two spell URLs differently.
    func firstString(_ keys: String...) -> String? {
        for key in keys {
            if let value = trimmedString(key) { return value }
        }
        return nil
    }

    func trimmedString(_ key: String) -> String? {
        guard let raw = self[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func bool(_ key: String, _ fallback: Bool) -> Bool {
        // `NSNumber` covers both a JavaScript boolean and a JavaScript 0/1, which is what actually arrives.
        (self[key] as? NSNumber)?.boolValue ?? (self[key] as? Bool) ?? fallback
    }

    /// A JavaScript number is a double, so a duration arrives as one and has to come back as an Int64.
    ///
    /// Read as an `Int` this would wrap past about 24 days of milliseconds — not a duration anyone configures,
    /// but the same read is used for capture intervals, where a wrong number changes how often the screen is
    /// captured.
    func millis(_ key: String, _ fallback: Int64) -> Int64 {
        guard let number = self[key] as? NSNumber else { return fallback }
        return Int64(number.doubleValue)
    }
}
#endif
