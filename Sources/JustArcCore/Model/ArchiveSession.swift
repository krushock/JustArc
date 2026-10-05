import Foundation

/// The state behind one browser window: an archive that may be open, plus any files
/// staged for writing. An untitled window is a session with no archive URL and only
/// staged items, which is what the empty WinRAR-style window shows.
public final class ArchiveSession {
    public private(set) var archiveURL: URL?
    public private(set) var listing: ArchiveListing
    public private(set) var tree: EntryTree
    public var password: String?
    /// The encoding chosen for names that do not say what they are written in, or
    /// nil to work it out. The engines keep it for the archive, since extracting has
    /// to read the names the way listing them did.
    public var encodingCodePage: Int? {
        didSet {
            if let archiveURL { CodePageMemory.remember(encodingCodePage, for: archiveURL) }
        }
    }

    /// One thing the user added that has not been written yet: a file or folder on
    /// disk, and the folder inside the archive it is headed for.
    ///
    /// What it holds is recorded when it is staged. Reading the disk again later,
    /// to work out what a staged folder had contributed, gives a different answer
    /// once the folder has changed, and rows would be left behind that belong to
    /// nothing.
    private struct Staged {
        let url: URL
        let folder: String
        let entries: [ArchiveEntry]
        let sources: [String: URL]

        /// Where it sits in the archive.
        var path: String {
            ArchivePath.normalize(ArchivePath.join(folder, url.lastPathComponent))
        }

        /// A folder, as opposed to a file or a link to anything.
        var isFolder: Bool { entries.first?.isDirectory == true }
    }

    private var staged: [Staged] = []

    /// Top-level items the user added but has not written to an archive yet.
    public var stagedRoots: [URL] {
        var seen = Set<URL>()
        return staged.map(\.url).filter { seen.insert($0).inserted }
    }

    // Worked out from `staged` whenever it changes; see `rebuild()`.
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
        archiveURL?.lastPathComponent ?? L("Untitled Archive")
    }

    public var format: ArchiveFormat? {
        guard let archiveURL else { return FormatRegistry.format(forKey: "zip") }
        return FormatRegistry.format(for: archiveURL)
    }

    /// Whether entries can be added to or removed from the archive as it stands.
    /// Formats that can only be rebuilt, such as disk images, say no here but can
    /// still be written with Save As.
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
        CodePageMemory.remember(nil, for: archiveURL)
    }

    public var hasUnsavedChanges: Bool {
        !staged.isEmpty || !pendingDeletions.isEmpty
    }

    // MARK: - Loading

    /// Runs on the main actor so that the listing the window is reading is never
    /// replaced from another thread; the engine's own work still happens off it.
    @MainActor
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
    /// minus anything queued for deletion. Worked out once per change, since the
    /// window asks for it on every selection change and toolbar validation.
    public private(set) var visibleEntries: [ArchiveEntry] = []

    /// Brings everything derived from the archive's listing, the staged items and
    /// the pending deletions up to date.
    public func rebuild() {
        // The item staged last wins a path that several claim, which is also the
        // order in which they are written.
        var entries: [String: ArchiveEntry] = [:]
        var order: [String] = []
        var sources: [String: URL] = [:]
        for item in staged {
            for entry in item.entries {
                if entries.updateValue(entry, forKey: entry.path) == nil { order.append(entry.path) }
            }
            sources.merge(item.sources) { _, later in later }
        }
        stagedEntries = order.compactMap { entries[$0] }
        stagedSources = sources

        // Staged files win over the archive's, so replacing a file shows the new one.
        var seen = Set<String>()
        var merged: [ArchiveEntry] = []
        for entry in stagedEntries + listing.entries
        where !pendingDeletions.contains(entry.path) && seen.insert(entry.path).inserted {
            merged.append(entry)
        }
        visibleEntries = merged
        tree = EntryTree(entries: merged)
    }

    /// The on-disk file behind a staged entry, if this row has not been written yet.
    public func stagedSource(for path: String) -> URL? {
        stagedSources[ArchivePath.normalize(path)]
    }

    // MARK: - Editing

    /// A file or folder that has been walked, ready to be staged.
    public struct Scanned: Sendable {
        public let url: URL
        let entries: [ArchiveEntry]
        /// The file on disk behind each entry, in the same order.
        let sources: [URL]

        init(url: URL, entries: [ArchiveEntry], sources: [URL]? = nil) {
            self.url = url
            self.entries = entries
            let parent = url.deletingLastPathComponent()
            self.sources = sources ?? entries.map { parent.appendingPathComponent($0.path) }
        }
    }

    /// Walks files and folders to find what staging them would add. Touches nothing
    /// in the session, so it can run off the main thread: a folder of a hundred
    /// thousand files takes a while, and the window should not freeze for it.
    public static func scan(_ items: [URL]) -> [Scanned] {
        items.map { item in
            let standardized = item.standardizedFileURL
            let found = walk(item: standardized)
            return Scanned(url: standardized, entries: found.map(\.entry), sources: found.map(\.source))
        }
    }

    /// Stages files and folders to be written on the next save.
    /// - Parameter folder: where they go inside the archive, "" being its root.
    @discardableResult
    public func stage(items: [URL], into folder: String = "") -> [ArchiveEntry] {
        stage(scanned: Self.scan(items), into: folder)
    }

    @discardableResult
    public func stage(scanned: [Scanned], into folder: String = "") -> [ArchiveEntry] {
        let folder = ArchivePath.normalize(folder)
        var existing = Set(staged.map { StagedKey(url: $0.url, folder: $0.folder) })
        var arriving: [Staged] = []
        for item in scanned {
            // The same file can go into two folders; into the same one twice it cannot.
            guard existing.insert(StagedKey(url: item.url, folder: folder)).inserted else { continue }
            let entries = item.entries.map { $0.moved(into: folder) }
            arriving.append(Staged(
                url: item.url,
                folder: folder,
                entries: entries,
                sources: Dictionary(zip(entries.map(\.path), item.sources)) { _, later in later }))
        }
        guard !arriving.isEmpty else { return [] }

        // Something staged earlier at a path one of these now occupies has been
        // replaced, as it would be in the Finder. Left in, it would still be written,
        // and which of the two the archive ended up with would depend on the order
        // they happened to be saved in, not on what the list shows.
        //
        // Folders are the exception. Two of one name merge, so the earlier stays,
        // and only its files that the later one also has are replaced, which the
        // order of writing takes care of.
        let added = arriving.flatMap(\.entries)
        let claimed = Set(added.map(\.path))
        let claimedByFiles = Set(added.lazy.filter { !$0.isDirectory }.map(\.path))
        staged.removeAll { $0.isFolder ? claimedByFiles.contains($0.path) : claimed.contains($0.path) }
        // Two of the arrivals may claim one path as well; the later one stands.
        var taken = Set<String>()
        arriving = arriving.reversed().filter { taken.insert($0.path).inserted }.reversed()

        staged.append(contentsOf: arriving)
        pendingDeletions.subtract(claimed)
        rebuild()
        return added
    }

    private struct StagedKey: Hashable {
        let url: URL
        let folder: String
    }

    /// The folder a staged root is headed for, "" being the archive's root.
    public func stagedFolder(for root: URL) -> String {
        let standardized = root.standardizedFileURL
        return staged.first { $0.url == standardized }?.folder ?? ""
    }

    public func unstage(root: URL) {
        let standardized = root.standardizedFileURL
        unstage { $0.url == standardized }
        rebuild()
    }

    /// Takes staged items out, along with anything staged into a folder that one of
    /// them was going to make, and the deletions that had been made inside them.
    private func unstage(where matches: (Staged) -> Bool) {
        var removed = staged.filter(matches)
        guard !removed.isEmpty else { return }
        staged.removeAll(where: matches)

        // What was headed into a folder that is no longer coming has nowhere to go.
        var frontier = removed.map(\.path)
        while !frontier.isEmpty {
            let folders = Set(frontier)
            let orphans = staged.filter { item in
                folders.contains(item.folder) || Self.ancestors(of: item.folder).contains(where: folders.contains)
            }
            guard !orphans.isEmpty else { break }
            staged.removeAll { item in
                folders.contains(item.folder) || Self.ancestors(of: item.folder).contains(where: folders.contains)
            }
            removed.append(contentsOf: orphans)
            frontier = orphans.map(\.path)
        }

        // Deletions made inside them have nothing left to apply to. Ones that name an
        // entry of the archive itself still stand.
        guard !pendingDeletions.isEmpty else { return }
        let owned = Set(removed.flatMap { $0.entries.map(\.path) })
        guard !pendingDeletions.isDisjoint(with: owned) else { return }
        let stillThere = Set(listing.entries.map(\.path)).union(staged.flatMap { $0.entries.map(\.path) })
        pendingDeletions = pendingDeletions.filter { !owned.contains($0) || stillThere.contains($0) }
    }

    /// Removes items from what the next save will write. A folder takes everything
    /// in it along, including files staged into it from elsewhere.
    public func markForDeletion(_ paths: [String]) {
        let wanted = Set(paths.map(ArchivePath.normalize).filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return }
        func isWanted(_ path: String) -> Bool {
            wanted.contains(path) || Self.ancestors(of: path).contains(where: wanted.contains)
        }

        // Deleting something the user staged simply takes it out again, with
        // whatever was staged into it.
        unstage { isWanted($0.path) }

        // What is left at those paths, in the archive or inside a staged folder
        // that stays, is recorded item by item, so that a file staged into the same
        // place later is not caught by a deletion made before it arrived. One pass
        // over the entries, however many rows were selected.
        for entry in listing.entries where isWanted(entry.path) {
            pendingDeletions.insert(entry.path)
        }
        for item in staged {
            for entry in item.entries where isWanted(entry.path) {
                pendingDeletions.insert(entry.path)
            }
        }
        rebuild()
    }

    public func clearPendingChanges() {
        staged.removeAll()
        pendingDeletions.removeAll()
        rebuild()
    }

    // MARK: - Saving

    /// Writes the session to `destination`. When the destination is the currently open
    /// archive and the format allows it, pending changes are applied in place; otherwise
    /// a new archive is built from scratch.
    ///
    /// - Parameter rebuild: write the archive afresh even when the destination is the
    ///   open archive. Save As asks for this, because the options chosen there, a
    ///   password or a compression level, only take effect when everything is rewritten.
    @MainActor
    public func save(to destination: URL,
                     options: CompressionOptions,
                     rebuild: Bool = false,
                     cancellation: CancellationToken? = nil,
                     progress: ProgressHandler? = nil) async throws {
        defer {
            if let placeholders { try? FileManager.default.removeItem(at: placeholders) }
            placeholders = nil
        }
        let sameFile = destination.standardizedFileURL == archiveURL?.standardizedFileURL
        let format = FormatRegistry.format(for: destination)
        guard let format, format.canWrite else {
            throw ArchiveError.notWritable(destination.pathExtension.uppercased())
        }

        // A split archive has no file of the name that was asked for; it is opened
        // through its first volume.
        var written = destination
        var rewritten = false
        if sameFile, !rebuild, format.canEditInPlace, !listing.entries.isEmpty {
            try await saveInPlace(destination: destination, options: options,
                                  cancellation: cancellation, progress: progress)
        } else {
            written = try await saveByRebuilding(destination: destination, options: options,
                                                 cancellation: cancellation, progress: progress)
            // A rewritten archive is protected by whatever was chosen for it, which
            // is what reading it back from here on needs.
            password = options.password?.isEmpty == false ? options.password : nil
            rewritten = true
        }

        // Whatever the engine held for the previous file is stale now, whether we
        // wrote over it or wrote somewhere new.
        if let previous = archiveURL {
            EngineFactory.engine(for: previous).release(archive: previous)
        }
        archiveURL = written
        // Every name in an archive written afresh is in Unicode, whatever the old
        // ones had to be read as. One edited in place still holds the old names.
        if rewritten { encodingCodePage = nil } else { CodePageMemory.remember(encodingCodePage, for: written) }
        clearPendingChanges()
        try await load()
    }

    /// Applies the pending deletions and additions to the open archive.
    ///
    /// They are several rewrites, and the archive must not be left with some of them
    /// done and others not. So they are made to a copy, which takes the archive's
    /// place only when all of them have succeeded. On APFS the copy is a clone and
    /// costs nothing.
    @MainActor
    private func saveInPlace(destination: URL,
                             options: CompressionOptions,
                             cancellation: CancellationToken?,
                             progress: ProgressHandler?) async throws {
        let groups = try stagedGroups()
        let victims = listing.entries.filter { pendingDeletions.contains($0.path) }
        guard !victims.isEmpty || !groups.isEmpty else { return }

        // One rewrite is all or nothing by itself, and needs no copy.
        if (victims.isEmpty ? 0 : 1) + groups.count == 1 {
            let engine = EngineFactory.engine(for: destination)
            if let group = groups.first {
                try await CloudFile.materializeAll(stagedRoots, cancellation: cancellation, progress: progress)
                try await engine.add(items: group.items, to: destination, into: group.folder,
                                     options: options, cancellation: cancellation, progress: progress)
            } else {
                try await engine.delete(entries: victims, from: destination, password: password)
            }
            return
        }

        let fileManager = FileManager.default
        let building = try Self.buildFolder(for: destination)
        defer { try? fileManager.removeItem(at: building) }
        let working = building.appendingPathComponent(destination.lastPathComponent)
        try fileManager.copyItem(at: destination, to: working)
        let engine = EngineFactory.engine(for: working)
        // The copy is read with the encoding chosen for the original.
        CodePageMemory.remember(encodingCodePage, for: working)
        defer {
            CodePageMemory.remember(nil, for: working)
            engine.release(archive: working)
        }

        if !victims.isEmpty {
            try await engine.delete(entries: victims, from: working, password: password)
        }
        if !groups.isEmpty {
            try await CloudFile.materializeAll(stagedRoots, cancellation: cancellation, progress: progress)
            for group in groups {
                try await engine.add(items: group.items, to: working, into: group.folder,
                                     options: options, cancellation: cancellation, progress: progress)
            }
        }
        if cancellation?.isCancelled == true { throw ArchiveError.cancelled }
        _ = try fileManager.replaceItemAt(destination, withItemAt: working)
    }

    /// What to write for the staged items, as a list of additions, each of several
    /// items into one folder of the archive.
    ///
    /// A staged folder normally goes in whole. When something inside it was deleted
    /// before saving, it is taken apart instead, only as far down as the deletions
    /// reach: its remaining contents are added one by one into the folder it would
    /// have made.
    private func stagedGroups() throws -> [(folder: String, items: [URL])] {
        // Every addition rewrites the archive, so there should be few of them: one
        // for each folder that receives something. That is only right while no two
        // staged items hold the same path. When they do, the one staged later is the
        // one the list shows, so they are written in the order they were staged.
        let inOrder = stagedItemsOverlap
        var groups: [(folder: String, items: [URL])] = []
        var position: [String: Int] = [:]
        func emit(_ item: URL, into folder: String) {
            if inOrder {
                if groups.last?.folder == folder {
                    groups[groups.count - 1].items.append(item)
                } else {
                    groups.append((folder, [item]))
                }
            } else if let index = position[folder] {
                groups[index].items.append(item)
            } else {
                position[folder] = groups.count
                groups.append((folder, [item]))
            }
        }
        // Every folder that has a deletion somewhere beneath it, found once.
        let touched = Set(pendingDeletions.flatMap(Self.ancestors(of:)))

        for item in staged {
            guard PathSafety.itemExists(at: item.url) else {
                throw ArchiveError.ioFailure(L("%@ was not found.", item.url.path))
            }
            if touched.contains(item.path) {
                try takeApart(item.url, at: item.path, parent: item.folder, touched: touched, emit: emit)
            } else {
                emit(item.url, into: item.folder)
            }
        }
        // The archive's root first, since a new archive is begun with what goes there.
        return inOrder ? groups : groups.filter { $0.folder.isEmpty } + groups.filter { !$0.folder.isEmpty }
    }

    /// Whether two staged items both hold some path, other than as folders, which
    /// simply merge.
    private var stagedItemsOverlap: Bool {
        guard staged.count > 1 else { return false }
        var owners: [String: (item: Int, isFolder: Bool)] = [:]
        for (index, item) in staged.enumerated() {
            for entry in item.entries {
                if let other = owners[entry.path], other.item != index, !(other.isFolder && entry.isDirectory) {
                    return true
                }
                owners[entry.path] = (index, entry.isDirectory)
            }
        }
        return false
    }

    /// Emits what is left of the folder at `directory`, which has deletions inside it.
    private func takeApart(_ directory: URL, at path: String, parent: String, touched: Set<String>,
                           emit: (URL, String) -> Void) throws {
        // Gone since it was staged. Written as the empty folder it now looks like,
        // the save would succeed and the files would simply not be in the archive.
        guard PathSafety.itemExists(at: directory) else {
            throw ArchiveError.ioFailure(L("%@ was not found.", directory.path))
        }
        var emitted = false
        for child in Self.children(of: directory) {
            let childPath = ArchivePath.normalize(ArchivePath.join(path, child.lastPathComponent))
            if pendingDeletions.contains(childPath) { continue }
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isRealFolder = values?.isDirectory == true && values?.isSymbolicLink != true
            if isRealFolder, touched.contains(childPath) {
                try takeApart(child, at: childPath, parent: path, touched: touched, emit: emit)
            } else {
                emit(child, path)
            }
            emitted = true
        }
        // A folder emptied by deletions was not itself deleted, so it is still
        // written, as the empty folder the list shows.
        if !emitted {
            emit(try emptyFolder(named: directory.lastPathComponent), parent)
        }
    }

    /// Everything directly inside a folder, by name. Read with readdir, because
    /// FileManager's listings leave out files whose names start with "._", and
    /// whether those are stored is decided by the engine, from the user's setting.
    static func children(of directory: URL) -> [URL] {
        guard let handle = opendir(directory.path) else { return [] }
        defer { closedir(handle) }
        var names: [String] = []
        while let entry = readdir(handle) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names.sorted().map { directory.appendingPathComponent($0) }
    }

    /// Temporary empty folders standing in for staged folders whose contents were
    /// all deleted. Removed once the save is over.
    private var placeholders: URL?

    private func emptyFolder(named name: String) throws -> URL {
        let base = placeholders ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("justarc-empty-\(UUID().uuidString)")
        placeholders = base
        let folder = base.appendingPathComponent(UUID().uuidString).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// One addition to the archive being built.
    private struct Step {
        var folder: String
        var items: [URL]
        /// Contents of the archive that was open, which go across as they are: the
        /// setting that leaves Mac bookkeeping out is about what the user adds.
        var verbatim = false
    }

    /// Extracts the current archive to a scratch folder, applies the pending edits there,
    /// then compresses the result into the destination format. Returns the file to open
    /// afterwards, which for a split archive is its first volume.
    @MainActor
    private func saveByRebuilding(destination: URL,
                                  options: CompressionOptions,
                                  cancellation: CancellationToken?,
                                  progress: ProgressHandler?) async throws -> URL {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("justarc-save-\(UUID().uuidString)")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        var steps: [Step] = []

        if let archiveURL, !listing.entries.isEmpty {
            let sourceEngine = EngineFactory.engine(for: archiveURL)
            if let exact = sourceEngine as? VerbatimExtractor {
                let folders = try await exact.extractVerbatim(archive: archiveURL, excluding: pendingDeletions,
                                                              under: scratch, password: password,
                                                              cancellation: cancellation, progress: progress)
                for folder in folders {
                    let items = Self.children(of: folder)
                    if !items.isEmpty { steps.append(Step(folder: "", items: items, verbatim: true)) }
                }
            } else {
                // Files, and the folders that hold none: an empty folder is content too,
                // and would otherwise be lost on the way through.
                let files = listing.entries.filter { !pendingDeletions.contains($0.path) && !$0.isDirectory }
                let occupied = Set(files.flatMap { Self.ancestors(of: $0.path) })
                let emptyFolders = listing.entries.filter {
                    $0.isDirectory && !pendingDeletions.contains($0.path) && !occupied.contains($0.path)
                }
                let keep = files + emptyFolders
                if !keep.isEmpty {
                    let contents = scratch.appendingPathComponent("contents")
                    try fileManager.createDirectory(at: contents, withIntermediateDirectories: true)
                    // Better to say so than to write an archive with a file quietly missing.
                    try Self.refuseIfNamesWouldCollide(keep.map(\.path), in: contents)
                    try await sourceEngine.extract(archive: archiveURL, entries: keep, to: contents,
                                                   password: password, overwrite: .overwrite,
                                                   flattenPaths: false, cancellation: cancellation,
                                                   progress: progress)
                    // Asking for a folder brings everything in it, deleted items included.
                    for path in pendingDeletions {
                        if let removed = try? PathSafety.resolvedURL(for: path, in: contents) {
                            try? fileManager.removeItem(at: removed)
                        }
                    }
                    let items = Self.children(of: contents)
                    if !items.isEmpty { steps.append(Step(folder: "", items: items, verbatim: true)) }
                }
            }
        }

        // Staged files may come from a cloud folder and still be placeholders.
        try await CloudFile.materializeAll(stagedRoots, cancellation: cancellation, progress: progress)
        steps.append(contentsOf: try stagedGroups().map { Step(folder: $0.folder, items: $0.items) })
        guard !steps.isEmpty else {
            throw ArchiveError.ioFailure(L("There is nothing to save. Add files to the archive first."))
        }

        // The new archive is built under its real name in a folder of its own, on the
        // destination's volume: the name is what a disk image is titled after and
        // what split volumes are numbered from, and the volume is what lets the
        // finished file take the old one's place in a single step.
        let building = try Self.buildFolder(for: destination)
        defer { try? fileManager.removeItem(at: building) }
        let temporaryArchive = building.appendingPathComponent(destination.lastPathComponent)
        let destinationEngine = EngineFactory.engine(for: destination)
        let kind = FormatRegistry.format(for: destination)?.engine
        let splitting = options.volumeSize?.isEmpty == false

        // Some archives can only be written in one go. A disk image is built from a
        // folder and cannot be added to afterwards; RAR writes its volumes as it
        // compresses and cannot cut up an archive it has finished. For those,
        // everything is laid out on disk first, shaped like the archive, with the
        // same rule as the list: what was added later replaces what it lands on.
        if steps.count > 1, kind == .diskImage || (kind == .externalRAR && splitting) {
            guard steps.filter(\.verbatim).count <= 1 else {
                throw ArchiveError.ioFailure(
                    L("The archive holds names that differ only in capitalisation, which a folder on this Mac cannot. It cannot be saved in this format."))
            }
            let layout = scratch.appendingPathComponent("layout-\(UUID().uuidString)")
            steps = [Step(folder: "", items: try Self.layOut(steps, in: layout))]
        }

        // Volumes are cut once the archive is complete, so everything is added first.
        for (index, step) in steps.enumerated() {
            var settings = options
            settings.volumeSize = steps.count == 1 ? options.volumeSize : nil
            if step.verbatim { settings.excludeMacMetadata = false }
            if index == 0, step.folder.isEmpty {
                try await destinationEngine.create(archive: temporaryArchive, items: step.items, options: settings,
                                                   cancellation: cancellation, progress: progress)
            } else {
                try await destinationEngine.add(items: step.items, to: temporaryArchive, into: step.folder,
                                                options: settings, cancellation: cancellation, progress: progress)
            }
        }
        if steps.count > 1, let size = options.volumeSize, !size.isEmpty {
            try Self.splitInPlace(temporaryArchive, volumeSize: size)
        }

        return try Self.place(builtIn: building, named: destination.lastPathComponent, at: destination)
    }

    /// Every folder path above `path`: "a/b/c.txt" gives ["a/b", "a"].
    private static func ancestors(of path: String) -> [String] {
        var result: [String] = []
        var current = Substring(path)
        while let slash = current.lastIndex(of: "/") {
            current = current[..<slash]
            result.append(String(current))
        }
        return result
    }

    /// Throws when two of `paths` are the same name to a volume that ignores case or
    /// composes accents, and `folder` is on such a volume.
    private static func refuseIfNamesWouldCollide(_ paths: [String], in folder: URL) throws {
        let sensitive = (try? folder.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames) ?? false
        guard !sensitive else { return }
        var seen: [String: String] = [:]
        for path in paths {
            let folded = path.precomposedStringWithCanonicalMapping.lowercased()
            if let other = seen[folded], other != path {
                throw ArchiveError.ioFailure(
                    L("“%@” and “%@” differ only in capitalisation. This Mac's disk cannot hold both, so the archive cannot be rewritten here without losing one. Its contents can still be changed in place.",
                      other, path))
            }
            seen[folded] = path
        }
    }

    private static func buildFolder(for destination: URL) throws -> URL {
        let fileManager = FileManager.default
        if let folder = try? fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                             appropriateFor: destination.deletingLastPathComponent(),
                                             create: true) {
            return folder
        }
        let folder = fileManager.temporaryDirectory.appendingPathComponent("justarc-build-\(UUID().uuidString)")
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func splitInPlace(_ archive: URL, volumeSize: String) throws {
        guard let bytes = try SevenZipEngine.volumeBytes(volumeSize) else { return }
        let whole = archive.deletingLastPathComponent().appendingPathComponent("justarc-whole")
        try FileManager.default.moveItem(at: archive, to: whole)
        defer { try? FileManager.default.removeItem(at: whole) }
        try SevenZipEngine.split(whole, into: archive, volumeBytes: bytes)
    }

    /// Moves what was built into the destination's folder and returns the file to
    /// open. An engine asked to split writes volumes instead of the one file:
    /// "name.7z.001" and so on from 7-Zip, "name.part1.rar" from RAR.
    private static func place(builtIn building: URL, named name: String, at destination: URL) throws -> URL {
        let fileManager = FileManager.default
        let built = building.appendingPathComponent(name)
        if fileManager.fileExists(atPath: built.path) {
            if PathSafety.itemExists(at: destination) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: built)
            } else {
                try fileManager.moveItem(at: built, to: destination)
            }
            return destination
        }

        let volumes = try fileManager.contentsOfDirectory(at: building, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != "justarc-whole" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard let first = volumes.first else {
            throw ArchiveError.ioFailure(L("%@ was not written.", name))
        }
        let folder = destination.deletingLastPathComponent()
        for volume in volumes {
            let target = folder.appendingPathComponent(volume.lastPathComponent)
            if PathSafety.itemExists(at: target) {
                _ = try fileManager.replaceItemAt(target, withItemAt: volume)
            } else {
                try fileManager.moveItem(at: volume, to: target)
            }
        }

        // Volumes left from an earlier, larger save of this name would be read as
        // part of the new set. Only the ones that directly continue its numbering
        // are taken to be that: "name.7z.004" after a set of three, never a file
        // that merely has a number for an extension.
        var number = volumes.count + 1
        while let stale = volumeName(number, like: volumes.map(\.lastPathComponent), of: name) {
            let url = folder.appendingPathComponent(stale)
            guard PathSafety.itemExists(at: url) else { break }
            try? fileManager.trashItem(at: url, resultingItemURL: nil)
            if PathSafety.itemExists(at: url) { break }
            number += 1
        }
        return folder.appendingPathComponent(first.lastPathComponent)
    }

    /// Whether `candidate` is named like one volume of the archive called `name`.
    static func isVolume(_ candidate: String, of name: String) -> Bool {
        if candidate.hasPrefix(name + ".") {
            let suffix = candidate.dropFirst(name.count + 1)
            if !suffix.isEmpty, suffix.allSatisfy(\.isNumber) { return true }
        }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, candidate.hasPrefix(stem + ".part"), candidate.hasSuffix("." + ext) else { return false }
        let middle = candidate.dropFirst(stem.count + 5).dropLast(ext.count + 1)
        return !middle.isEmpty && middle.allSatisfy(\.isNumber)
    }

    /// The name volume `number` of this set would have, going by how the volumes
    /// just written are named.
    static func volumeName(_ number: Int, like written: [String], of name: String) -> String? {
        guard let sample = written.first else { return nil }
        if sample == name + ".001" { return name + String(format: ".%03d", number) }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        if sample.hasPrefix(stem + ".part"), sample.hasSuffix("." + ext) {
            // RAR pads the number to the width the whole set needs.
            let digits = sample.dropFirst(stem.count + 5).dropLast(ext.count + 1)
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
            let padded = String(repeating: "0", count: max(digits.count - String(number).count, 0)) + String(number)
            return "\(stem).part\(padded).\(ext)"
        }
        return nil
    }

    /// Copies everything into one folder tree shaped like the archive, and returns
    /// what is at its top. On APFS the copies are clones and take no space. A folder
    /// merges into a folder of the same name; anything else replaces what it lands on.
    private static func layOut(_ steps: [Step], in layout: URL) throws -> [URL] {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: layout, withIntermediateDirectories: true)
        for step in steps {
            let folder = step.folder.isEmpty ? layout : try PathSafety.resolvedURL(for: step.folder, in: layout)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            for item in step.items {
                try mergeCopy(item, to: folder.appendingPathComponent(item.lastPathComponent))
            }
        }
        return children(of: layout)
    }

    static func mergeCopy(_ source: URL, to target: URL) throws {
        let fileManager = FileManager.default
        func isRealFolder(_ url: URL) -> Bool {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }
        guard PathSafety.itemExists(at: target) else {
            try fileManager.copyItem(at: source, to: target)
            return
        }
        if isRealFolder(source), isRealFolder(target) {
            for child in children(of: source) {
                try mergeCopy(child, to: target.appendingPathComponent(child.lastPathComponent))
            }
        } else {
            try fileManager.removeItem(at: target)
            try fileManager.copyItem(at: source, to: target)
        }
    }

    // MARK: - Staging helpers

    /// Produces archive entries for a file or folder, each with the file on disk
    /// behind it. Paths are relative to the item's parent, so a dropped folder keeps
    /// its own name at the archive root.
    static func walk(item: URL) -> [(entry: ArchiveEntry, source: URL)] {
        let fm = FileManager.default
        // Not followed: a link to a folder is stored as a link, so it is listed as one.
        guard let attributes = try? fm.attributesOfItem(atPath: item.path) else { return [] }
        let base = item.lastPathComponent
        let modified = attributes[.modificationDate] as? Date

        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            return [(ArchiveEntry(path: base, isDirectory: false, size: size,
                                  packedSize: 0, modified: modified), item)]
        }

        var results = [(entry: ArchiveEntry(path: base, isDirectory: true, modified: modified), source: item)]
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
            results.append((ArchiveEntry(path: ArchivePath.join(base, relative),
                                         isDirectory: isDir,
                                         size: UInt64(values?.fileSize ?? 0),
                                         packedSize: 0,
                                         modified: values?.contentModificationDate),
                            item.appendingPathComponent(relative)))
        }
        return results
    }

    static func enumerate(item: URL) -> [ArchiveEntry] {
        walk(item: item).map(\.entry)
    }
}
