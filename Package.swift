// swift-tools-version:5.9
import PackageDescription

/// Two platforms on purpose, and only one of them ships.
///
/// iOS is the product. macOS is here so the decisions — how a screen is named, which widget a view
/// classifies as, what the wire payload looks like — can be tested with `swift test` in about a
/// second, with no simulator involved. Everything that touches UIKit sits behind
/// `#if canImport(UIKit)`, so the macOS build sees the logic and not the platform.
///
/// This is the split that paid for itself on Android: the screen-source decision was nested
/// branching that got two of its four cases wrong for nineteen commits, and it only became provable
/// once it was a pure function a JVM test could walk end to end.
let package = Package(
    name: "LightSession",
    platforms: [
        // 15 rather than 13: finding the key window through `UIWindowScene` needs it, and going
        // lower would mean a second code path for that — the kind of duplication that rots because
        // only one branch is ever exercised.
        .iOS(.v15),
        .macOS(.v13),
    ],
    products: [
        .library(name: "LightSession", targets: ["LightSession"]),
    ],
    targets: [
        .target(name: "LightSession"),
        .testTarget(name: "LightSessionTests", dependencies: ["LightSession"]),
    ]
)
