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
    /// The folder inside the archive each staged root goes into. Roots headed for
    /// the archive's own root are not listed.
    private var stagedFolders: [URL: String] = [:]
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

    private func computeVisibleEntries() -> [ArchiveEntry] {
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
        visibleEntries = computeVisibleEntries()
        tree = EntryTree(entries: visibleEntries)
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
    }

    /// Walks files and folders to find what staging them would add. Touches nothing
    /// in the session, so it can run off the main thread: a folder of a hundred
    /// thousand files takes a while, and the window should not freeze for it.
    public static func scan(_ items: [URL]) -> [Scanned] {
        items.map { item in
            let standardized = item.standardizedFileURL
            return Scanned(url: standardized, entries: enumerate(item: standardized))
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
        var added: [ArchiveEntry] = []
        for item in scanned {
            let standardized = item.url
            guard !stagedRoots.contains(standardized) else { continue }
            stagedRoots.append(standardized)
            if !folder.isEmpty { stagedFolders[standardized] = folder }
            let produced = item.entries.map { $0.moved(into: folder) }
            let replaced = Set(produced.map(\.path))
            stagedEntries.removeAll { replaced.contains($0.path) }
            stagedEntries.append(contentsOf: produced)
            pendingDeletions.subtract(replaced)
            for (path, url) in Self.sourceMap(for: standardized, entries: item.entries) {
                stagedSources[ArchivePath.join(folder, path)] = url
            }
            added.append(contentsOf: produced)
        }
        rebuild()
        return added
    }

    /// The folder a staged root is headed for, "" being the archive's root.
    public func stagedFolder(for root: URL) -> String {
        stagedFolders[root.standardizedFileURL] ?? ""
    }

    public func unstage(root: URL) {
        let standardized = root.standardizedFileURL
        guard stagedRoots.contains(standardized) else { return }
        let folder = stagedFolder(for: standardized)
        let archivePath = ArchivePath.join(folder, standardized.lastPathComponent)

        stagedRoots.removeAll { $0 == standardized }
        stagedFolders[standardized] = nil
        let owned = Set(Self.sourceMap(for: standardized).keys.map { ArchivePath.join(folder, $0) })
        stagedEntries.removeAll { owned.contains($0.path) }
        for path in owned { stagedSources.removeValue(forKey: path) }
        // Deletions made inside it have nothing left to apply to. Ones that name an
        // entry of the archive itself still stand.
        let inArchive = Set(listing.entries.map(\.path))
        pendingDeletions = pendingDeletions.filter { !owned.contains($0) || inArchive.contains($0) }

        // Anything staged into this folder has lost the place it was going to.
        for (other, destination) in stagedFolders
        where destination == archivePath || destination.hasPrefix(archivePath + "/") {
            unstage(root: other)
        }
        rebuild()
    }

    /// Removes items from what the next save will write. A folder takes everything
    /// in it along, including files staged into it from elsewhere.
    public func markForDeletion(_ paths: [String]) {
        for path in paths {
            let normalized = ArchivePath.normalize(path)
            guard !normalized.isEmpty else { continue }

            // Deleting something the user staged whole simply takes it out again.
            if let source = stagedSources[normalized], stagedRoots.contains(source),
               archivePath(ofStagedRoot: source) == normalized {
                unstage(root: source)
                continue
            }

            // Anything else is recorded item by item, so that a file staged into the
            // same place later is not caught by a deletion made before it arrived.
            let prefix = normalized + "/"
            pendingDeletions.insert(normalized)
            for entry in listing.entries + stagedEntries where entry.path.hasPrefix(prefix) {
                pendingDeletions.insert(entry.path)
            }
            for (root, folder) in stagedFolders where folder == normalized || folder.hasPrefix(prefix) {
                unstage(root: root)
            }
        }
        rebuild()
    }

    private func archivePath(ofStagedRoot root: URL) -> String {
        ArchivePath.join(stagedFolder(for: root), root.lastPathComponent)
    }

    public func clearPendingChanges() {
        stagedRoots.removeAll()
        stagedFolders.removeAll()
        stagedEntries.removeAll()
        stagedSources.removeAll()
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
        if sameFile, !rebuild, format.canEditInPlace, !listing.entries.isEmpty {
            try await saveInPlace(destination: destination, options: options,
                                  cancellation: cancellation, progress: progress)
        } else {
            written = try await saveByRebuilding(destination: destination, options: options,
                                                 cancellation: cancellation, progress: progress)
            // A rewritten archive is protected by whatever was chosen for it, which
            // is what reading it back from here on needs.
            password = options.password?.isEmpty == false ? options.password : nil
        }

        // Whatever the engine held for the previous file is stale now, whether we
        // wrote over it or wrote somewhere new.
        if let previous = archiveURL {
            EngineFactory.engine(for: previous).release(archive: previous)
        }
        archiveURL = written
        clearPendingChanges()
        try await load()
    }

    @MainActor
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
            for group in try stagedGroups() {
                try await engine.add(items: group.items, to: destination, into: group.folder,
                                     options: options, cancellation: cancellation, progress: progress)
            }
        }
    }

    /// What to write for the staged items, gathered by the folder each goes into, the
    /// archive's root first.
    ///
    /// A staged folder normally goes in whole. When something inside it was deleted
    /// before saving, it is taken apart instead, only as far down as the deletions
    /// reach: its remaining contents are added one by one into the folder it would
    /// have made.
    private func stagedGroups() throws -> [(folder: String, items: [URL])] {
        var order: [String] = []
        var groups: [String: [URL]] = [:]
        func emit(_ item: URL, into folder: String) {
            if groups[folder] == nil { order.append(folder) }
            groups[folder, default: []].append(item)
        }

        for root in stagedRoots {
            let folder = stagedFolder(for: root)
            let path = ArchivePath.join(folder, root.lastPathComponent)
            if hasDeletions(under: path) {
                try takeApart(root, at: path, parent: folder, emit: emit)
            } else {
                emit(root, into: folder)
            }
        }
        return order.sorted { $0.isEmpty && !$1.isEmpty }.map { ($0, groups[$0] ?? []) }
    }

    private func hasDeletions(under path: String) -> Bool {
        let prefix = path + "/"
        return pendingDeletions.contains { $0.hasPrefix(prefix) }
    }

    /// Emits what is left of the folder at `directory`, which has deletions inside it.
    private func takeApart(_ directory: URL, at path: String, parent: String,
                           emit: (URL, String) -> Void) throws {
        var emitted = false
        for child in Self.children(of: directory) {
            let childPath = ArchivePath.join(path, child.lastPathComponent)
            if pendingDeletions.contains(childPath) { continue }
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isRealFolder = values?.isDirectory == true && values?.isSymbolicLink != true
            if isRealFolder, hasDeletions(under: childPath) {
                try takeApart(child, at: childPath, parent: path, emit: emit)
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
    private static func children(of directory: URL) -> [URL] {
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

        var roots: [URL] = []

        if let archiveURL, !listing.entries.isEmpty {
            // Files, and the folders that hold none: an empty folder is content too,
            // and would otherwise be lost on the way through.
            let files = listing.entries.filter { !pendingDeletions.contains($0.path) && !$0.isDirectory }
            let occupied = Set(files.flatMap { Self.ancestors(of: $0.path) })
            let emptyFolders = listing.entries.filter {
                $0.isDirectory && !pendingDeletions.contains($0.path) && !occupied.contains($0.path)
            }
            let keep = files + emptyFolders
            if !keep.isEmpty {
                let sourceEngine = EngineFactory.engine(for: archiveURL)
                try await sourceEngine.extract(archive: archiveURL, entries: keep, to: scratch,
                                               password: password, overwrite: .overwrite,
                                               flattenPaths: false, cancellation: cancellation,
                                               progress: progress)
                // Asking for a folder brings everything in it, deleted items included.
                for path in pendingDeletions {
                    if let removed = try? PathSafety.resolvedURL(for: path, in: scratch) {
                        try? fileManager.removeItem(at: removed)
                    }
                }
                roots.append(contentsOf: try fileManager.contentsOfDirectory(
                    at: scratch, includingPropertiesForKeys: nil))
            }
        }

        // Staged files may come from a cloud folder and still be placeholders.
        try await CloudFile.materializeAll(stagedRoots, cancellation: cancellation, progress: progress)
        let groups = try stagedGroups()
        roots.append(contentsOf: groups.first { $0.folder.isEmpty }?.items ?? [])
        var nested = groups.filter { !$0.folder.isEmpty }
        guard !roots.isEmpty || !nested.isEmpty else {
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

        // A disk image is built in one go from a folder and cannot be added to
        // afterwards, so what goes into subfolders is laid out on disk first.
        if !nested.isEmpty, FormatRegistry.format(for: destination)?.engine == .diskImage {
            roots = try Self.layOut(roots: roots, nested: nested,
                                    in: scratch.appendingPathComponent("layout-\(UUID().uuidString)"))
            nested = []
        }

        // Volumes are cut once the archive is complete, so everything is added first.
        var whole = options
        whole.volumeSize = nested.isEmpty ? options.volumeSize : nil
        if !roots.isEmpty {
            try await destinationEngine.create(archive: temporaryArchive, items: roots, options: whole,
                                               cancellation: cancellation, progress: progress)
        }
        for (index, group) in nested.enumerated() {
            var step = options
            step.volumeSize = nil
            try await destinationEngine.add(items: group.items, to: temporaryArchive, into: group.folder,
                                            options: step, cancellation: cancellation, progress: progress)
            if index == nested.count - 1, let size = options.volumeSize, !size.isEmpty {
                try Self.splitInPlace(temporaryArchive, volumeSize: size)
            }
        }

        return try Self.place(builtIn: building, named: destination.lastPathComponent, at: destination)
    }

    /// Every folder path above `path`: "a/b/c.txt" gives ["a", "a/b"].
    private static func ancestors(of path: String) -> [String] {
        var result: [String] = []
        var current = Substring(path)
        while let slash = current.lastIndex(of: "/") {
            current = current[..<slash]
            result.append(String(current))
        }
        return result
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

        // Volumes from an earlier save of this name would be read as part of the
        // new set if it has fewer of them.
        let produced = Set(volumes.map(\.lastPathComponent))
        for existing in (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where isVolume(existing.lastPathComponent, of: name) && !produced.contains(existing.lastPathComponent) {
            try? fileManager.removeItem(at: existing)
        }
        for volume in volumes {
            let target = folder.appendingPathComponent(volume.lastPathComponent)
            if PathSafety.itemExists(at: target) {
                _ = try fileManager.replaceItemAt(target, withItemAt: volume)
            } else {
                try fileManager.moveItem(at: volume, to: target)
            }
        }
        return folder.appendingPathComponent(first.lastPathComponent)
    }

    /// True for "name.7z.001"-style and "name.part1.rar"-style volumes of `name`.
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

    /// Copies everything into one folder tree shaped like the archive, and returns
    /// what is at its top. On APFS the copies are clones and take no space.
    private static func layOut(roots: [URL], nested: [(folder: String, items: [URL])],
                               in layout: URL) throws -> [URL] {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: layout, withIntermediateDirectories: true)
        for root in roots {
            try fileManager.copyItem(at: root, to: layout.appendingPathComponent(root.lastPathComponent))
        }
        for group in nested {
            let folder = try PathSafety.resolvedURL(for: group.folder, in: layout)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            for item in group.items {
                let target = folder.appendingPathComponent(item.lastPathComponent)
                if PathSafety.itemExists(at: target) { try fileManager.removeItem(at: target) }
                try fileManager.copyItem(at: item, to: target)
            }
        }
        return try fileManager.contentsOfDirectory(at: layout, includingPropertiesForKeys: nil)
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

    static func sourceMap(for item: URL, entries: [ArchiveEntry]? = nil) -> [String: URL] {
        var map: [String: URL] = [:]
        let base = item.lastPathComponent
        map[base] = item
        for entry in entries ?? enumerate(item: item) where entry.path != base {
            let relative = String(entry.path.dropFirst(base.count + 1))
            map[entry.path] = item.appendingPathComponent(relative)
        }
        return map
    }
}
