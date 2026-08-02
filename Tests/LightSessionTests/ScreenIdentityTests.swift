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

/// The rules that decide what a part of a screen is *called*, mirrored from the Android SDK's
/// `SubScreensTest` question for question — the two platforms write `Parent › Part` into one graph,
/// and a drift in folding or sanitising shows up as one platform's nodes quietly failing to match
/// the other's.
final class SubScreenPartsTests: XCTestCase {

    // ------------------------------------------------------------- labels

    func testALabelIsTrimmedAndItsWhitespaceCollapsed() {
        // A label that wraps arrives with the newline in it. Left alone, "Recent\nActivity" and
        // "Recent Activity" are two different screen names for one part.
        XCTAssertEqual(ScreenIdentity.subScreenLabel("  Recent\n  Activity "), "Recent Activity")
        XCTAssertEqual(ScreenIdentity.subScreenLabel("Overview"), "Overview")
    }

    func testAnEmptyOrBlankLabelIsNotALabel() {
        XCTAssertNil(ScreenIdentity.subScreenLabel(""))
        XCTAssertNil(ScreenIdentity.subScreenLabel("   \n "))
        XCTAssertNil(ScreenIdentity.subScreenLabel(nil))
    }

    func testAnOverLongLabelIsRejectedRatherThanTruncated() {
        // Long means the caller grabbed body text, and body text is per-user: truncating "Delete
        // Dr. Silva from the cardiology department?" would keep the screen-per-record bug and hide it.
        XCTAssertNil(ScreenIdentity.subScreenLabel("Delete Dr. Silva from the cardiology department?"))
    }

    func testALabelCannotSmuggleInTheSeparator() {
        XCTAssertEqual(ScreenIdentity.subScreenLabel("a › b"), "a b")
    }

    // ------------------------------------------------------------- layers

    func testPartsNestInOrder() {
        XCTAssertEqual(
            ScreenIdentity.compose(screen: "Login", parts: ["filters", "alert-4fab23"]),
            "Login › filters › alert-4fab23"
        )
    }

    func testNoPartsLeaveTheScreenAlone() {
        XCTAssertEqual(ScreenIdentity.compose(screen: "Login", parts: []), "Login")
    }

    func testAPartThatRepeatsTheOneBeneathFoldsIntoIt() {
        // A modal named like the panel it covers must not stutter: the redundancy rule reads the
        // name built so far, layer by layer, so `Filter › Filter` never happens.
        XCTAssertEqual(
            ScreenIdentity.compose(screen: "doctors", parts: ["Filter", "Filter"]),
            "doctors › Filter"
        )
    }

    func testAPartThatRepeatsTheScreenAddsNothing() {
        XCTAssertEqual(ScreenIdentity.compose(screen: "home", parts: ["Home"]), "home")
        // The leaf of a route, and spelling variants, count as repeats — the Android rule.
        XCTAssertEqual(ScreenIdentity.compose(screen: "app/home_feed", parts: ["Home Feed"]), "app/home_feed")
    }

    func testAPartThatOnlyResemblesTheScreenIsKept() {
        XCTAssertEqual(
            ScreenIdentity.compose(screen: "home", parts: ["Home Feed"]),
            "home › Home Feed"
        )
    }

    // ------------------------------------------------------------- alerts

    func testAnIdentifierNamesTheAlert() {
        XCTAssertEqual(
            ScreenIdentity.alertName(identifier: "confirm-delete", styleRaw: 1, actionStyleRaws: [0, 1], textFieldCount: 0),
            "confirm-delete"
        )
    }

    func testAnAlertKeepsOneNameWhenOnlyItsDataWouldDiffer() {
        // The Android measurement, restated: the name reads no text at all, so nothing the alert
        // displays can split it into a screen per record.
        let a = ScreenIdentity.alertName(identifier: nil, styleRaw: 1, actionStyleRaws: [0, 1], textFieldCount: 0)
        let b = ScreenIdentity.alertName(identifier: nil, styleRaw: 1, actionStyleRaws: [0, 1], textFieldCount: 0)
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.hasPrefix("alert-"), "no identifier, so it falls back to structure: \(a)")
    }

    func testAStructurallyDifferentAlertGetsADifferentName() {
        let confirm = ScreenIdentity.alertName(identifier: nil, styleRaw: 1, actionStyleRaws: [0, 1], textFieldCount: 0)
        let withField = ScreenIdentity.alertName(identifier: nil, styleRaw: 1, actionStyleRaws: [0, 1], textFieldCount: 1)
        let sheet = ScreenIdentity.alertName(identifier: nil, styleRaw: 0, actionStyleRaws: [0, 1], textFieldCount: 0)
        XCTAssertNotEqual(confirm, withField)
        XCTAssertNotEqual(confirm, sheet)
    }

    func testAnOverLongIdentifierFallsBackToStructure() {
        let name = ScreenIdentity.alertName(
            identifier: "an identifier long enough to be body text rather than a name",
            styleRaw: 1,
            actionStyleRaws: [0],
            textFieldCount: 0
        )
        XCTAssertTrue(name.hasPrefix("alert-"), "got \(name)")
    }
}
