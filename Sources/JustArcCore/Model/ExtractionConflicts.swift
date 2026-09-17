import Foundation

/// How to handle a folder at the destination that has the same name as one being
/// extracted. These mirror what Finder offers when you drop a folder onto a folder.
public enum FolderConflictResolution: String, Sendable, CaseIterable {
    /// Extract into the folder that is already there. Files inside it are then
    /// governed by the file-level rule.
    case merge
    /// Move the existing folder to the Trash, then extract a clean copy.
    case replace
    /// Extract alongside it under a new name, leaving the existing folder untouched.
    case keepBoth
    /// Leave the existing folder alone and extract nothing into it.
    case skip
}

/// Works out what is already at the destination, so the caller can ask what to do
/// instead of quietly renaming or merging.
public enum ExtractionConflicts {
    public struct Report: Sendable {
        /// Top-level names that already exist at the destination as folders.
        public let folders: [String]
        /// A sample of file paths that already exist, for showing to the user.
        public let files: [String]
        /// How many files collide in total, which can exceed `files`.
        public let fileCount: Int

        public var hasFolderConflicts: Bool { !folders.isEmpty }
        public var hasFileConflicts: Bool { fileCount > 0 }
        public var isEmpty: Bool { !hasFolderConflicts && !hasFileConflicts }

        public init(folders: [String], files: [String], fileCount: Int) {
            self.folders = folders
            self.files = files
            self.fileCount = fileCount
        }
    }

    /// - Parameters:
    ///   - roots: the top-level archive paths being written, such as ["Project"].
    ///   - sampleLimit: how many file names to keep for showing to the user.
    ///   - scanLimit: stops the file scan on very large archives, where the exact
    ///     number has long since stopped being interesting.
    public static func find(entries: [ArchiveEntry],
                            roots: [String],
                            in destination: URL,
                            sampleLimit: Int = 5,
                            scanLimit: Int = 20_000) -> Report {
        var folders: [String] = []
        for root in roots {
            let normalized = ArchivePath.normalize(root)
            guard !normalized.isEmpty, PathSafety.isSafe(entryPath: normalized) else { continue }
            guard isDirectory(destination.appendingPathComponent(normalized)) else { continue }
            if !folders.contains(normalized) { folders.append(normalized) }
        }

        var sample: [String] = []
        var fileCount = 0
        var scanned = 0

        for entry in entries {
            guard !entry.isDirectory else { continue }
            scanned += 1
            if scanned > scanLimit { break }

            guard PathSafety.isSafe(entryPath: entry.path) else { continue }
            let candidate = destination.appendingPathComponent(entry.path)
            guard PathSafety.itemExists(at: candidate), !isDirectory(candidate) else { continue }

            fileCount += 1
            if sample.count < sampleLimit { sample.append(entry.path) }
        }

        return Report(folders: folders, files: sample, fileCount: fileCount)
    }

    /// The file collisions that remain once a folder decision has been made.
    /// Replacing or renaming a folder removes every collision inside it, and skipping
    /// it means nothing there is written at all.
    public static func fileConflictsRemaining(after resolution: FolderConflictResolution,
                                              report: Report,
                                              entries: [ArchiveEntry],
                                              in destination: URL) -> Report {
        switch resolution {
        case .merge:
            return report
        case .replace, .keepBoth, .skip:
            let untouched = entries.filter { entry in
                !report.folders.contains { entry.path == $0 || entry.path.hasPrefix($0 + "/") }
            }
            return find(entries: untouched, roots: [], in: destination)
        }
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }
}
