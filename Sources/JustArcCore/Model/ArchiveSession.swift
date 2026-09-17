import Foundation

/// The state behind one browser window: an archive that may be open, plus any files
/// staged for writing. An untitled window is a session with no archive URL and only
/// staged items, which is what the empty WinRAR-style window shows.
public final class ArchiveSession {
    public private(set) var archiveURL: URL?
    public private(set) var listing: ArchiveListing
    public private(set) var tree: EntryTree
    public var password: String?
    public var encodingCodePage: Int?

    /// Top-level items the user added but has not written to an archive yet.
    public private(set) var stagedRoots: [URL] = []
    private(set) var stagedEntries: [ArchiveEntry] = []
    private(set) var stagedSources: [String: URL] = [:]

    /// Entries the user marked for removal, applied on the next save.
    public private(set) var pendingDeletions: Set<String> = []

    /// Resolved from the archive's format, so disk images use hdiutil and
    /// everything else uses 7-Zip.
    public var engine: ArchiveEngine { EngineFactory.engine(for: format) }

    public init(archiveURL: URL?) {
        self.archiveURL = archiveURL
        self.listing = ArchiveListing(info: ArchiveInfo(), entries: [])
        self.tree = EntryTree(entries: [])
    }

    // MARK: - Identity

    public var isUntitled: Bool { archiveURL == nil }

    public var displayName: String {
        archiveURL?.lastPathComponent ?? "Untitled Archive"
    }

    public var format: ArchiveFormat? {
        guard let archiveURL else { return FormatRegistry.format(forKey: "zip") }
        return FormatRegistry.format(for: archiveURL)
    }

    /// Whether entries can be added to or removed from the archive as it stands.
    /// Formats that can only be rebuilt, such as .tar.gz and disk images, say no
    /// here but can still be written with Save As.
    public var canModifyContents: Bool {
        guard let format else { return false }
        if archiveURL == nil { return true }
        if format.engine == .externalRAR { return EngineLocator.externalRAR != nil }
        return format.canWrite && format.canEditInPlace
    }

    /// True when the archive can be written at all, in this or another format.
    public var canSaveAs: Bool { true }

    public var isReadOnly: Bool { !canModifyContents }

    /// Releases anything the engine holds for this archive, such as a mounted disk image.
    public func close() {
        guard let archiveURL else { return }
        EngineFactory.engine(for: archiveURL).release(archive: archiveURL)
    }

    public var hasUnsavedChanges: Bool {
        !stagedRoots.isEmpty || !pendingDeletions.isEmpty
    }

    // MARK: - Loading

    public func load(cancellation: CancellationToken? = nil,
                     progress: ProgressHandler? = nil) async throws {
        guard let archiveURL else {
            rebuild()
            return
        }
        // A file from iCloud or Google Drive may still be a placeholder.
        try await CloudFile.materialize(archiveURL, cancellation: cancellation, progress: progress)
        let loaded = try await engine.list(archive: archiveURL,
                                           password: password,
                                           encodingCodePage: encodingCodePage)
        listing = loaded
        rebuild()
    }

    /// Every row the browser should show: archive contents plus staged files,
    /// minus anything queued for deletion.
    public var visibleEntries: [ArchiveEntry] {
        let existing = listing.entries.filter { !pendingDeletions.contains($0.path) }
        let staged = stagedEntries.filter { !pendingDeletions.contains($0.path) }
        var seen = Set<String>()
        var merged: [ArchiveEntry] = []
        // Staged files win, so replacing a file shows the new one.
        for entry in staged + existing where seen.insert(entry.path).inserted {
            merged.append(entry)
        }
        return merged
    }

    public func rebuild() {
        tree = EntryTree(entries: visibleEntries)
    }

    /// The on-disk file behind a staged entry, if this row has not been written yet.
    public func stagedSource(for path: String) -> URL? {
        stagedSources[ArchivePath.normalize(path)]
    }

    // MARK: - Editing

    @discardableResult
    public func stage(items: [URL]) -> [ArchiveEntry] {
        var added: [ArchiveEntry] = []
        for item in items {
            let standardized = item.standardizedFileURL
            guard !stagedRoots.contains(standardized) else { continue }
            stagedRoots.append(standardized)
            let produced = Self.enumerate(item: standardized)
            for entry in produced {
                stagedEntries.removeAll { $0.path == entry.path }
                stagedEntries.append(entry)
                pendingDeletions.remove(entry.path)
            }
            for (path, url) in Self.sourceMap(for: standardized) {
                stagedSources[path] = url
            }
            added.append(contentsOf: produced)
        }
        rebuild()
        return added
    }

    public func unstage(root: URL) {
        let standardized = root.standardizedFileURL
        stagedRoots.removeAll { $0 == standardized }
        let owned = Set(Self.sourceMap(for: standardized).keys)
        stagedEntries.removeAll { owned.contains($0.path) }
        for path in owned { stagedSources.removeValue(forKey: path) }
        rebuild()
    }

    public func markForDeletion(_ paths: [String]) {
        for path in paths {
            let normalized = ArchivePath.normalize(path)
            pendingDeletions.insert(normalized)
            // Deleting a staged root simply removes it again.
            if let source = stagedSources[normalized], stagedRoots.contains(source) {
                unstage(root: source)
                pendingDeletions.remove(normalized)
            }
        }
        rebuild()
    }

    public func clearPendingChanges() {
        stagedRoots.removeAll()
        stagedEntries.removeAll()
        stagedSources.removeAll()
        pendingDeletions.removeAll()
    }

    // MARK: - Saving

    /// Writes the session to `destination`. When the destination is the currently open
    /// archive and the format allows it, pending changes are applied in place; otherwise
    /// a new archive is built from scratch.
    public func save(to destination: URL,
                     options: CompressionOptions,
                     cancellation: CancellationToken? = nil,
                     progress: ProgressHandler? = nil) async throws {
        let sameFile = destination.standardizedFileURL == archiveURL?.standardizedFileURL
        let format = FormatRegistry.format(for: destination)
        guard let format, format.canWrite else {
            throw ArchiveError.notWritable(destination.pathExtension.uppercased())
        }

        if sameFile, format.canEditInPlace, !listing.entries.isEmpty {
            try await saveInPlace(destination: destination, options: options,
                                  cancellation: cancellation, progress: progress)
        } else {
            try await saveByRebuilding(destination: destination, options: options,
                                       cancellation: cancellation, progress: progress)
        }

        // Whatever the engine held for the previous file is stale now, whether we
        // wrote over it or wrote somewhere new.
        if let previous = archiveURL {
            EngineFactory.engine(for: previous).release(archive: previous)
        }
        archiveURL = destination
        clearPendingChanges()
        try await load()
    }

    private func saveInPlace(destination: URL,
                             options: CompressionOptions,
                             cancellation: CancellationToken?,
                             progress: ProgressHandler?) async throws {
        if !pendingDeletions.isEmpty {
            let victims = listing.entries.filter { pendingDeletions.contains($0.path) }
            try await engine.delete(entries: victims, from: destination, password: password)
        }
        if !stagedRoots.isEmpty {
            try await CloudFile.materializeAll(stagedRoots, cancellation: cancellation,
                                               progress: progress)
            try await engine.add(items: stagedRoots, to: destination, options: options,
                                 cancellation: cancellation, progress: progress)
        }
    }

    /// Extracts the current archive to a scratch folder, applies the pending edits there,
    /// then compresses the result into the destination format.
    private func saveByRebuilding(destination: URL,
                                  options: CompressionOptions,
                                  cancellation: CancellationToken?,
                                  progress: ProgressHandler?) async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("justarc-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var roots: [URL] = []

        if let archiveURL, !listing.entries.isEmpty {
            let keep = listing.entries.filter { !pendingDeletions.contains($0.path) && !$0.isDirectory }
            if !keep.isEmpty {
                let sourceEngine = EngineFactory.engine(for: archiveURL)
                try await sourceEngine.extract(archive: archiveURL, entries: keep, to: scratch,
                                               password: password, overwrite: .overwrite,
                                               flattenPaths: false, cancellation: cancellation,
                                               progress: progress)
                let contents = try FileManager.default.contentsOfDirectory(
                    at: scratch, includingPropertiesForKeys: nil)
                roots.append(contentsOf: contents)
            }
        }

        // Staged files may come from a cloud folder and still be placeholders.
        try await CloudFile.materializeAll(stagedRoots, cancellation: cancellation, progress: progress)
        roots.append(contentsOf: stagedRoots)
        guard !roots.isEmpty else {
            throw ArchiveError.ioFailure(L("There is nothing to save. Add files to the archive first."))
        }

        let temporaryArchive = scratch.deletingLastPathComponent()
            .appendingPathComponent("justarc-out-\(UUID().uuidString)-\(destination.lastPathComponent)")
        let destinationEngine = EngineFactory.engine(for: destination)
        try await destinationEngine.create(archive: temporaryArchive, items: roots, options: options,
                                           cancellation: cancellation, progress: progress)

        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporaryArchive)
        } else {
            try FileManager.default.moveItem(at: temporaryArchive, to: destination)
        }
    }

    // MARK: - Staging helpers

    /// Produces archive entries for a file or folder, with paths relative to its parent
    /// so a dropped folder keeps its own name at the archive root.
    static func enumerate(item: URL) -> [ArchiveEntry] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: item.path, isDirectory: &isDirectory) else { return [] }

        let base = item.lastPathComponent
        let attributes = try? fm.attributesOfItem(atPath: item.path)
        let modified = attributes?[.modificationDate] as? Date

        if !isDirectory.boolValue {
            let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
            return [ArchiveEntry(path: base, isDirectory: false, size: size,
                                 packedSize: 0, modified: modified)]
        }

        var results = [ArchiveEntry(path: base, isDirectory: true, modified: modified)]
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = fm.enumerator(at: item, includingPropertiesForKeys: keys,
                                         options: [.skipsPackageDescendants]) else {
            return results
        }
        let prefixLength = item.standardizedFileURL.path.count + 1
        for case let url as URL in walker {
            let full = url.standardizedFileURL.path
            guard full.count > prefixLength else { continue }
            let relative = String(full.dropFirst(prefixLength))
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDir = values?.isDirectory ?? false
            results.append(ArchiveEntry(path: ArchivePath.join(base, relative),
                                        isDirectory: isDir,
                                        size: UInt64(values?.fileSize ?? 0),
                                        packedSize: 0,
                                        modified: values?.contentModificationDate))
        }
        return results
    }

    static func sourceMap(for item: URL) -> [String: URL] {
        var map: [String: URL] = [:]
        let base = item.lastPathComponent
        map[base] = item
        for entry in enumerate(item: item) where entry.path != base {
            let relative = String(entry.path.dropFirst(base.count + 1))
            map[entry.path] = item.appendingPathComponent(relative)
        }
        return map
    }
}
