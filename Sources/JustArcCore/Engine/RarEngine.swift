import Foundation

/// Writes RAR archives with RARLAB's `rar` tool, which cannot be bundled because of
/// its licence. Reading goes through 7-Zip, which handles RAR and RAR5 on its own,
/// so this engine only takes over the operations 7-Zip cannot perform.
public struct RarEngine: ArchiveEngine {
    private let reader = SevenZipEngine()

    public init() {}

    public static let installHint =
        "Install RARLAB's command line tool, then point JustArc at it in Settings."

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

    public func add(items: [URL], to archive: URL, options: CompressionOptions,
                    cancellation: CancellationToken? = nil,
                    progress: ProgressHandler? = nil) async throws {
        guard !items.isEmpty else { return }
        let tool = try Self.requireTool()
        let reporter = ProgressReporter(handler: progress)

        // One run per parent folder so each item is stored under its own name.
        var groups: [URL: [String]] = [:]
        for item in items {
            groups[item.deletingLastPathComponent().standardizedFileURL, default: []]
                .append(item.lastPathComponent)
        }

        for (parent, names) in groups {
            let arguments = Self.addArguments(archive: archive, names: names, options: options)
            let result = try await ProcessRunner.run(executable: tool,
                                                     arguments: arguments,
                                                     currentDirectory: parent,
                                                     cancellation: cancellation,
                                                     onOutput: { reporter.consume($0) })
            if cancellation?.isCancelled == true { throw ArchiveError.cancelled }
            try Self.check(result, password: options.password)
        }
        progress?(ArchiveProgress(fraction: 1, currentFile: nil))
    }

    public func delete(entries: [ArchiveEntry], from archive: URL, password: String?) async throws {
        guard !entries.isEmpty else { return }
        let tool = try Self.requireTool()
        var arguments = ["d", "-y"]
        if let password, !password.isEmpty { arguments.append("-p\(password)") }
        arguments.append(archive.path)
        arguments.append(contentsOf: entries.map(\.path))

        let result = try await ProcessRunner.run(executable: tool, arguments: arguments)
        try Self.check(result, password: password)
    }

    public func rename(entry: ArchiveEntry, to newPath: String, in archive: URL,
                       password: String?) async throws {
        guard PathSafety.isSafe(entryPath: newPath) else { throw ArchiveError.unsafeEntry(newPath) }
        let tool = try Self.requireTool()
        var arguments = ["rn", "-y"]
        if let password, !password.isEmpty { arguments.append("-p\(password)") }
        arguments.append(contentsOf: [archive.path, entry.path, ArchivePath.normalize(newPath)])

        let result = try await ProcessRunner.run(executable: tool, arguments: arguments)
        try Self.check(result, password: password)
    }

    public func update(fileAt localURL: URL, entryPath: String, in archive: URL,
                       options: CompressionOptions, cancellation: CancellationToken? = nil,
                       progress: ProgressHandler? = nil) async throws {
        let tool = try Self.requireTool()
        let staging = try EntryStaging(localURL: localURL, entryPath: entryPath)
        defer { staging.cleanup() }

        var arguments = ["a", "-y"] + Self.compressionArguments(options)
        arguments.append(archive.path)
        arguments.append(staging.relativePath)

        let result = try await ProcessRunner.run(executable: tool,
                                                 arguments: arguments,
                                                 currentDirectory: staging.root,
                                                 cancellation: cancellation)
        try Self.check(result, password: options.password)
    }

    // MARK: - Argument building

    /// Exposed for tests: RAR's own switches differ enough from 7-Zip's to be worth pinning down.
    static func addArguments(archive: URL, names: [String], options: CompressionOptions) -> [String] {
        var arguments = ["a", "-y", "-r"] + compressionArguments(options)
        if options.excludeMacMetadata {
            arguments.append(contentsOf: ["-x*.DS_Store", "-x*/.DS_Store", "-x*__MACOSX*", "-x*/._*"])
        }
        arguments.append(archive.path)
        arguments.append(contentsOf: names)
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
        let lowered = result.combined.lowercased()
        if lowered.contains("wrong password") || lowered.contains("incorrect password") {
            return try { throw (password?.isEmpty ?? true)
                ? ArchiveError.passwordRequired : ArchiveError.wrongPassword }()
        }
        let lines = result.combined.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
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

    init(localURL: URL, entryPath: String) throws {
        let normalized = ArchivePath.normalize(entryPath)
        self.relativePath = normalized

        // When the file already sits at <root>/<entryPath>, use it in place.
        let suffix = "/" + normalized
        let localPath = localURL.standardizedFileURL.path
        if localPath.hasSuffix(suffix) {
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
