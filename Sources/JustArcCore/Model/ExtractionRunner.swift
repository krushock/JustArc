import Foundation

/// Everything needed to extract once the user has answered any conflict questions.
public struct ExtractionJob: Sendable {
    public var archive: URL
    public var destination: URL
    public var password: String?
    /// Every entry in the archive, needed for filtering.
    public var allEntries: [ArchiveEntry]
    /// What the user picked. Nil means the whole archive, which lets the engine skip
    /// building a file list.
    public var selectedEntries: [ArchiveEntry]?
    /// Top-level archive paths being written, such as ["Project"].
    public var roots: [String]
    /// Which of those roots already exist at the destination as folders.
    public var folderConflicts: [String]
    public var folderResolution: FolderConflictResolution
    public var fileOverwrite: OverwriteMode

    public init(archive: URL,
                destination: URL,
                password: String? = nil,
                allEntries: [ArchiveEntry],
                selectedEntries: [ArchiveEntry]? = nil,
                roots: [String],
                folderConflicts: [String] = [],
                folderResolution: FolderConflictResolution = .merge,
                fileOverwrite: OverwriteMode = .renameNew) {
        self.archive = archive
        self.destination = destination
        self.password = password
        self.allEntries = allEntries
        self.selectedEntries = selectedEntries
        self.roots = roots
        self.folderConflicts = folderConflicts
        self.folderResolution = folderResolution
        self.fileOverwrite = fileOverwrite
    }
}

public struct ExtractionOutcome: Sendable {
    /// What ended up at the destination, which is what Finder should select.
    /// Keeping both renames as it goes, so these are not always the archive's names.
    public let producedItems: [URL]
    public let skippedFolders: [String]
    public let trashedFolders: [String]

    public var extractedNothing: Bool { producedItems.isEmpty }
}

/// Carries out an extraction, applying the folder decision before handing the rest
/// to the engine.
public enum ExtractionRunner {
    public static func run(_ job: ExtractionJob,
                           engine: ArchiveEngine,
                           cancellation: CancellationToken? = nil,
                           progress: ProgressHandler? = nil) async throws -> ExtractionOutcome {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: job.destination, withIntermediateDirectories: true)

        switch job.folderResolution {
        case .keepBoth where !job.folderConflicts.isEmpty:
            return try await extractAlongside(job, engine: engine,
                                              cancellation: cancellation, progress: progress)

        case .skip where !job.folderConflicts.isEmpty:
            return try await extractSkippingFolders(job, engine: engine,
                                                    cancellation: cancellation, progress: progress)

        case .replace where !job.folderConflicts.isEmpty:
            var trashed: [String] = []
            for folder in job.folderConflicts {
                let existing = try PathSafety.resolvedURL(for: folder, in: job.destination)
                guard PathSafety.itemExists(at: existing) else { continue }
                // Whatever the archive calls its entries, the folder being extracted
                // into is never one of the things replaced.
                guard existing.standardizedFileURL != PathSafety.canonicalRoot(job.destination) else { continue }
                try moveToTrashOrDelete(existing)
                trashed.append(folder)
            }
            let produced = try await extractDirectly(job, engine: engine,
                                                     cancellation: cancellation, progress: progress)
            return ExtractionOutcome(producedItems: produced, skippedFolders: [], trashedFolders: trashed)

        case .merge, .replace, .keepBoth, .skip:
            let produced = try await extractDirectly(job, engine: engine,
                                                     cancellation: cancellation, progress: progress)
            return ExtractionOutcome(producedItems: produced, skippedFolders: [], trashedFolders: [])
        }
    }

    // MARK: - Strategies

    private static func extractDirectly(_ job: ExtractionJob,
                                        engine: ArchiveEngine,
                                        cancellation: CancellationToken?,
                                        progress: ProgressHandler?) async throws -> [URL] {
        let before = Neighbours(of: job.roots, in: job.destination)
        try await engine.extract(archive: job.archive,
                                 entries: job.selectedEntries,
                                 to: job.destination,
                                 password: job.password,
                                 overwrite: job.fileOverwrite,
                                 flattenPaths: false,
                                 cancellation: cancellation,
                                 progress: progress)
        return before.produced(after: job.fileOverwrite)
    }

    /// What sat beside each extracted item before extraction, so that what is new
    /// afterwards can be told from what was already there.
    ///
    /// An item whose name was taken comes out as "name 2". Showing the Finder the
    /// archive's own name would then select the file that was there all along.
    struct Neighbours {
        private let roots: [String]
        private let destination: URL
        private var namesBefore: [String: Set<String>] = [:]

        init(of roots: [String], in destination: URL) {
            self.roots = roots
            self.destination = destination
            for root in roots {
                let parent = Self.parent(of: root)
                guard namesBefore[parent] == nil else { continue }
                namesBefore[parent] = Self.names(in: destination.appendingPathComponent(parent))
            }
        }

        func produced(after overwrite: OverwriteMode) -> [URL] {
            var result: [URL] = []
            var seen = Set<URL>()
            for root in roots {
                let normalized = ArchivePath.normalize(root)
                guard !normalized.isEmpty, PathSafety.isSafe(entryPath: normalized) else { continue }
                let parent = Self.parent(of: normalized)
                let folder = destination.appendingPathComponent(parent)
                let name = (normalized as NSString).lastPathComponent
                var target = folder.appendingPathComponent(name)

                // With "rename the existing one" the new item has the archive's name
                // and the old one moved; in every other case a new numbered sibling
                // is the item that was just extracted.
                if overwrite != .renameExisting, namesBefore[parent]?.contains(name) == true,
                   let renamed = Self.newestVariant(of: name, in: folder, notIn: namesBefore[parent] ?? []) {
                    target = renamed
                }
                guard PathSafety.itemExists(at: target), seen.insert(target).inserted else { continue }
                result.append(target)
                if result.count >= 50 { break }
            }
            return result
        }

        private static func parent(of path: String) -> String {
            let normalized = ArchivePath.normalize(path)
            guard let slash = normalized.lastIndex(of: "/") else { return "" }
            return String(normalized[..<slash])
        }

        private static func names(in folder: URL) -> Set<String> {
            Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        }

        /// The highest-numbered "name N.ext" in `folder` that was not there before.
        private static func newestVariant(of name: String, in folder: URL, notIn before: Set<String>) -> URL? {
            let ext = (name as NSString).pathExtension
            let base = ext.isEmpty || name.hasPrefix(".") && name.dropFirst().firstIndex(of: ".") == nil
                ? name : (name as NSString).deletingPathExtension
            let suffix = base == name ? "" : "." + ext
            var best: (number: Int, name: String)?
            for candidate in names(in: folder).subtracting(before)
            where candidate.hasPrefix(base + " ") && candidate.hasSuffix(suffix) {
                let middle = candidate.dropFirst(base.count + 1).dropLast(suffix.count)
                guard let number = Int(middle), number >= 2 else { continue }
                if best == nil || number > best!.number { best = (number, candidate) }
            }
            return best.map { folder.appendingPathComponent($0.name) }
        }
    }

    /// Leaves the existing folders untouched by dropping everything inside them.
    private static func extractSkippingFolders(_ job: ExtractionJob,
                                               engine: ArchiveEngine,
                                               cancellation: CancellationToken?,
                                               progress: ProgressHandler?) async throws -> ExtractionOutcome {
        let source = job.selectedEntries ?? job.allEntries
        let kept = source.filter { entry in
            !job.folderConflicts.contains { entry.path == $0 || entry.path.hasPrefix($0 + "/") }
        }

        guard !kept.isEmpty else {
            return ExtractionOutcome(producedItems: [],
                                     skippedFolders: job.folderConflicts,
                                     trashedFolders: [])
        }

        try await engine.extract(archive: job.archive,
                                 entries: kept,
                                 to: job.destination,
                                 password: job.password,
                                 overwrite: job.fileOverwrite,
                                 flattenPaths: false,
                                 cancellation: cancellation,
                                 progress: progress)

        let remainingRoots = job.roots.filter { !job.folderConflicts.contains($0) }
        let produced = ExtractionPlan.revealTargets(forArchivePaths: remainingRoots, in: job.destination)
            .filter { $0 != job.destination }
        return ExtractionOutcome(producedItems: produced,
                                 skippedFolders: job.folderConflicts,
                                 trashedFolders: [])
    }

    /// Extracts into a hidden staging folder inside the destination, then moves each
    /// top-level item in under a free name. Staging inside the destination keeps every
    /// move on the same volume, so it is a rename rather than a copy.
    private static func extractAlongside(_ job: ExtractionJob,
                                         engine: ArchiveEngine,
                                         cancellation: CancellationToken?,
                                         progress: ProgressHandler?) async throws -> ExtractionOutcome {
        let fileManager = FileManager.default
        let staging = job.destination.appendingPathComponent(".justarc-extract-\(UUID().uuidString)")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        try await engine.extract(archive: job.archive,
                                 entries: job.selectedEntries,
                                 to: staging,
                                 password: job.password,
                                 overwrite: .overwrite,
                                 flattenPaths: false,
                                 cancellation: cancellation,
                                 progress: progress)

        if cancellation?.isCancelled == true { throw ArchiveError.cancelled }

        var produced: [URL] = []
        let contents = try fileManager.contentsOfDirectory(at: staging,
                                                           includingPropertiesForKeys: nil,
                                                           options: [])
        for item in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let wanted = job.destination.appendingPathComponent(item.lastPathComponent)
            var target = PathSafety.uniqueURL(for: wanted)

            // "Keep both" was the answer about folders. A loose file at the top that
            // collides with a file follows the answer given about files.
            let isFolder = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if !isFolder, PathSafety.itemExists(at: wanted), !ExtractionConflicts.isDirectory(wanted) {
                switch job.fileOverwrite {
                case .skip:
                    continue
                case .overwrite:
                    _ = try fileManager.replaceItemAt(wanted, withItemAt: item)
                    produced.append(wanted)
                    continue
                case .renameExisting:
                    try fileManager.moveItem(at: wanted, to: target)
                    target = wanted
                case .renameNew:
                    break
                }
            }
            try fileManager.moveItem(at: item, to: target)
            produced.append(target)
        }
        return ExtractionOutcome(producedItems: produced, skippedFolders: [], trashedFolders: [])
    }

    /// Replacing a folder should be recoverable, so it goes to the Trash rather than
    /// being deleted outright. Only a volume that has no Trash falls back to removal;
    /// any other failure stops the extraction, since deleting for good is not what
    /// the dialog offered.
    static func moveToTrashOrDelete(_ url: URL) throws {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch let error as CocoaError where error.code == .featureUnsupported {
            Diagnostics.log("no Trash on the volume holding \(url.lastPathComponent), deleting instead")
            try FileManager.default.removeItem(at: url)
        } catch {
            throw ArchiveError.ioFailure(
                L("%@ could not be moved to the Trash, so it was left as it is. %@",
                  url.lastPathComponent, error.localizedDescription))
        }
    }
}
