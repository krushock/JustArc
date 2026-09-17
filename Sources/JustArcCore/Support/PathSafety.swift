import Foundation

/// Guards against zip-slip, symlink escapes and decompression bombs.
public enum PathSafety {
    public static let defaultMaxExpandedBytes: UInt64 = 64 * 1024 * 1024 * 1024
    public static let defaultMaxEntryCount = 500_000

    /// Rejects absolute paths, "..", home-relative paths and Windows drive prefixes.
    /// The raw string is inspected first, because normalising strips the leading slash
    /// that makes a path absolute.
    public static func isSafe(entryPath: String) -> Bool {
        let raw = entryPath.replacingOccurrences(of: "\\", with: "/")
        if raw.isEmpty { return false }
        if raw.hasPrefix("/") { return false }
        if raw.hasPrefix("~") { return false }
        let characters = Array(raw)
        if characters.count > 1, characters[1] == ":", characters[0].isLetter { return false }

        let normalized = ArchivePath.normalize(raw)
        if normalized.isEmpty { return false }
        for component in normalized.split(separator: "/") where component == ".." {
            return false
        }
        return true
    }

    public static func firstUnsafePath(in entries: [ArchiveEntry]) -> String? {
        entries.first { !isSafe(entryPath: $0.path) }?.path
    }

    /// Confirms a resolved destination really sits inside the extraction root.
    ///
    /// The root is resolved once and the target is built from it, so both sides of the
    /// containment check are spelled the same way. Standardising them separately does
    /// not work: `standardizedFileURL` rewrites `/private/tmp` to `/tmp` only when the
    /// path already exists, so an existing destination and its not-yet-created child
    /// end up with different prefixes and every entry looks like a traversal attempt.
    public static func resolvedURL(for entryPath: String, in destination: URL) throws -> URL {
        guard isSafe(entryPath: entryPath) else {
            throw ArchiveError.unsafeEntry(entryPath)
        }

        let root = canonicalRoot(destination)
        let target = root.appendingPathComponent(ArchivePath.normalize(entryPath))

        var rootPath = root.path
        if !rootPath.hasSuffix("/") { rootPath += "/" }
        guard target.path.hasPrefix(rootPath) else {
            throw ArchiveError.unsafeEntry(entryPath)
        }
        return target
    }

    /// One canonical spelling for an extraction root, used for every containment check.
    public static func canonicalRoot(_ destination: URL) -> URL {
        destination.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Existence check that does not follow symbolic links, so a link pointing at a
    /// missing file still counts as present and is never written through.
    public static func itemExists(at url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    public struct BombVerdict: Sendable {
        public let expandedBytes: UInt64
        public let entryCount: Int
        public let ratio: Double
        public let isSuspicious: Bool
    }

    /// A very high expansion ratio on a large payload is the classic bomb signature.
    public static func evaluate(listing: ArchiveListing,
                                maxExpandedBytes: UInt64 = defaultMaxExpandedBytes,
                                maxEntryCount: Int = defaultMaxEntryCount) -> BombVerdict {
        let expanded = listing.totalSize
        let physical = max(listing.info.physicalSize, 1)
        let ratio = Double(expanded) / Double(physical)
        let suspicious = expanded > maxExpandedBytes
            || listing.entries.count > maxEntryCount
            || (ratio > 1000 && expanded > 2 * 1024 * 1024 * 1024)
        return BombVerdict(expandedBytes: expanded,
                           entryCount: listing.entries.count,
                           ratio: ratio,
                           isSuspicious: suspicious)
    }

    /// Returns a URL that does not exist yet, appending " 2", " 3" and so on.
    public static func uniqueURL(for proposed: URL) -> URL {
        let fm = FileManager.default
        guard itemExists(at: proposed) else { return proposed }
        let directory = proposed.deletingLastPathComponent()
        let ext = proposed.pathExtension
        let base = proposed.deletingPathExtension().lastPathComponent
        var counter = 2
        while counter < 10_000 {
            var name = "\(base) \(counter)"
            if !ext.isEmpty { name += ".\(ext)" }
            let candidate = directory.appendingPathComponent(name)
            if !itemExists(at: candidate) { return candidate }
            counter += 1
        }
        return directory.appendingPathComponent("\(base) \(UUID().uuidString)")
    }
}
