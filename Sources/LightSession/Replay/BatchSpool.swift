import Foundation

/// Batches waiting on disk for the network to work.
///
/// The reason this exists rather than a retry in memory: an upload that fails is usually a connection that is
/// not there, and a connection that is not there tends to stay away for longer than the app stays open. Before
/// this, a failed batch was logged and dropped — a person who used the app on the underground lost everything
/// they did there.
///
/// The split that makes it work is that **recording and uploading are separate jobs**. Recording writes a file
/// and is done; uploading reads files and deletes each one only once the server has taken it. Whoever produced
/// the data no longer has to survive long enough for a request to finish, which is the part that used to be
/// wrong: on Android a flush was only as good as the request it fired, and the app being killed took the
/// buffer with it.
///
/// `FileManager` works on macOS as well as iOS, so this is not behind `#if canImport(UIKit)` and is tested
/// against a real temporary directory rather than a mock. Files are what this is about; mocking them would
/// test the wrong thing.
public final class BatchSpool {

    /// What kind of batch an entry holds. Breadcrumbs go first when draining.
    ///
    /// They are two orders of magnitude smaller than frames and they are the only record that a tap happened,
    /// so a slow frame upload must not sit in front of them.
    public enum Kind: String, Sendable, CaseIterable {
        case breadcrumbs
        case frames
    }

    /// One batch on disk.
    public struct Entry: Equatable, Sendable {
        public let kind: Kind
        public let directory: URL
        /// Sorts oldest first. Part of the directory name rather than read from the file system, because
        /// creation dates are not reliably preserved by every copy and a batch's order is not negotiable.
        public let sequence: Int
    }

    /// Beyond this, the oldest entries are deleted.
    ///
    /// A recorder must not fill someone's phone because their network has been down for a week. Dropping the
    /// oldest keeps the recent part of the session, which is the part worth watching.
    public let maxBytes: Int

    private let root: URL
    private let fileManager: FileManager
    private var nextSequence: Int

    public init(root: URL, maxBytes: Int = 32 * 1024 * 1024, fileManager: FileManager = .default) throws {
        self.root = root
        self.maxBytes = maxBytes
        self.fileManager = fileManager
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        // Continues where a previous run left off, so a batch written before a restart still sorts before one
        // written after it. Starting from zero would upload them out of order, and the sequence is what a
        // replay's timeline is rebuilt from.
        self.nextSequence = (try? Self.highestSequence(in: root, fileManager: fileManager)).flatMap { $0 + 1 } ?? 0
    }

    // MARK: - Writing

    /// Writes a breadcrumb batch. The fields are exactly what the request will carry.
    @discardableResult
    public func write(breadcrumbs fields: [String: String]) throws -> Entry {
        let entry = try makeEntry(kind: .breadcrumbs)
        let data = try JSONSerialization.data(withJSONObject: fields)
        try data.write(to: entry.directory.appendingPathComponent("fields.json"))
        try commit(entry)
        return entry
    }

    /// Writes a frame batch: the metadata, and one file per frame.
    ///
    /// The frame's own file name carries its sequence and timestamp, and is the name the request will use, so
    /// a batch written by an older build still uploads with the identity it was created with.
    @discardableResult
    public func write(frames: [ReplayFrame], metadata: [String: String]) throws -> Entry {
        let entry = try makeEntry(kind: .frames)
        let data = try JSONSerialization.data(withJSONObject: metadata)
        try data.write(to: entry.directory.appendingPathComponent("meta.json"))
        // Zero-padded, so a plain lexical sort of the directory is the frames' real order. Without the padding
        // `frame_10` sorts before `frame_9` and the replay plays out of sequence.
        for (index, frame) in frames.enumerated() {
            let name = String(format: "%05d_", index) + frame.fileName
            try frame.data.write(to: entry.directory.appendingPathComponent(name))
        }
        try commit(entry)
        return entry
    }

    // MARK: - Reading

    /// Everything waiting, breadcrumbs first and oldest first within each kind.
    public func pending() -> [Entry] {
        let entries = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return entries
            .compactMap(Self.parse)
            .sorted { left, right in
                if left.kind != right.kind { return left.kind == .breadcrumbs }
                return left.sequence < right.sequence
            }
    }

    /// The fields a breadcrumb entry was written with.
    public func fields(of entry: Entry) -> [String: String]? {
        guard entry.kind == .breadcrumbs else { return nil }
        guard let data = try? Data(contentsOf: entry.directory.appendingPathComponent("fields.json")) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }

    /// The metadata and frames a frame entry was written with, in order.
    public func frames(of entry: Entry) -> (metadata: [String: String], frames: [ReplayFrame])? {
        guard entry.kind == .frames else { return nil }
        guard
            let metaData = try? Data(contentsOf: entry.directory.appendingPathComponent("meta.json")),
            let metadata = (try? JSONSerialization.jsonObject(with: metaData)) as? [String: String],
            let names = try? fileManager.contentsOfDirectory(atPath: entry.directory.path)
        else { return nil }

        var frames: [ReplayFrame] = []
        for name in names.sorted() where name != "meta.json" {
            guard let data = try? Data(contentsOf: entry.directory.appendingPathComponent(name)) else { continue }
            guard let frame = Self.parseFrame(fileName: name, data: data) else { continue }
            frames.append(frame)
        }
        return (metadata, frames)
    }

    /// Removes an entry, which is what "the server has it" means.
    public func remove(_ entry: Entry) {
        try? fileManager.removeItem(at: entry.directory)
    }

    /// Total bytes on disk.
    public func size() -> Int {
        pending().reduce(0) { total, entry in
            total + Self.size(of: entry.directory, fileManager: fileManager)
        }
    }

    /// Deletes the oldest entries until the spool is under its ceiling. Returns how many went.
    ///
    /// Frames first among equals: a frame batch is tens of kilobytes and the frame beside it looks almost
    /// identical, while a breadcrumb is a few hundred bytes and is the only record that a tap happened.
    @discardableResult
    public func prune() -> Int {
        var removed = 0
        var remaining = pending()
        var total = remaining.reduce(0) { $0 + Self.size(of: $1.directory, fileManager: fileManager) }
        // Oldest frames first, then oldest breadcrumbs — the reverse of the drain order, deliberately.
        let victims = remaining
            .sorted { left, right in
                if left.kind != right.kind { return left.kind == .frames }
                return left.sequence < right.sequence
            }
        for entry in victims where total > maxBytes {
            total -= Self.size(of: entry.directory, fileManager: fileManager)
            remove(entry)
            removed += 1
        }
        remaining = []
        return removed
    }

    // MARK: - Internals

    /// A batch is built in a staging directory and renamed into place.
    ///
    /// So a crash halfway through writing twenty-four frames leaves a staging directory that the drain does not
    /// see, rather than a batch that is missing frames the metadata claims are there. The rename is the commit.
    private func makeEntry(kind: Kind) throws -> Entry {
        let sequence = nextSequence
        nextSequence += 1
        let directory = root.appendingPathComponent(Self.stagingName(kind: kind, sequence: sequence))
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return Entry(kind: kind, directory: directory, sequence: sequence)
    }

    private func commit(_ entry: Entry) throws {
        let committed = root.appendingPathComponent(Self.name(kind: entry.kind, sequence: entry.sequence))
        try fileManager.moveItem(at: entry.directory, to: committed)
        prune()
    }

    private static let stagingPrefix = "staging-"

    private static func name(kind: Kind, sequence: Int) -> String {
        String(format: "%@-%09d", kind.rawValue, sequence)
    }

    private static func stagingName(kind: Kind, sequence: Int) -> String {
        stagingPrefix + name(kind: kind, sequence: sequence)
    }

    private static func parse(_ url: URL) -> Entry? {
        let name = url.lastPathComponent
        // Staging directories are invisible to the drain: they are batches that were never finished.
        guard !name.hasPrefix(stagingPrefix) else { return nil }
        let parts = name.split(separator: "-")
        guard parts.count == 2, let kind = Kind(rawValue: String(parts[0])), let sequence = Int(parts[1]) else {
            return nil
        }
        return Entry(kind: kind, directory: url, sequence: sequence)
    }

    /// Recovers a frame from the name it was written under.
    ///
    /// The name is the source of truth for sequence, timestamp and kind, because that is what the upload sends
    /// and what the server keys on. Parsed rather than stored separately so there is one copy of it.
    static func parseFrame(fileName: String, data: Data) -> ReplayFrame? {
        // `00003_frame_57_1785467868670.jpg` or `00004_repeated_signal_58_…​.signal`
        let withoutOrder = fileName.drop(while: { $0 != "_" }).dropFirst()
        let isRepeat = withoutOrder.hasPrefix("repeated_signal_")
        let body = withoutOrder
            .replacingOccurrences(of: "repeated_signal_", with: "")
            .replacingOccurrences(of: "frame_", with: "")
        let stem = body.split(separator: ".").first.map(String.init) ?? body
        let numbers = stem.split(separator: "_")
        guard numbers.count == 2, let sequence = Int(numbers[0]), let timestamp = Int64(numbers[1]) else {
            return nil
        }
        return ReplayFrame(data: data, isRepeat: isRepeat, sequence: sequence, timestampMillis: timestamp)
    }

    private static func highestSequence(in root: URL, fileManager: FileManager) throws -> Int? {
        try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .compactMap(parse)
            .map(\.sequence)
            .max()
    }

    private static func size(of directory: URL, fileManager: FileManager) -> Int {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return 0 }
        return names.reduce(0) { total, name in
            let path = directory.appendingPathComponent(name).path
            let attributes = try? fileManager.attributesOfItem(atPath: path)
            return total + ((attributes?[.size] as? Int) ?? 0)
        }
    }
}
