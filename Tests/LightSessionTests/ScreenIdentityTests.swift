import XCTest
@testable import LightSession

/// How a type name becomes a screen name, and why each rule is there.
final class ScreenIdentityTests: XCTestCase {

    /// `NSStringFromClass` returns the module-qualified name. The module is noise, and worse: it would
    /// change the identity of every screen in the app the day someone renames the target.
    func testModuleQualifierIsDropped() {
        XCTAssertEqual(ScreenIdentity.screenName(fromTypeName: "Example.HomeViewController"), "HomeViewController")
    }

    func testNestedTypesKeepOnlyTheInnermostName() {
        XCTAssertEqual(ScreenIdentity.screenName(fromTypeName: "App.Feature.DetailController"), "DetailController")
    }

    func testGenericParametersAreStripped() {
        XCTAssertEqual(ScreenIdentity.screenName(fromTypeName: "SwiftUI.UIHostingController<Example.RootView>"),
                       "UIHostingController")
    }

    /// Tempting to strip, and wrong: a `SettingsViewController` and a SwiftUI screen the app names
    /// `Settings` are different screens, and collapsing them merges two unrelated nodes in the graph.
    func testViewControllerSuffixIsKept() {
        XCTAssertEqual(ScreenIdentity.screenName(fromTypeName: "SettingsViewController"), "SettingsViewController")
    }

    func testEmptyNameDegradesRatherThanProducingAnEmptyScreen() {
        XCTAssertEqual(ScreenIdentity.screenName(fromTypeName: "   "), "Unknown")
        XCTAssertEqual(ScreenIdentity.screenName(fromTypeName: "Module."), "Unknown")
    }

    /// The separator matches Android's byte for byte: a modal on iOS and a dialog on Android write into
    /// the same graph, and a different separator would make them different nodes for no visible reason.
    func testSubScreenComposition() {
        XCTAssertEqual(ScreenIdentity.compose(screen: "Home", subScreen: "Filters"), "Home › Filters")
        XCTAssertEqual(ScreenIdentity.compose(screen: "Home", subScreen: nil), "Home")
        XCTAssertEqual(ScreenIdentity.compose(screen: "Home", subScreen: "  "), "Home",
                       "a blank part is no part, not an empty suffix")
    }

    /// The composite is what the SDK's own cache is keyed on, so two captures of one screen at
    /// different sizes or appearances have to differ here.
    func testCompositeIdSeparatesSizeAndTheme() {
        let portrait = ScreenIdentity.compositeId(name: "Home", appVersionName: "1.0", appVersionCode: 1,
                                                  width: 1170, height: 2532, theme: .light)
        let landscape = ScreenIdentity.compositeId(name: "Home", appVersionName: "1.0", appVersionCode: 1,
                                                   width: 2532, height: 1170, theme: .light)
        let dark = ScreenIdentity.compositeId(name: "Home", appVersionName: "1.0", appVersionCode: 1,
                                              width: 1170, height: 2532, theme: .dark)
        XCTAssertNotEqual(portrait, landscape)
        XCTAssertNotEqual(portrait, dark)
        XCTAssertEqual(portrait, "Home_1.0_1_1170_2532_Light")
    }
}

/// The kind a host-reported screen is recorded as.
///
/// `setScreen(_:)` has two kinds of caller — a SwiftUI app and a React Native app — and neither the call nor the
/// SDK can tell which is on the other end. Before this was configurable, a React Native screen arrived labelled
/// `SWIFTUI`: a lie that reads as a bug.
final class ReportedScreenKindTests: XCTestCase {

    func testTheWireWordsMatchWhatTheServerParses() {
        XCTAssertEqual(ScreenIdentity.Kind.uiKit.rawValue, "UIKIT")
        XCTAssertEqual(ScreenIdentity.Kind.swiftUI.rawValue, "SWIFTUI")
        // The same words the Android SDK sends, so one app's two builds land on one node in the graph rather
        // than on two that differ only by platform.
        XCTAssertEqual(ScreenIdentity.Kind.reactNative.rawValue, "REACT_NATIVE")
        XCTAssertEqual(ScreenIdentity.Kind.flutter.rawValue, "FLUTTER")
    }

    func testSwiftUIIsTheDefaultAndReactNativeIsOptedInto() {
        XCTAssertEqual(
            LightSessionConfig(apiKey: "k", apiURL: "u").reportedScreenKind, .swiftUI,
            "the common case needs no configuration"
        )
        XCTAssertEqual(
            LightSessionConfig(apiKey: "k", apiURL: "u", reportedScreenKind: .reactNative).reportedScreenKind,
            .reactNative
        )
    }

    /// The bridge sends the kind across as a string, so an unknown one must fall back rather than crash.
    ///
    /// This used to spell the unknown one `"FLUTTER"`, which stopped being unknown the day a Flutter SDK
    /// was written — and the test failed for the one reason a test should never fail, which is that the
    /// thing it was standing for came true. The placeholder is now a word no platform will ever send.
    func testAnUnknownKindIsNotRepresentable() {
        XCTAssertNil(ScreenIdentity.Kind(rawValue: "NOT_A_PLATFORM"))
        XCTAssertEqual(ScreenIdentity.Kind(rawValue: "REACT_NATIVE"), .reactNative)
        XCTAssertEqual(ScreenIdentity.Kind(rawValue: "FLUTTER"), .flutter)
    }
}
