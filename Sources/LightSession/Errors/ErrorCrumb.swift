import Foundation

/// An error, flattened into the JSON an error breadcrumb carries.
///
/// Pure — no UIKit, no clock, no singletons — because the two places it runs could not be more
/// different: `LightSession.captureError` on an ordinary thread, and the uncaught-exception handler
/// on a thread the process is about to die on. Everything here is bounded CPU over objects already
/// in memory, which is the entire budget a crash path has.
///
/// ## The shape, shared with Android
///
/// ```json
/// { "handled": false, "thread": "main", "thread_id": 259,
///   "exceptions": [ { "type": "...", "message": "...",
///                     "frames": [ {"class": "...", "method": "...", "in_app": true} ] } ] }
/// ```
///
/// `exceptions` is the cause chain, **outermost first** — index 0 is what reached the handler, the
/// last entry is the root cause. On this platform the chain is `NSUnderlyingErrorKey`, which is what
/// wrapping errors actually populate; the walk carries the same identity-set cycle guard as
/// Android's `getCause()` walk, because a userInfo that points back at its wrapper is constructible
/// and an unbounded walk inside a crash handler converts a crash with a report into a hang without
/// one.
///
/// ## What a frame is here
///
/// Symbolicated stack lines — `"4  ModuleName  0x… symbol + 123"` — parsed into the same field names
/// Android sends: `class` carries the binary image, `method` the symbol. There is no file or line
/// without a dSYM, and inventing them would only make the server's picture cleaner than the truth;
/// the fields are simply absent, which every consumer of this shape already tolerates.
///
/// `in_app` is a module-name match against the app's executable. It is the honest signal available
/// without configuration, with a known limit worth writing down: a statically linked library's
/// frames carry the app's module name, so they mark `in_app` too. The capture entry points drop
/// their own leading frames instead, which is where that limit actually bites.
enum ErrorCrumb {

    /// Chain links kept. Past this the chain is repetition, or a cycle the set already broke.
    static let maxCauses = 8

    /// Frames kept per link, from the top — the throw site, not the thousand loops below it.
    static let maxFrames = 120

    /// Characters of one message. Messages are built by string concatenation in `catch` blocks and
    /// have arrived carrying whole request bodies; two kilobytes keeps every message a person would
    /// read.
    static let maxMessage = 2_048

    /// The cause chain for a handled error. Only the first link carries a stack, because on this
    /// platform only the capture site has one — an `Error` value does not travel with a trace.
    static func exceptions(
        for error: Error,
        stack: [String],
        appModule: String
    ) -> [[String: Any]] {
        var links: [[String: Any]] = []
        // Identity, not equality: two distinct errors can compare equal, and the cycle being
        // guarded against is literally the same object appearing twice.
        var seen = Set<ObjectIdentifier>()
        var current: NSError? = error as NSError

        while let ns = current, links.count < maxCauses, seen.insert(ObjectIdentifier(ns)).inserted {
            let link: [String: Any] = [
                // The Swift type for the value that was thrown, the domain for the NSErrors under
                // it — each is the taxonomy its layer actually uses. Domain and code ride along on
                // every link: they are how this platform names errors, and the ingest stores crumb
                // fields verbatim, so an extra field costs nothing and answers questions later.
                "type": links.isEmpty ? String(reflecting: type(of: error)) : ns.domain,
                "message": String(ns.localizedDescription.prefix(maxMessage)),
                "domain": ns.domain,
                "code": ns.code,
                "frames": links.isEmpty ? frames(fromSymbols: stack, appModule: appModule) : [],
            ]
            links.append(link)
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return links
    }

    /// The single link an uncaught `NSException` carries — it has no cause chain, and its stack is
    /// the throw site's, recorded by the runtime when the exception was raised.
    static func exceptions(for exception: NSException, appModule: String) -> [[String: Any]] {
        var link: [String: Any] = [
            "type": exception.name.rawValue,
            "frames": frames(fromSymbols: exception.callStackSymbols, appModule: appModule),
        ]
        if let reason = exception.reason {
            link["message"] = String(reason.prefix(maxMessage))
        }
        return [link]
    }

    /// Parsed frames, capped with an elision marker so a truncated trace says so instead of ending
    /// mid-air.
    static func frames(fromSymbols symbols: [String], appModule: String) -> [[String: Any]] {
        var out = symbols.prefix(maxFrames).map { frame(fromSymbolLine: $0, appModule: appModule) }
        if symbols.count > maxFrames {
            out.append([
                "class": "…",
                "method": "\(symbols.count - maxFrames) frames elided",
                "in_app": false,
            ])
        }
        return out
    }

    /// One `callStackSymbols` line into one frame.
    ///
    /// The format is columns — index, module, address, symbol — but the module column can contain
    /// spaces ("My App"), so the address is the anchor: everything between the index and the first
    /// `0x…` token is the module, everything after it is the symbol. A line that does not parse is
    /// kept whole in `method` rather than dropped: an unreadable frame is still a frame, and a
    /// parser bug must not shorten a stack.
    static func frame(fromSymbolLine line: String, appModule: String) -> [String: Any] {
        guard let address = line.range(of: #"0x[0-9a-fA-F]+"#, options: .regularExpression) else {
            return ["class": "?", "method": line.trimmingCharacters(in: .whitespaces), "in_app": false]
        }

        var module = line[line.startIndex..<address.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        // Drop the leading frame index, keeping a module name with spaces intact.
        if let firstGap = module.firstIndex(where: { $0.isWhitespace }) {
            module = String(module[module.index(after: firstGap)...])
                .trimmingCharacters(in: .whitespaces)
        } else {
            module = "?"
        }

        let symbol = line[address.upperBound...].trimmingCharacters(in: .whitespaces)
        return [
            "class": module,
            "method": symbol.isEmpty ? "?" : symbol,
            "in_app": module == appModule,
        ]
    }
}
