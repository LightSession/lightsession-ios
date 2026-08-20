import Foundation

/// A URL path with its dynamic segments replaced, computed **on the device**.
///
/// The Android SDK's `PathTemplate`, rule for rule, and it has to be: an endpoint list groups by
/// this string, and a query that cared which platform sent it would not be an endpoint list. Where
/// the two ever disagree, one platform's `/v1/users/{id}` and the other's `/v1/users/84321` become
/// two rows for one endpoint — and the second one is a leak.
///
/// ## Which way to be wrong
///
/// Two failures, and they are not symmetric.
///
/// **Over-collapsing** merges two endpoints into one row. A reader sees `/v1/{id}` where they
/// expected `/v1/status`, which is visible, and revisable.
///
/// **Under-collapsing** stores an id — often a token — in a column with a thirteen-month TTL, and
/// mints one endpoint per value, so the list this exists to produce fills with a million rows of
/// one call each. Invisible until somebody reads the table, and permanent.
///
/// So a segment survives only when it looks like a word somebody typed into a route. The same
/// asymmetry `ScreenIdentity.subScreenLabel` settles the same way for a label.
///
/// ## What is never included
///
/// The query and the fragment, at all. `?token=`, `?api_key=`, `#access_token=` — no rule about
/// their *contents* is worth trusting, so they are not read. The ingest strips them again if one
/// arrives anyway, and that second line is not a reason to relax this one: a token that reaches
/// the server has already left the customer's building.
enum PathTemplate {

    /// Longest segment that can still be a word rather than a value.
    private static let maxWord = 24

    /// Past this, a segment holding both letters and digits is an id or a hash. Below it, `v2`,
    /// `api1` and `oauth2` are ordinary route words.
    private static let maxMixedWord = 12

    /// Collapses a path.
    ///
    /// Answers `""` for anything that is not a path, which the caller reports as "no endpoint"
    /// rather than guessing — the same refusal the ingest makes, for the same reason.
    static func of(_ rawPath: String) -> String {
        let path = rawPath
            .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, path.hasPrefix("/") else { return "" }
        if path == "/" { return "/" }

        let collapsed = path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : collapse(String($0)) }
            .joined(separator: "/")

        // A path is a key in a column, not a place to put an essay. A template this long means the
        // collapsing did not recognise what it was looking at.
        return collapsed.count > 200 ? "" : collapsed
    }

    private static func collapse(_ segment: String) -> String {
        if isUUID(segment) { return "{uuid}" }
        if segment.allSatisfy(\.isNumber) { return "{id}" }
        // Before the extension rule below, and the ordering is a fix rather than a preference: an
        // email has a dot in it, so letting the extension rule look first turned
        // `maria@example.com` into `{id}.com` and published the domain. Measured on the Android
        // side; ported with the fix rather than the bug.
        if !isRouteAlphabet(segment) { return "{id}" }
        return collapseWord(segment)
    }

    /// The characters a hand-written route uses. `.` is here for file names and is why the rule
    /// above runs first; everything else — `@`, `+`, `,`, `%`, `=`, `:` — appears in a value.
    private static func isRouteAlphabet(_ segment: String) -> Bool {
        segment.allSatisfy { character in
            character.isLetter || character.isNumber
                || character == "-" || character == "_" || character == "~" || character == "."
        }
    }

    private static func collapseWord(_ segment: String) -> String {
        if let dot = segment.lastIndex(of: ".") {
            let stem = String(segment[segment.startIndex..<dot])
            let extensionPart = String(segment[segment.index(after: dot)...])
            // A real extension, not a domain suffix: short, alphanumeric, with a name in front.
            // `/assets/logo.png` and `/assets/{id}.png` are different questions, and the extension
            // is not data.
            if !stem.isEmpty,
               !extensionPart.isEmpty,
               extensionPart.count <= 5,
               extensionPart.allSatisfy({ $0.isLetter || $0.isNumber }) {
                // The stem goes back through `collapse`, not straight to `collapseWord`: an id
                // with a file extension on it is still an id. Sending the stem to `collapseWord`
                // skipped the digit and UUID rules, so `/assets/8842.png` published `8842` and
                // minted one endpoint per file — under-collapsing, which is the failure that
                // cannot be seen or undone.
                return collapse(stem) + "." + extensionPart
            }
        }
        if segment.count > maxWord { return "{id}" }
        if segment.count > maxMixedWord,
           segment.contains(where: \.isNumber),
           segment.contains(where: \.isLetter) {
            return "{id}"
        }
        return segment
    }

    /// `8-4-4-4-12` hex. Written out rather than through `UUID(uuidString:)`, which accepts forms
    /// this must not — a bare 32-hex run is a hash and belongs in `{id}`.
    private static func isUUID(_ segment: String) -> Bool {
        let groups = segment.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count == 5 else { return false }
        let lengths = [8, 4, 4, 4, 12]
        for (group, length) in zip(groups, lengths) {
            guard group.count == length, group.allSatisfy(\.isHexDigit) else { return false }
        }
        return true
    }
}
