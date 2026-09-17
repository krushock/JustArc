import Foundation

/// Works out which entries would land on something that is already there, so the
/// caller can ask what to do instead of quietly renaming files.
public enum ExtractionConflicts {
    public struct Report: Sendable {
        /// Archive paths that already exist at the destination, in archive order.
        public let paths: [String]
        /// The total count, which can exceed `paths` when the scan stopped early.
        public let count: Int

        public var isEmpty: Bool { count == 0 }

        public init(paths: [String], count: Int) {
            self.paths = paths
            self.count = count
        }
    }

    /// - Parameter sampleLimit: how many names to keep for showing to the user.
    ///   Scanning stops once the count is known to be large, since the exact number
    ///   stops being interesting.
    public static func find(entries: [ArchiveEntry],
                            in destination: URL,
                            sampleLimit: Int = 5,
                            scanLimit: Int = 20_000) -> Report {
        var sample: [String] = []
        var count = 0
        var scanned = 0

        for entry in entries {
            guard !entry.isDirectory else { continue }
            scanned += 1
            if scanned > scanLimit { break }

            guard PathSafety.isSafe(entryPath: entry.path) else { continue }
            let candidate = destination.appendingPathComponent(entry.path)
            guard PathSafety.itemExists(at: candidate) else { continue }

            count += 1
            if sample.count < sampleLimit { sample.append(entry.path) }
        }
        return Report(paths: sample, count: count)
    }
}
