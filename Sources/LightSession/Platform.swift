/// The platform this SDK runs on, as the server names it.
///
/// Every write carries it, and the server checks it against the project the API key belongs to. A project
/// created for iOS refuses `android`, a project created for React Native or Flutter accepts both — one
/// codebase, two platforms — and a project whose SDK is too old to send anything is accepted as before.
///
/// It exists because of a mistake that has already happened, in the other direction: an Android project's key
/// was pasted into an iOS integration and nothing objected. Both apps reported into the same project, the
/// screen map filled with the screens of two different apps, and the only symptom was somebody looking at the
/// graph and not recognising it. The key alone cannot tell the two apart — it identifies a project, not a
/// platform — so the report has to say.
///
/// A constant rather than something read from `UIDevice`: this artifact only ever runs on Apple's platforms,
/// so anything else it could report would be a lie. `ios` covers iPadOS too, which the server folds into the
/// same value — the distinction the check cares about is which SDK is talking, and there is one SDK here.
///
/// This is also what makes React Native correct for free. That package contains no SDK of its own; it depends
/// on this one on iOS and on the Android artifact on Android, so whichever is actually making the request is
/// the one that names the platform, and the two can never disagree.
enum Platform {
    static let name = "ios"
}
