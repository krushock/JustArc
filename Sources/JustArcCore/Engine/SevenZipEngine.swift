import Foundation

/// Reads and writes archives through 7-Zip's format library, loaded into the process.
/// Nothing runs as a subprocess, so passwords never appear in a command line.
///
/// A compressed stream wrapping a tar (`.tar.gz`, `.tar.xz`, …) is unwrapped into a
/// temporary tar once and read from there; see `NestedTarCache`.
public struct SevenZipEngine: ArchiveEngine, VerbatimExtractor {
    public init() {}

    // MARK: - Listing

    public func list(archive: URL, password: String?, encodingCodePage: Int? = nil) async throws -> ArchiveListing {
        // No encoding given means whichever was last chosen for this archive, not
        // "forget the choice": Quick Extract and the Finder's services list archives
        // too, and must not change how a window that is open on one reads its names.
        if let encodingCodePage { CodePageMemory.remember(encodingCodePage, for: archive) }
        let codePage = encodingCodePage ?? CodePageMemory.codePage(for: archive)
        return try await Self.blocking {
            let readable = try Readable.open(archive, password: password, codePage: codePage,
                                             unwrapProgress: .silent)
            var info = readable.bridge.info
            if let outer = readable.outer {
                info.formatName = "\(outer.info.formatName) / \(info.formatName)"
                info.physicalSize = outer.info.physicalSize
            }
            // macOS's own bookkeeping is left out; see `MacMetadata`.
            // An entry named "." or "./", which tar writes for the folder it was run
            // in, normalises to no name at all and stands for nothing extractable.
            // Nor is a path nested deeper than any path on this system can be.
            let all = readable.bridge.entries()
            let entries = all.filter {
                !$0.path.isEmpty && !MacMetadata.isMetadata(path: $0.path) && !ArchivePath.isTooDeep($0.path)
            }
            let tooDeep = all.lazy.filter { ArchivePath.isTooDeep($0.path) }.count
            if tooDeep > 0 {
                Diagnostics.log("\(archive.lastPathComponent): \(tooDeep) item(s) nested more than \(ArchivePath.maximumDepth) folders deep are not listed")
            }
            return ArchiveListing(info: info, entries: entries)
        }
    }

    // MARK: - Extraction

    public func extract(archive: URL,
                        entries: [ArchiveEntry]?,
                        to destination: URL,
                        password: String?,
                        overwrite: OverwriteMode = .renameNew,
                        flattenPaths: Bool = false,
                        cancellation: CancellationToken? = nil,
                        progress: ProgressHandler? = nil) async throws {
        try await extract(archive: archive, entries: entries, to: destination, password: password,
                          overwrite: overwrite, flattenPaths: flattenPaths, keepLinksAsStored: false,
                          cancellation: cancellation, progress: progress)
    }

    func extractVerbatim(archive: URL, excluding: Set<String>, under scratch: URL,
                         password: String?, cancellation: CancellationToken?,
                         progress: ProgressHandler?) async throws -> [URL] {
        let codePage = CodePageMemory.codePage(for: archive)
        let caseSensitive = (try? scratch.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames) ?? false

        return try await Self.blocking {
            let whole = BridgeProgress(handler: progress, cancellation: cancellation)
            let readable = try Readable.open(archive, password: password, codePage: codePage,
                                             unwrapProgress: whole.slice(offset: 0, span: 0.5))
            let kept = readable.bridge.indices().filter { !Self.isExcluded($0.path, by: excluding) }
            if let unsafe = kept.first(where: { !$0.path.isEmpty && !PathSafety.isSafe(entryPath: $0.path) }) {
                throw ArchiveError.unsafeEntry(unsafe.path)
            }
            let layers = try Self.layers(of: kept, caseSensitive: caseSensitive)
            let rest = readable.didUnwrap ? whole.slice(offset: 0.5, span: 0.5) : whole

            var folders: [URL] = []
            for (number, layer) in layers.enumerated() where !layer.isEmpty {
                let folder = scratch.appendingPathComponent("contents-\(number)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try readable.bridge.extract(indices: layer, destination: folder, password: password,
                                            overwrite: .overwrite, flatten: false, testOnly: false,
                                            keepLinksAsStored: true,
                                            progress: layers.count == 1 ? rest : whole.slice(offset: 0, span: 0))
                folders.append(folder)
            }
            return folders
        }
    }

    /// Whether an item is one of `excluded`, inside one of them, or the Mac
    /// bookkeeping that describes one.
    static func isExcluded(_ path: String, by excluded: Set<String>) -> Bool {
        guard !excluded.isEmpty else { return false }
        func isCovered(_ path: String) -> Bool {
            if excluded.contains(path) { return true }
            var parent = Substring(path)
            while let slash = parent.lastIndex(of: "/") {
                parent = parent[..<slash]
                if excluded.contains(String(parent)) { return true }
            }
            return false
        }
        if isCovered(path) { return true }
        guard MacMetadata.isMetadata(path: path), let described = MacMetadata.itemDescribed(by: path) else {
            return false
        }
        return isCovered(described)
    }

    /// Sorts items into groups that a disk can hold: within one, no two names, of
    /// files or of the folders above them, differ only in capitalisation or in how
    /// an accent is composed.
    static func layers(of items: [(index: UInt32, path: String)], caseSensitive: Bool) throws -> [[UInt32]] {
        guard !caseSensitive else { return [items.map(\.index)] }
        var layers: [[UInt32]] = [[]]
        var spellings: [[String: String]] = [[:]]
        for item in items {
            // Every folder on the way down, and the item itself.
            var prefixes: [(folded: String, exact: String)] = []
            var end = item.path.startIndex
            while end < item.path.endIndex {
                end = item.path[end...].dropFirst().firstIndex(of: "/") ?? item.path.endIndex
                let exact = String(item.path[..<end])
                prefixes.append((exact.precomposedStringWithCanonicalMapping.lowercased(), exact))
            }
            var home = layers.indices.first { layer in
                prefixes.allSatisfy { (spellings[layer][$0.folded] ?? $0.exact) == $0.exact }
            }
            if home == nil {
                guard layers.count < 32 else {
                    throw ArchiveError.ioFailure(
                        L("“%@” differs from too many other names only in capitalisation for the archive to be rewritten on this Mac's disk.", item.path))
                }
                layers.append([])
                spellings.append([:])
                home = layers.count - 1
            }
            guard let home else { continue }
            layers[home].append(item.index)
            for prefix in prefixes { spellings[home][prefix.folded] = prefix.exact }
        }
        return layers
    }

    private func extract(archive: URL,
                         entries: [ArchiveEntry]?,
                         to destination: URL,
                         password: String?,
                         overwrite: OverwriteMode,
                         flattenPaths: Bool,
                         keepLinksAsStored: Bool,
                         cancellation: CancellationToken?,
                         progress: ProgressHandler?) async throws {
        if let entries, let unsafePath = PathSafety.firstUnsafePath(in: entries) {
            throw ArchiveError.unsafeEntry(unsafePath)
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let codePage = CodePageMemory.codePage(for: archive)

        try await Self.blocking {
            let whole = BridgeProgress(handler: progress, cancellation: cancellation)
            let readable = try Readable.open(archive, password: password, codePage: codePage,
                                             unwrapProgress: whole.slice(offset: 0, span: 0.5))
            let indices = entries.map { Self.indices(of: $0, in: readable.bridge) }
                ?? Self.indicesWithoutMacMetadata(in: readable.bridge)
            if let indices, indices.isEmpty { return }

            let summary = try readable.bridge.extract(
                indices: indices,
                destination: destination,
                password: password,
                overwrite: overwrite,
                flatten: flattenPaths,
                testOnly: false,
                keepLinksAsStored: keepLinksAsStored,
                progress: readable.didUnwrap ? whole.slice(offset: 0.5, span: 0.5) : whole)
            if summary.linksRefused > 0 {
                Diagnostics.log("Skipped \(summary.linksRefused) link(s) pointing outside \(destination.path)")
            }
        }
        // A cancel that arrives after the last file is written is too late to be one:
        // the bridge reports a real cancel itself, having undone what it had extracted.
        progress?(ArchiveProgress(fraction: 1, currentFile: nil))
    }

    // MARK: - Testing

    public func test(archive: URL,
                     password: String?,
                     cancellation: CancellationToken? = nil,
                     progress: ProgressHandler? = nil) async throws -> String {
        let summary = try await Self.blocking {
            let whole = BridgeProgress(handler: progress, cancellation: cancellation)
            let readable = try Readable.open(archive, password: password, codePage: nil,
                                             unwrapProgress: whole.slice(offset: 0, span: 0.5))
            let result = try readable.bridge.extract(
                indices: nil, destination: nil, password: password, overwrite: .overwrite,
                flatten: false, testOnly: true,
                progress: readable.didUnwrap ? whole.slice(offset: 0.5, span: 0.5) : whole)
            return (files: Int(result.filesProcessed), bytes: result.bytesProcessed)
        }
        if cancellation?.isCancelled == true { throw ArchiveError.cancelled }
        progress?(ArchiveProgress(fraction: 1, currentFile: nil))
        let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: summary.bytes), countStyle: .file)
        return [L("Everything is Ok"), L("Files: %d", summary.files), L("Size: %@", size)]
            .joined(separator: "\n")
    }

    // MARK: - Creating

    public func create(archive: URL,
                       items: [URL],
                       options: CompressionOptions,
                       cancellation: CancellationToken? = nil,
                       progress: ProgressHandler? = nil) async throws {
        try await create(archive: archive, items: items, folder: "", options: options,
                         cancellation: cancellation, progress: progress)
    }

    private func create(archive: URL,
                        items: [URL],
                        folder: String,
                        options: CompressionOptions,
                        cancellation: CancellationToken?,
                        progress: ProgressHandler?) async throws {
        guard let format = options.format, format.canWrite else {
            throw ArchiveError.notWritable(options.formatKey)
        }
        let recipe = try WriteRecipe(formatKey: format.key, displayName: format.displayName)
        let volumeBytes = try options.volumeSize.flatMap(Self.volumeBytes)

        try await Self.blocking {
            let whole = BridgeProgress(handler: progress, cancellation: cancellation)
            let added = try Self.collect(items, into: folder, excludeMacMetadata: options.excludeMacMetadata)
            let scratch = try Scratch(beside: archive)
            defer { scratch.remove() }

            let output = scratch.file("justarc-output")
            if let compressor = recipe.compressor {
                if recipe.container == nil {
                    // A bare compressor holds exactly one file.
                    guard added.count == 1, let only = added.first,
                          !only.diskURL.hasDirectoryPath, !Self.isDirectory(only.diskURL) else {
                        throw ArchiveError.ioFailure(
                            L("%@ holds a single file. Choose one file, or save as TAR + %@ instead.",
                              format.displayName, format.displayName))
                    }
                    try BridgeArchive.create(added: added, to: output,
                                             settings: recipe.settings(options, formatName: compressor),
                                             progress: whole)
                } else {
                    // tar first, then compress the tar.
                    let tar = try scratch.file(Self.innerTarName(for: archive), inSubfolder: "tar")
                    try BridgeArchive.create(added: added, to: tar,
                                             settings: recipe.settings(options, formatName: "tar"),
                                             progress: whole.slice(offset: 0, span: 0.5))
                    try BridgeArchive.create(added: [.init(archivePath: tar.lastPathComponent, diskURL: tar)],
                                             to: output,
                                             settings: recipe.settings(options, formatName: compressor),
                                             progress: whole.slice(offset: 0.5, span: 0.5))
                }
            } else {
                try BridgeArchive.create(added: added, to: output,
                                         settings: recipe.settings(options, formatName: recipe.container!),
                                         progress: whole)
            }

            if let volumeBytes {
                try Self.split(output, into: archive, volumeBytes: volumeBytes)
            } else {
                try Self.place(output, at: archive)
            }
        }
        NestedTarCache.shared.forget(archive)
        progress?(ArchiveProgress(fraction: 1, currentFile: nil))
    }

    // MARK: - Editing

    /// Adds files to an archive, replacing items with the same paths. Creates the
    /// archive when it does not exist yet.
    public func add(items: [URL],
                    to archive: URL,
                    into folder: String,
                    options: CompressionOptions,
                    cancellation: CancellationToken? = nil,
                    progress: ProgressHandler? = nil) async throws {
        guard !items.isEmpty else { return }
        let folder = ArchivePath.normalize(folder)
        guard folder.isEmpty || PathSafety.isSafe(entryPath: folder) else {
            throw ArchiveError.unsafeEntry(folder)
        }
        guard PathSafety.itemExists(at: archive) else {
            try await create(archive: archive, items: items, folder: folder, options: options,
                             cancellation: cancellation, progress: progress)
            return
        }
        try await rewrite(archive, password: options.password, options: options,
                          cancellation: cancellation, progress: progress) { bridge in
            let added = try Self.collect(items, into: folder, excludeMacMetadata: options.excludeMacMetadata)
            let existing = bridge.indices()
            if !folder.isEmpty,
               let blocker = existing.first(where: { $0.path == folder }),
               bridge.item(blocker.index)?.isDirectory == false {
                throw ArchiveError.ioFailure(L("%@ is a file in this archive, not a folder.", folder))
            }
            // What is added replaces what has the same path, and a file replaces a
            // whole folder of that name, so no path ends up in the archive twice.
            let replaced = Set(added.map(\.archivePath))
            let replacedByFiles = Set(added.lazy.filter { !Self.isDirectory($0.diskURL) }.map(\.archivePath))
            // Looked up by walking each existing path upwards, not by comparing every
            // existing item with every added one, which for a large archive and a
            // large folder is tens of millions of comparisons.
            func isUnderReplacedFile(_ path: String) -> Bool {
                var parent = Substring(path)
                while let slash = parent.lastIndex(of: "/") {
                    parent = parent[..<slash]
                    if replacedByFiles.contains(String(parent)) { return true }
                }
                return false
            }
            let removed = existing.filter { item in
                replaced.contains(item.path) || (!replacedByFiles.isEmpty && isUnderReplacedFile(item.path))
            }.map(\.index)
            return Edit(removed: removed, renames: [], added: added)
        }
    }

    public func delete(entries: [ArchiveEntry], from archive: URL, password: String?) async throws {
        guard !entries.isEmpty else { return }
        try await rewrite(archive, password: password, options: nil) { bridge in
            Edit(removed: Self.indices(of: entries, in: bridge, withMacMetadata: true), renames: [], added: [])
        }
    }

    /// Renames an item. A folder takes everything inside it along.
    public func rename(entry: ArchiveEntry, to newPath: String, in archive: URL, password: String?) async throws {
        guard PathSafety.isSafe(entryPath: newPath) else { throw ArchiveError.unsafeEntry(newPath) }
        let from = entry.path
        let to = ArchivePath.normalize(newPath)
        guard from != to else { return }
        // Names the list leaves out as the Mac's bookkeeping. Something renamed to
        // one would still be in the archive and could not be seen, extracted or
        // renamed back.
        guard !MacMetadata.isMetadata(path: to) else {
            throw ArchiveError.ioFailure(
                L("“%@” is a name macOS keeps for its own bookkeeping, and files with it are not shown. Choose another name.",
                  (to as NSString).lastPathComponent))
        }

        try await rewrite(archive, password: password, options: nil) { bridge in
            let items = bridge.indices()
            func moved(_ path: String) -> String? {
                if path == from { return to }
                if path.hasPrefix(from + "/") { return to + path.dropFirst(from.count) }
                return nil
            }
            let renames = items.compactMap { item -> (index: UInt32, path: String)? in
                if let path = moved(item.path) { return (item.index, path) }
                // The hidden `._name` and `__MACOSX` companions follow what they
                // describe, or they would be left behind under the old name.
                if let described = MacMetadata.itemDescribed(by: item.path), let renamed = moved(described),
                   let companion = MacMetadata.path(item.path, redescribing: renamed) {
                    return (item.index, companion)
                }
                return nil
            }
            // Two items with one path cannot be told apart afterwards: the list shows
            // one, and deleting it removes both.
            let moving = Set(renames.map(\.index))
            let taken = items.contains { !moving.contains($0.index) && ($0.path == to || $0.path.hasPrefix(to + "/")) }
            if taken {
                throw ArchiveError.ioFailure(
                    L("%@ already exists in the archive.", (to as NSString).lastPathComponent))
            }
            return Edit(removed: [], renames: renames, added: [])
        }
    }

    /// Writes an edited copy of one entry back, keeping its path inside the archive.
    public func update(fileAt localURL: URL,
                       entryPath: String,
                       in archive: URL,
                       options: CompressionOptions,
                       cancellation: CancellationToken? = nil,
                       progress: ProgressHandler? = nil) async throws {
        let path = ArchivePath.normalize(entryPath)
        guard PathSafety.isSafe(entryPath: path) else { throw ArchiveError.unsafeEntry(entryPath) }
        try await rewrite(archive, password: options.password, options: options,
                          cancellation: cancellation, progress: progress) { bridge in
            let removed = bridge.indices().filter { $0.path == path }.map(\.index)
            return Edit(removed: removed, renames: [],
                        added: [.init(archivePath: path, diskURL: localURL)])
        }
    }

    public func release(archive: URL) {
        NestedTarCache.shared.forget(archive)
    }

    // MARK: - Rewriting

    struct Edit {
        var removed: [UInt32]
        var renames: [(index: UInt32, path: String)]
        var added: [BridgeArchive.NewItem]
    }

    /// Every edit is a rewrite: 7-Zip copies the untouched items across without
    /// recompressing them, applies the edit, and the result replaces the original.
    private func rewrite(_ archive: URL,
                         password: String?,
                         options: CompressionOptions?,
                         cancellation: CancellationToken? = nil,
                         progress: ProgressHandler? = nil,
                         edit: @escaping @Sendable (BridgeArchive) throws -> Edit) async throws {
        let codePage = CodePageMemory.codePage(for: archive)
        try await Self.blocking {
            let whole = BridgeProgress(handler: progress, cancellation: cancellation)
            let readable = try Readable.open(archive, password: password, codePage: codePage,
                                             unwrapProgress: whole.slice(offset: 0, span: 0.3))
            let changes = try edit(readable.bridge)
            if changes.removed.isEmpty, changes.renames.isEmpty, changes.added.isEmpty { return }

            let info = readable.bridge.info
            let formatName = info.formatName.lowercased()
            guard SevenZipLibrary.writableFormatNames.contains(where: { $0.lowercased() == formatName }) else {
                throw ArchiveError.notWritable(FormatRegistry.format(for: archive)?.displayName ?? info.formatName)
            }

            // Keep the archive as protected as it was: a header-encrypted 7z stays so.
            let settings = BridgeArchive.WriteSettings(
                formatName: formatName,
                level: options?.level ?? 5,
                password: options?.password ?? password,
                zipEncryption: options?.zipEncryption ?? .aes256,
                encryptHeaders: info.hasEncryptedHeader || (options?.encryptFileNames ?? false),
                solid: formatName == "7z" ? (options?.solid ?? info.isSolid) : nil)

            let scratch = try Scratch(beside: archive)
            defer { scratch.remove() }
            let output = scratch.file("justarc-output")

            if let outer = readable.outer {
                // Rewrite the tar, then compress it again the way it was compressed.
                let tar = try scratch.file(outer.innerName, inSubfolder: "tar")
                try readable.bridge.write(removed: changes.removed, renames: changes.renames,
                                          added: changes.added, to: tar, settings: settings,
                                          progress: whole.slice(offset: 0.3, span: 0.4))
                var outerSettings = settings
                outerSettings.formatName = outer.info.formatName.lowercased()
                outerSettings.password = nil
                try BridgeArchive.create(added: [.init(archivePath: outer.innerName, diskURL: tar)],
                                         to: output, settings: outerSettings,
                                         progress: whole.slice(offset: 0.7, span: 0.3))
            } else {
                try readable.bridge.write(removed: changes.removed, renames: changes.renames,
                                          added: changes.added, to: output, settings: settings,
                                          progress: readable.didUnwrap ? whole.slice(offset: 0.3, span: 0.7) : whole)
            }
            try Self.place(output, at: archive)
        }
        // No check for cancellation here: by now the archive has been replaced, and
        // reporting a cancel would leave the window showing what is no longer there.
        NestedTarCache.shared.forget(archive)
        progress?(ArchiveProgress(fraction: 1, currentFile: nil))
    }

    // MARK: - Helpers

    /// Runs bridge work on a plain dispatch thread; it blocks for as long as the
    /// archive takes, which would starve Swift's cooperative pool.
    static func blocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    /// The indices behind `entries`, with everything inside the folders among them.
    /// Folders the browser shows but the archive never stored are covered too.
    /// - Parameter withMacMetadata: also take the `._name` and `__MACOSX` companions
    ///   of what was asked for. Extraction leaves them behind; deletion must not, or
    ///   the names of deleted files stay in an archive that looks clean.
    static func indices(of entries: [ArchiveEntry], in bridge: BridgeArchive,
                        withMacMetadata: Bool = false) -> [UInt32] {
        let wanted = Set(entries.map(\.path))
        func isWanted(_ path: String) -> Bool {
            if wanted.contains(path) { return true }
            var parent = Substring(path)
            while let slash = parent.lastIndex(of: "/") {
                parent = parent[..<slash]
                if wanted.contains(String(parent)) { return true }
            }
            return false
        }
        return bridge.indices().filter { item in
            if wanted.contains(item.path) { return true }
            guard MacMetadata.isMetadata(path: item.path) else { return isWanted(item.path) }
            guard withMacMetadata, let described = MacMetadata.itemDescribed(by: item.path) else { return false }
            return isWanted(described)
        }.map(\.index)
    }

    /// Every index but macOS's bookkeeping, or nil when the archive has none of it and
    /// can simply be extracted whole.
    static func indicesWithoutMacMetadata(in bridge: BridgeArchive) -> [UInt32]? {
        let all = bridge.indices()
        let kept = all.filter { !MacMetadata.isMetadata(path: $0.path) }
        return kept.count == all.count ? nil : kept.map(\.index)
    }

    /// Everything to store for `items`, folders expanded, each under its own name
    /// inside `folder`, or at the archive root when that is empty. Symbolic links are
    /// stored as links, never followed.
    static func collect(_ items: [URL], into folder: String = "",
                        excludeMacMetadata: Bool) throws -> [BridgeArchive.NewItem] {
        var result: [BridgeArchive.NewItem] = []
        for item in items {
            if excludeMacMetadata && isMacMetadata(item.lastPathComponent) { continue }
            let name = ArchivePath.join(folder, item.lastPathComponent)
            guard PathSafety.itemExists(at: item) else {
                throw ArchiveError.ioFailure(L("%@ was not found.", item.path))
            }
            // Pipes, sockets and devices have nothing to store, and opening a pipe to
            // read it waits for ever for someone to write to it.
            guard isStorable(item) else { continue }
            result.append(.init(archivePath: name, diskURL: item))
            guard isDirectory(item), !isSymbolicLink(item) else { continue }

            // Not FileManager's enumerators: they leave out every file whose name
            // starts with "._", which is not their decision to make. Whether those
            // are stored is the user's choice, applied just below.
            let relatives = ((try? FileManager.default.subpathsOfDirectory(atPath: item.path)) ?? []).sorted()
            for relative in relatives {
                if excludeMacMetadata,
                   relative.split(separator: "/").contains(where: { isMacMetadata(String($0)) }) {
                    continue
                }
                let child = item.appendingPathComponent(relative)
                guard isStorable(child) else { continue }
                result.append(.init(archivePath: name + "/" + relative, diskURL: child))
            }
        }
        // Two items of the same name, from different folders, would otherwise be
        // stored under one path. The later one wins, as it would in the Finder.
        var seen = Set<String>()
        return result.reversed().filter { seen.insert($0.archivePath).inserted }.reversed()
    }

    /// Files, folders and symbolic links.
    private static func isStorable(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return true }
        let kind = info.st_mode & S_IFMT
        return kind == S_IFREG || kind == S_IFDIR || kind == S_IFLNK
    }

    static func isMacMetadata(_ name: String) -> Bool {
        name == ".DS_Store" || name == "__MACOSX" || name.hasPrefix("._")
    }

    static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    /// "photos.tar.gz" → "photos.tar", "photos.tgz" → "photos.tar".
    static func innerTarName(for archive: URL) -> String {
        var base = archive.deletingPathExtension().lastPathComponent
        if !base.lowercased().hasSuffix(".tar") { base += ".tar" }
        return base
    }

    /// Moves a finished archive over the destination in one step.
    static func place(_ output: URL, at archive: URL) throws {
        let fileManager = FileManager.default
        if PathSafety.itemExists(at: archive) {
            _ = try fileManager.replaceItemAt(archive, withItemAt: output)
        } else {
            try fileManager.moveItem(at: output, to: archive)
        }
    }

    /// Cuts a finished archive into `name.001`, `name.002`, …, which is how 7-Zip
    /// writes volumes and what it reads back.
    static func split(_ output: URL, into archive: URL, volumeBytes: UInt64) throws {
        let input = try FileHandle(forReadingFrom: output)
        defer { try? input.close() }

        var part = 1
        let chunk = 4 * 1024 * 1024
        while true {
            var written: UInt64 = 0
            let volume = URL(fileURLWithPath: archive.path + String(format: ".%03d", part))
            var handle: FileHandle?
            while written < volumeBytes {
                let wanted = Int(min(UInt64(chunk), volumeBytes - written))
                guard let data = try input.read(upToCount: wanted), !data.isEmpty else { break }
                if handle == nil {
                    if PathSafety.itemExists(at: volume) { try FileManager.default.removeItem(at: volume) }
                    FileManager.default.createFile(atPath: volume.path, contents: nil)
                    handle = try FileHandle(forWritingTo: volume)
                }
                try handle?.write(contentsOf: data)
                written += UInt64(data.count)
            }
            try handle?.close()
            guard handle != nil, written == volumeBytes else {
                if handle == nil { part -= 1 }
                break
            }
            part += 1
        }

        // Volumes left from an earlier, larger save would be read as part of this one.
        var stale = part + 1
        while true {
            let volume = URL(fileURLWithPath: archive.path + String(format: ".%03d", stale))
            guard PathSafety.itemExists(at: volume) else { break }
            try? FileManager.default.removeItem(at: volume)
            stale += 1
        }
    }

    /// "100m" → 104857600. 7-Zip's units are powers of 1024.
    static func volumeBytes(_ spec: String) throws -> UInt64? {
        let text = spec.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return nil }
        let multipliers: [Character: UInt64] = ["b": 1, "k": 1 << 10, "m": 1 << 20, "g": 1 << 30]
        var digits = text
        var multiplier: UInt64 = 1
        if let last = text.last, let value = multipliers[last] {
            multiplier = value
            digits.removeLast()
        }
        guard let count = UInt64(digits), count > 0 else {
            throw ArchiveError.ioFailure(L("%@ is not a volume size.", spec))
        }
        let (bytes, overflow) = count.multipliedReportingOverflow(by: multiplier)
        guard !overflow else {
            throw ArchiveError.ioFailure(L("%@ is not a volume size.", spec))
        }
        return bytes
    }
}

// MARK: - Opening for reading

/// An archive opened for reading, with a compressed tar already unwrapped.
private struct Readable {
    let bridge: BridgeArchive
    /// The compressed stream around the tar, when there is one.
    let outer: NestedTarCache.Outer?
    /// True when this call did the unwrapping, rather than finding it cached.
    let didUnwrap: Bool

    static func open(_ archive: URL, password: String?, codePage: Int?,
                     unwrapProgress: BridgeProgress) throws -> Readable {
        if let cached = NestedTarCache.shared.lookup(archive) {
            let tar = try BridgeArchive.open(cached.tar, password: nil, codePage: codePage)
            return Readable(bridge: tar, outer: cached.outer, didUnwrap: false)
        }

        let bridge = try BridgeArchive.open(archive, password: password, codePage: codePage)
        guard NestedTarCache.mayHoldTar(bridge, archive: archive) else {
            return Readable(bridge: bridge, outer: nil, didUnwrap: false)
        }
        guard let unwrapped = try NestedTarCache.shared.unwrap(bridge, archive: archive,
                                                               codePage: codePage,
                                                               progress: unwrapProgress) else {
            return Readable(bridge: bridge, outer: nil, didUnwrap: false)
        }
        return Readable(bridge: unwrapped.tar, outer: unwrapped.outer, didUnwrap: true)
    }
}

/// Watches a folder being written into and says when it has grown too large.
final class GrowthLimiter: @unchecked Sendable {
    private let folder: URL
    private let limit: UInt64
    private let lock = NSLock()
    private var lastCheck: TimeInterval = 0
    private var hasTripped = false

    /// - Parameter ceiling: a limit of its own, for tests. Normally the only limit is
    ///   the room on the disk: a compressed tar of a hundred gigabytes is a backup,
    ///   not a bomb, and there is no size at which one becomes the other.
    init(folder: URL, ceiling: UInt64 = .max) {
        self.folder = folder
        let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage).map { UInt64(max($0, 0)) } ?? ceiling
        // Leave the disk a margin: a full startup volume makes everything else fail.
        // On a disk with less than that to spare, half of what there is, so that a
        // small archive can still be opened.
        let margin: UInt64 = 1 << 30
        limit = min(ceiling, free > 2 * margin ? free - margin : free / 2)
    }

    var tripped: Bool {
        lock.lock(); defer { lock.unlock() }
        return hasTripped
    }

    /// Cheap to call often: the folder is only measured a few times a second.
    func allowsMore() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if hasTripped { return false }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastCheck >= 0.25 else { return true }
        lastCheck = now

        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let size = files.reduce(UInt64(0)) { total, file in
            total.addingSaturating(UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        }
        if size > limit { hasTripped = true }
        return !hasTripped
    }
}

/// Holds the unwrapped tar inside each `.tar.gz` and friends that has been opened,
/// so browsing, previewing and extracting do not decompress the whole stream again
/// every time. An entry is dropped when its archive changes on disk or is released.
final class NestedTarCache: @unchecked Sendable {
    static let shared = NestedTarCache()

    struct Outer {
        let info: ArchiveInfo
        /// The tar's name inside the compressed stream.
        let innerName: String
    }

    private struct Stamp: Equatable {
        let size: UInt64
        let modified: Date
        init?(_ url: URL) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? UInt64,
                  let modified = attributes[.modificationDate] as? Date else { return nil }
            self.size = size
            self.modified = modified
        }
    }

    private struct Entry {
        let stamp: Stamp
        let folder: URL
        let tar: URL
        let outer: Outer
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("JustArc-Unwrapped")

    /// Single-stream formats that are usually a tar in disguise.
    private static let streamFormats: Set<String> = ["gzip", "bzip2", "xz", "zstd", "z", "lzma", "lz4", "lzip"]
    private static let alwaysTarKeys: Set<String> = ["tgz", "tbz2", "txz", "tzst", "taz"]

    static func mayHoldTar(_ bridge: BridgeArchive, archive: URL) -> Bool {
        guard streamFormats.contains(bridge.formatName.lowercased()), bridge.itemCount == 1 else { return false }
        if alwaysTarKeys.contains(FormatRegistry.format(for: archive)?.key ?? "") { return true }
        return bridge.item(0)?.path.lowercased().hasSuffix(".tar") == true
    }

    func lookup(_ archive: URL) -> (tar: URL, outer: Outer)? {
        let key = archive.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        guard Stamp(archive) == entry.stamp, FileManager.default.fileExists(atPath: entry.tar.path) else {
            try? FileManager.default.removeItem(at: entry.folder)
            entries[key] = nil
            return nil
        }
        return (entry.tar, entry.outer)
    }

    /// Decompresses the stream into a temporary tar and opens it. Returns nil when
    /// the payload turns out not to be a tar after all.
    func unwrap(_ outer: BridgeArchive, archive: URL, codePage: Int?,
                progress: BridgeProgress) throws -> (tar: BridgeArchive, outer: Outer)? {
        guard let stamp = Stamp(archive) else { return nil }
        let folder = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // The stream says nothing reliable about how large it will grow, and a few
        // megabytes can expand to more than the disk holds, so the growing file is
        // watched and the work stopped before it gets there.
        let limiter = GrowthLimiter(folder: folder)
        do {
            do {
                try outer.extract(indices: [0], destination: folder, password: nil, overwrite: .overwrite,
                                  flatten: true, testOnly: false,
                                  progress: progress.guarded(by: limiter.allowsMore))
            } catch where limiter.tripped {
                throw ArchiveError.ioFailure(
                    L("%@ expands to more than this Mac has room for, so it was not opened.",
                      archive.lastPathComponent))
            }
            guard let produced = try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil).first else {
                throw ArchiveError.ioFailure(L("%@ was not found after extraction.", archive.lastPathComponent))
            }
            guard let tar = try? BridgeArchive.open(produced, password: nil, codePage: codePage),
                  tar.formatName.lowercased() == "tar" else {
                try? FileManager.default.removeItem(at: folder)
                return nil
            }

            let info = Outer(info: outer.info, innerName: produced.lastPathComponent)
            let key = archive.standardizedFileURL.path
            lock.lock()
            if let old = entries[key] { try? FileManager.default.removeItem(at: old.folder) }
            entries[key] = Entry(stamp: stamp, folder: folder, tar: produced, outer: info)
            lock.unlock()
            return (tar, info)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func forget(_ archive: URL) {
        let key = archive.standardizedFileURL.path
        lock.lock()
        let entry = entries.removeValue(forKey: key)
        lock.unlock()
        if let entry { try? FileManager.default.removeItem(at: entry.folder) }
    }

    func forgetAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - Writing recipes

/// How a format key turns into 7-Zip handlers: a container, a compressor, or a tar
/// that is then compressed.
private struct WriteRecipe {
    let container: String?
    let compressor: String?

    init(formatKey: String, displayName: String) throws {
        switch formatKey {
        case "zip", "7z", "tar": (container, compressor) = (formatKey, nil)
        case "gzip", "bzip2", "xz", "zstd": (container, compressor) = (nil, formatKey)
        case "tgz": (container, compressor) = ("tar", "gzip")
        case "tbz2": (container, compressor) = ("tar", "bzip2")
        case "txz": (container, compressor) = ("tar", "xz")
        case "tzst": (container, compressor) = ("tar", "zstd")
        default: throw ArchiveError.notWritable(displayName)
        }
        let writable = Set(SevenZipLibrary.writableFormatNames.map { $0.lowercased() })
        for name in [container, compressor].compactMap({ $0 }) where !writable.contains(name) {
            throw ArchiveError.notWritable(displayName)
        }
    }

    func settings(_ options: CompressionOptions, formatName: String) -> BridgeArchive.WriteSettings {
        BridgeArchive.WriteSettings(formatName: formatName,
                                    level: options.level,
                                    password: options.password,
                                    zipEncryption: options.zipEncryption,
                                    encryptHeaders: options.encryptFileNames,
                                    solid: formatName == "7z" ? options.solid : nil)
    }
}

/// A private folder for work in progress, on the archive's own volume so the finished
/// file moves into place in one step.
///
/// The system's item-replacement directory is the first choice: it sits out of sight
/// and is cleared by the system if the app dies midway. A hidden folder beside the
/// archive is the fallback for volumes that have none.
private struct Scratch {
    let folder: URL

    init(beside archive: URL) throws {
        let fileManager = FileManager.default
        let parent = archive.deletingLastPathComponent()
        if let replacement = try? fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                  appropriateFor: parent, create: true) {
            folder = replacement
            return
        }
        folder = parent.appendingPathComponent(".justarc-\(UUID().uuidString)")
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw ArchiveError.ioFailure(L("JustArc cannot write to %@.", parent.path))
        }
    }

    func file(_ name: String) -> URL { folder.appendingPathComponent(name) }

    /// A file in a folder of its own, for a name that comes from the archive and
    /// could otherwise be the same as one of ours.
    func file(_ name: String, inSubfolder subfolder: String) throws -> URL {
        let directory = folder.appendingPathComponent(subfolder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    func remove() { try? FileManager.default.removeItem(at: folder) }
}

/// The text encoding last chosen for an archive's names, so extracting and editing
/// read the names the same way the listing did.
enum CodePageMemory {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pages: [String: Int] = [:]

    static func remember(_ codePage: Int?, for archive: URL) {
        lock.lock()
        pages[archive.standardizedFileURL.path] = codePage
        lock.unlock()
    }

    static func codePage(for archive: URL) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return pages[archive.standardizedFileURL.path]
    }
}
