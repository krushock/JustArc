import Foundation

/// Writes RAR archives with RARLAB's `rar` tool, which cannot be bundled because of
/// its licence. Reading goes through 7-Zip, which handles RAR and RAR5 on its own,
/// so this engine only takes over the operations 7-Zip cannot perform.
public struct RarEngine: ArchiveEngine, VerbatimExtractor {
    private let reader = SevenZipEngine()

    public init() {}

    public static let installHint =
        L("Install RARLAB's command line tool, then point JustArc at it in Settings.")

    // MARK: - Reading, delegated to 7-Zip

    public func list(archive: URL, password: String?, encodingCodePage: Int?) async throws -> ArchiveListing {
        try await reader.list(archive: archive, password: password, encodingCodePage: encodingCodePage)
    }

    public func extract(archive: URL, entries: [ArchiveEntry]?, to destination: URL,
                        password: String?, overwrite: OverwriteMode = .renameNew,
                        flattenPaths: Bool = false, cancellation: CancellationToken? = nil,
                        progress: ProgressHandler? = nil) async throws {
        try await reader.extract(archive: archive, entries: entries, to: destination,
                                 password: password, overwrite: overwrite,
                                 flattenPaths: flattenPaths, cancellation: cancellation,
                                 progress: progress)
    }

    func extractVerbatim(archive: URL, excluding: Set<String>, under scratch: URL,
                         password: String?, cancellation: CancellationToken?,
                         progress: ProgressHandler?) async throws -> [URL] {
        try await reader.extractVerbatim(archive: archive, excluding: excluding, under: scratch,
                                         password: password, cancellation: cancellation, progress: progress)
    }

    public func test(archive: URL, password: String?, cancellation: CancellationToken? = nil,
                     progress: ProgressHandler? = nil) async throws -> String {
        try await reader.test(archive: archive, password: password,
                              cancellation: cancellation, progress: progress)
    }

    // MARK: - Writing, which needs the external tool

    public func create(archive: URL, items: [URL], options: CompressionOptions,
                       cancellation: CancellationToken? = nil,
                       progress: ProgressHandler? = nil) async throws {
        if FileManager.default.fileExists(atPath: archive.path) {
            try FileManager.default.removeItem(at: archive)
        }
        try await add(items: items, to: archive, options: options,
                      cancellation: cancellation, progress: progress)
    }

    public func add(items: [URL], to archive: URL, into folder: String, options: CompressionOptions,
                    cancellation: CancellationToken? = nil,
                    progress: ProgressHandler? = nil) async throws {
        guard !items.isEmpty else { return }
        let folder = ArchivePath.normalize(folder)
        guard folder.isEmpty || PathSafety.isSafe(entryPath: folder) else {
            throw ArchiveError.unsafeEntry(folder)
        }
        let tool = try Self.requireTool()
        let reporter = ProgressReporter(handler: progress)

        let plan = try AddPlan(items: items, excludeMacMetadata: options.excludeMacMetadata)
        defer { plan.cleanup() }
        guard let list = plan.listFile else { return }

        // Everything in one run. Several would each rewrite the archive, and cannot
        // be done at all to one that is being split into volumes.
        let arguments = Self.addArguments(archive: archive, listFile: list, options: options, folder: folder,
                                          exclusions: plan.exclusions, wholeFolder: plan.directory != nil)
        let result = try await ProcessRunner.run(executable: tool,
                                                 arguments: arguments,
                                                 currentDirectory: plan.directory,
                                                 cancellation: cancellation,
                                                 onOutput: { reporter.consume($0) })
        if cancellation?.isCancelled == true { throw ArchiveError.cancelled }
        try Self.check(result, password: options.password)
        progress?(ArchiveProgress(fraction: 1, currentFile: nil))
    }

    /// How a set of items is handed to rar.
    ///
    /// Normally by their full paths, in a list file, with the switch that stores
    /// each under its own name. Two things that cannot be said that way get laid
    /// out in a folder of their own first, which is then archived whole:
    ///
    /// - items that share a name, where the later one replaces the earlier and two
    ///   folders merge, as they would in the Finder;
    /// - a path with "?" or "*" in it, which rar reads as a pattern, so that adding
    ///   "a?.txt" would take "ab.txt" beside it along;
    /// - a path a list file cannot hold, because it ends in a space or has a line
    ///   break in it.
    struct AddPlan {
        private(set) var listFile: URL?
        private(set) var exclusions: URL?
        /// The folder to run in when everything was laid out, and nil otherwise.
        private(set) var directory: URL?

        init(items: [URL], excludeMacMetadata: Bool) throws {
            var items = items
            if excludeMacMetadata { items.removeAll { SevenZipEngine.isMacMetadata($0.lastPathComponent) } }
            for item in items where !PathSafety.itemExists(at: item) {
                throw ArchiveError.ioFailure(L("%@ was not found.", item.path))
            }
            guard !items.isEmpty else { return }

            let names = items.map(\.lastPathComponent)
            let isPlain = Set(names).count == names.count
                && !items.contains { RarEngine.holdsWildcard($0.path) || RarEngine.cannotBeListed($0.path) }
            guard !isPlain else {
                listFile = try RarEngine.writeListFile(items.map(\.path))
                if excludeMacMetadata {
                    let found = items.flatMap(Self.macMetadata(under:))
                    if !found.isEmpty { exclusions = try RarEngine.writeListFile(found.map(\.path)) }
                }
                return
            }

            let layout = FileManager.default.temporaryDirectory
                .appendingPathComponent("justarc-rar-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: layout, withIntermediateDirectories: true)
            directory = layout
            do {
                for item in items {
                    try ArchiveSession.mergeCopy(item, to: layout.appendingPathComponent(item.lastPathComponent))
                }
                if excludeMacMetadata {
                    for found in Self.macMetadata(under: layout) { try? FileManager.default.removeItem(at: found) }
                }
                listFile = try RarEngine.writeListFile(["*"])
            } catch {
                cleanup()
                throw error
            }
        }

        func cleanup() {
            for url in [listFile, exclusions, directory] {
                if let url { try? FileManager.default.removeItem(at: url) }
            }
        }

        /// Every `.DS_Store`, `._name` and `__MACOSX` inside a folder. They are named
        /// one by one because a pattern cannot say it: "*.DS_Store" also takes
        /// "notes.DS_Store", and "*__MACOSX*" a file that merely mentions it.
        private static func macMetadata(under item: URL) -> [URL] {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { return [] }
            // Not an enumerator: FileManager's leave out the "._" files themselves.
            let relatives = ((try? FileManager.default.subpathsOfDirectory(atPath: item.path)) ?? []).sorted()
            var found: [String] = []
            for relative in relatives {
                // What is inside one already found goes with it.
                if let last = found.last, relative.hasPrefix(last + "/") { continue }
                if SevenZipEngine.isMacMetadata((relative as NSString).lastPathComponent) { found.append(relative) }
            }
            return found.map { item.appendingPathComponent($0) }
        }
    }

    /// Whether rar would read this as a pattern instead of a name.
    static func holdsWildcard(_ name: String) -> Bool {
        name.contains { $0 == "?" || $0 == "*" }
    }

    /// Whether a name would be changed by being written as one line of a list
    /// file, where a line break ends it and spaces at either end are dropped.
    static func cannotBeListed(_ name: String) -> Bool {
        name.contains(where: \.isNewline) || name != name.trimmingCharacters(in: .whitespaces)
            || name.hasPrefix("//")
    }

    /// Names go to rar in a list file, never on its command line. There a name such
    /// as "-df" is read as a switch (that one deletes the files after archiving), and
    /// several thousand names do not fit at all.
    static func writeListFile(_ names: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("justarc-rar-\(UUID().uuidString).lst")
        try Data((names.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
        return url
    }

    public func delete(entries: [ArchiveEntry], from archive: URL, password: String?) async throws {
        guard !entries.isEmpty else { return }
        let tool = try Self.requireTool()
        let victims = Set(entries.map(\.path))

        func run(on target: URL, sparing: [String]) async throws {
            var arguments = ["d", "-y"]
            if let password, !password.isEmpty { arguments.append("-p\(password)") }
            var lists: [URL] = []
            defer { lists.forEach { try? FileManager.default.removeItem(at: $0) } }
            if !sparing.isEmpty {
                let spared = try Self.writeListFile(sparing)
                lists.append(spared)
                arguments.append("-x@" + spared.path)
            }
            let names = entries.map(\.path)
            if names.contains(where: Self.cannotBeListed) {
                // A name a list file cannot hold has to go on the command line, where
                // "-@" keeps one that starts with "@" from being read as a list, and
                // "--" one that starts with "-" from being read as a switch.
                guard names.reduce(0, { $0 + $1.utf8.count + 1 }) < 200_000 else {
                    throw ArchiveError.ioFailure(
                        L("Too many items to delete from a RAR archive at once when one of their names ends in a space or holds a line break. Delete that one separately."))
                }
                arguments.append(contentsOf: ["-@", "--", target.path] + names)
            } else {
                let list = try Self.writeListFile(names)
                lists.append(list)
                arguments.append(contentsOf: ["--", target.path, "@" + list.path])
            }
            let result = try await ProcessRunner.run(executable: tool, arguments: arguments)
            try Self.check(result, password: password)
        }

        if entries.contains(where: { Self.holdsWildcard($0.path) }) {
            // "what?.txt" is a pattern to rar, and "whats.txt" matches it. So
            // everything that is to stay is named as an exception, and the result is
            // checked before it replaces the archive.
            func isVictim(_ path: String) -> Bool {
                victims.contains(path) || Self.ancestors(of: path).contains(where: victims.contains)
            }
            try await changeCarefully(archive, password: password, naming: entries.map(\.path),
                                      expecting: { $0.filter { !isVictim($0) } },
                                      change: { copy, before in
                                          try await run(on: copy, sparing: before.filter { !isVictim($0) }.sorted())
                                      })
        } else {
            try await run(on: archive, sparing: [])
        }
        // rar removes an archive rather than leave it with nothing in it. The other
        // formats keep an empty archive, which can be added to again.
        if !PathSafety.itemExists(at: archive) { try Self.emptyArchive.write(to: archive, options: .atomic) }
    }

    public func rename(entry: ArchiveEntry, to newPath: String, in archive: URL,
                       password: String?) async throws {
        guard PathSafety.isSafe(entryPath: newPath) else { throw ArchiveError.unsafeEntry(newPath) }
        let tool = try Self.requireTool()
        let from = entry.path
        let to = ArchivePath.normalize(newPath)

        func run(on target: URL) async throws {
            var arguments = ["rn", "-y"]
            if let password, !password.isEmpty { arguments.append("-p\(password)") }
            // "--" ends the switches, and "-@" stops a name starting with "@" being read
            // as a list file, so an entry's name is only ever a name.
            arguments.append(contentsOf: ["-@", "--", target.path, from, to])
            let result = try await ProcessRunner.run(executable: tool, arguments: arguments)
            try Self.check(result, password: password)
        }

        guard Self.holdsWildcard(from) || Self.holdsWildcard(to) else {
            try await run(on: archive)
            return
        }
        try await changeCarefully(archive, password: password, naming: [from],
                                  expecting: { before in
                                      Set(before.map { path in
                                          if path == from { return to }
                                          if path.hasPrefix(from + "/") { return to + path.dropFirst(from.count) }
                                          return path
                                      })
                                  },
                                  change: { copy, _ in try await run(on: copy) })
    }

    /// Makes a change that rar might apply to more than was meant, because a name in
    /// it reads as a pattern. The change is made to a copy, and the copy takes the
    /// archive's place only if it then holds exactly what it should.
    private func changeCarefully(_ archive: URL, password: String?, naming names: [String],
                                 expecting expected: (Set<String>) -> Set<String>,
                                 change: (URL, Set<String>) async throws -> Void) async throws {
        let fileManager = FileManager.default
        let before = Set(try await reader.list(archive: archive, password: password, encodingCodePage: nil)
            .entries.map(\.path))
        let folder = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                         appropriateFor: archive, create: true)
        defer { try? fileManager.removeItem(at: folder) }
        let copy = folder.appendingPathComponent(archive.lastPathComponent)
        try fileManager.copyItem(at: archive, to: copy)

        try await change(copy, before)

        var after = Set<String>()
        if PathSafety.itemExists(at: copy) {
            after = Set(try await reader.list(archive: copy, password: password, encodingCodePage: nil)
                .entries.map(\.path))
            reader.release(archive: copy)
        } else {
            try Self.emptyArchive.write(to: copy, options: .atomic)
        }
        guard after == expected(before) else {
            let name = names.first { Self.holdsWildcard($0) } ?? names.first ?? ""
            throw ArchiveError.ioFailure(
                L("RAR reads the “?” and “*” in “%@” as wildcards, and would have changed other items along with it. Nothing was changed.",
                  (name as NSString).lastPathComponent))
        }
        _ = try fileManager.replaceItemAt(archive, withItemAt: copy)
    }

    private static func ancestors(of path: String) -> [String] {
        var result: [String] = []
        var current = Substring(path)
        while let slash = current.lastIndex(of: "/") {
            current = current[..<slash]
            result.append(String(current))
        }
        return result
    }

    /// A RAR archive with nothing in it: the signature, the main header and the
    /// end-of-archive header, each with its checksum. rar will not write one, but
    /// reads it, and adds to it.
    static let emptyArchive = Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00,
                                    0xC5, 0x1A, 0x33, 0x32, 0x03, 0x01, 0x00, 0x00,
                                    0x1D, 0x77, 0x56, 0x51, 0x03, 0x05, 0x04, 0x00])

    public func update(fileAt localURL: URL, entryPath: String, in archive: URL,
                       options: CompressionOptions, cancellation: CancellationToken? = nil,
                       progress: ProgressHandler? = nil) async throws {
        let tool = try Self.requireTool()
        // A name that reads as a pattern is added from a folder holding nothing
        // else, so that it is the only thing the pattern can match.
        let staging = try EntryStaging(localURL: localURL, entryPath: entryPath,
                                       alone: Self.holdsWildcard(entryPath))
        defer { staging.cleanup() }

        var arguments = ["a", "-y"] + Self.compressionArguments(options)
        arguments.append(contentsOf: ["-@", "--", archive.path, staging.relativePath])

        let result = try await ProcessRunner.run(executable: tool,
                                                 arguments: arguments,
                                                 currentDirectory: staging.root,
                                                 cancellation: cancellation)
        try Self.check(result, password: options.password)
    }

    // MARK: - Argument building

    /// Exposed for tests: RAR's own switches differ enough from 7-Zip's to be worth pinning down.
    /// - Parameters:
    ///   - exclusions: a list file of paths to leave out.
    ///   - wholeFolder: the list holds "*" and rar runs inside a folder laid out for
    ///     it, everything in which is wanted.
    static func addArguments(archive: URL, listFile: URL, options: CompressionOptions,
                             folder: String = "", exclusions: URL? = nil,
                             wholeFolder: Bool = false) -> [String] {
        // -ol stores a symbolic link as a link. Without it rar follows them, so a
        // link to a folder brings that folder's contents and a link to its own
        // parent brings the folder again inside itself, sixty levels deep.
        var arguments = ["a", "-y", "-ol"] + compressionArguments(options)
        if wholeFolder {
            // -r is only safe here: it turns every name into a pattern looked for in
            // every subfolder, so with real names, adding one notes.txt would sweep
            // up each notes.txt beneath it.
            arguments.append("-r")
        } else {
            // The names are full paths; -ep1 stores each without the folders above it.
            // A folder named in the list is archived with everything in it anyway.
            arguments.append("-ep1")
        }
        // -ap sets the path the added files get inside the archive.
        if !folder.isEmpty { arguments.append("-ap\(folder)") }
        if let exclusions { arguments.append("-x@" + exclusions.path) }
        arguments.append(contentsOf: ["--", archive.path, "@" + listFile.path])
        return arguments
    }

    static func compressionArguments(_ options: CompressionOptions) -> [String] {
        var arguments = ["-m\(rarLevel(for: options.level))"]
        if let password = options.password, !password.isEmpty {
            // -hp also encrypts the file names; -p leaves the listing readable.
            arguments.append(options.encryptFileNames ? "-hp\(password)" : "-p\(password)")
        }
        if let volumeSize = options.volumeSize, !volumeSize.isEmpty {
            arguments.append("-v\(volumeSize)")
        }
        return arguments
    }

    /// RAR's compression scale is 0-5, ours is 0-9.
    static func rarLevel(for level: Int) -> Int {
        switch level {
        case ..<1: return 0
        case 1...2: return 1
        case 3...4: return 2
        case 5: return 3
        case 6...7: return 4
        default: return 5
        }
    }

    static func requireTool() throws -> URL {
        guard let tool = EngineLocator.externalRAR else {
            throw ArchiveError.externalToolMissing(name: "rar", hint: installHint)
        }
        return tool
    }

    private static func check(_ result: ProcessResult, password: String?) throws {
        // rar returns 0 for success and 1 for a warning such as a skipped open file.
        guard result.exitCode != 0, result.exitCode != 1 else { return }
        let lines = result.combined.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "Done" }
        // Its exit code says when the password was the trouble. Looking for the
        // words anywhere in what it printed does not: it prints file names, and a
        // file can be called "wrong password list.txt".
        let saysSo = lines.contains { line in
            let lowered = line.lowercased()
            return lowered.hasPrefix("incorrect password for ")
                || lowered.hasPrefix("the specified password is incorrect")
                || lowered.hasSuffix("corrupt file or wrong password.")
        }
        if result.exitCode == 11 || saysSo {
            throw (password?.isEmpty ?? true) ? ArchiveError.passwordRequired : ArchiveError.wrongPassword
        }
        throw ArchiveError.engineFailed(code: result.exitCode,
                                        message: lines.suffix(3).joined(separator: " "))
    }
}

/// Places a single edited file at the right relative path so an archiver run from
/// `root` stores it back under its original name.
struct EntryStaging {
    let root: URL
    let relativePath: String
    private let temporaryRoot: URL?

    /// - Parameter alone: always mirror the file into a tree of its own, even when
    ///   it already sits at the right path, where it has neighbours.
    init(localURL: URL, entryPath: String, alone: Bool = false) throws {
        let normalized = ArchivePath.normalize(entryPath)
        self.relativePath = normalized

        // When the file already sits at <root>/<entryPath>, use it in place.
        let suffix = "/" + normalized
        let localPath = localURL.standardizedFileURL.path
        if !alone, localPath.hasSuffix(suffix) {
            self.root = URL(fileURLWithPath: String(localPath.dropLast(suffix.count)))
            self.temporaryRoot = nil
            return
        }

        // Otherwise mirror it into a scratch tree that has the right shape.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("justarc-update-\(UUID().uuidString)")
        let target = scratch.appendingPathComponent(normalized)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: localURL, to: target)
        self.root = scratch
        self.temporaryRoot = scratch
    }

    func cleanup() {
        guard let temporaryRoot else { return }
        try? FileManager.default.removeItem(at: temporaryRoot)
    }
}

/// Turns a command-line tool's percentage output into progress updates. RARLAB's
/// `rar` prints progress the same way 7-Zip's command-line tool did.
final class ProgressReporter: @unchecked Sendable {
    private let handler: ProgressHandler?
    private let lock = NSLock()
    private var lastFraction: Double = -1
    private var lastFile: String?

    init(handler: ProgressHandler?) {
        self.handler = handler
    }

    func consume(_ chunk: String) {
        guard let handler else { return }
        // 7-Zip rewrites the progress line with carriage returns and backspaces.
        let pieces = chunk
            .replacingOccurrences(of: "\u{8}", with: "")
            .components(separatedBy: CharacterSet(charactersIn: "\r\n"))

        for piece in pieces {
            let line = piece.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            var fraction: Double?
            if let percentRange = line.range(of: #"^\s*(\d{1,3})%"#, options: .regularExpression) {
                let digits = line[percentRange].filter(\.isNumber)
                if let value = Double(digits) { fraction = min(max(value / 100, 0), 1) }
            }

            var file: String?
            if let dashRange = line.range(of: " - ") {
                file = String(line[dashRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("- ") {
                file = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }

            lock.lock()
            if let fraction { lastFraction = fraction }
            if let file, !file.isEmpty { lastFile = file }
            let reportFraction = lastFraction < 0 ? nil : lastFraction
            let reportFile = lastFile
            lock.unlock()

            if fraction != nil || file != nil {
                handler(ArchiveProgress(fraction: reportFraction, currentFile: reportFile))
            }
        }
    }
}
