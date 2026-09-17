import Foundation

/// Drives the bundled 7zz binary. Handles the nested-stream formats
/// (`.tar.gz`, `.tar.xz`, …) by piping the outer decompressor into a tar reader.
public struct SevenZipEngine: ArchiveEngine {
    public init() {}

    // Formats that are a compressed stream wrapping a tar.
    private static let alwaysNestedTar: Set<String> = ["tgz", "tbz2", "txz", "tzst", "taz"]
    // Single-stream compressors that may or may not hold a tar.
    private static let singleStreamCompressors: Set<String> = ["gzip", "bzip2", "xz", "zstd", "z", "lz4"]

    private static let commonFlags = ["-y", "-sccUTF-8", "-scsUTF-8"]

    // MARK: - Listing

    public func list(archive: URL, password: String?, encodingCodePage: Int? = nil) async throws -> ArchiveListing {
        let tool = try EngineLocator.requireSevenZip()
        var arguments = ["l", "-slt"] + Self.commonFlags
        arguments.append(passwordFlag(password))
        if let encodingCodePage { arguments.append("-mcp=\(encodingCodePage)") }
        arguments.append(archive.path)

        let result = try await ProcessRunner.run(executable: tool, arguments: arguments)
        if result.exitCode != 0 {
            throw Self.classify(result: result, password: password)
        }

        var listing = SevenZipListParser.parse(result.standardOutput)
        if needsNestedTarPass(archive: archive, listing: listing) {
            listing = try await listNestedTar(archive: archive, outer: listing, password: password)
        }
        return listing
    }

    private func needsNestedTarPass(archive: URL, listing: ArchiveListing) -> Bool {
        let key = FormatRegistry.format(for: archive)?.key ?? ""
        if Self.alwaysNestedTar.contains(key) { return true }
        guard Self.singleStreamCompressors.contains(key) else { return false }
        // A single payload named *.tar means the real content is one level deeper.
        guard listing.entries.count == 1, let only = listing.entries.first else { return false }
        return only.path.lowercased().hasSuffix(".tar")
    }

    private func listNestedTar(archive: URL, outer: ArchiveListing, password: String?) async throws -> ArchiveListing {
        let tool = try EngineLocator.requireSevenZip()
        let result = try await ProcessRunner.runPipeline(
            first: tool,
            firstArguments: ["x", "-so", passwordFlag(password), archive.path] + Self.commonFlags,
            second: tool,
            secondArguments: ["l", "-slt", "-si", "-ttar"] + Self.commonFlags)

        guard result.exitCode == 0 else {
            // Fall back to the outer view rather than failing the open outright.
            return outer
        }
        var inner = SevenZipListParser.parse(result.standardOutput)
        inner.info.formatName = outer.info.formatName.isEmpty
            ? inner.info.formatName
            : "\(outer.info.formatName) / tar"
        inner.info.physicalSize = outer.info.physicalSize
        return inner
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
        let tool = try EngineLocator.requireSevenZip()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        if let entries, let unsafePath = PathSafety.firstUnsafePath(in: entries) {
            throw ArchiveError.unsafeEntry(unsafePath)
        }

        let nested = try await isNestedTarArchive(archive)
        let listFile = try entries.map { try writeListFile(for: $0) }
        defer { if let listFile { try? FileManager.default.removeItem(at: listFile) } }

        let command = flattenPaths ? "e" : "x"
        let reporter = ProgressReporter(handler: progress)

        let result: ProcessResult
        if nested {
            var inner = [command, "-si", "-ttar", "-o\(destination.path)",
                         overwrite.sevenZipFlag, "-bsp1", "-bb1"] + Self.commonFlags
            if let listFile { inner.append(contentsOf: ["-spd", "-i@\(listFile.path)"]) }
            result = try await ProcessRunner.runPipeline(
                first: tool,
                firstArguments: ["x", "-so", passwordFlag(password), archive.path] + Self.commonFlags,
                second: tool,
                secondArguments: inner,
                cancellation: cancellation,
                onOutput: { reporter.consume($0) })
        } else {
            var arguments = [command, archive.path, "-o\(destination.path)",
                             overwrite.sevenZipFlag, "-bsp1", "-bb1"] + Self.commonFlags
            arguments.append(passwordFlag(password))
            if let listFile { arguments.append(contentsOf: ["-spd", "-i@\(listFile.path)"]) }
            result = try await ProcessRunner.run(executable: tool,
                                                 arguments: arguments,
                                                 cancellation: cancellation,
                                                 onOutput: { reporter.consume($0) })
        }

        if cancellation?.isCancelled == true { throw ArchiveError.cancelled }
        // 1 means "completed with warnings", which is not a failure for our purposes.
        if result.exitCode != 0 && result.exitCode != 1 {
            throw Self.classify(result: result, password: password)
        }
        progress?(ArchiveProgress(fraction: 1, currentFile: nil))
    }

    /// Extracts a single entry into a scratch folder and returns the file's URL,
    /// which is how the browser opens or previews one item.
    public func extractSingle(archive: URL,
                              entry: ArchiveEntry,
                              to scratch: URL,
                              password: String?,
                              cancellation: CancellationToken? = nil) async throws -> URL {
        try await extract(archive: archive,
                          entries: [entry],
                          to: scratch,
                          password: password,
                          overwrite: .overwrite,
                          flattenPaths: false,
                          cancellation: cancellation,
                          progress: nil)
        let produced = scratch.appendingPathComponent(entry.path)
        if FileManager.default.fileExists(atPath: produced.path) { return produced }
        // Some formats normalise separators; fall back to the leaf name.
        let leaf = scratch.appendingPathComponent(entry.name)
        if FileManager.default.fileExists(atPath: leaf.path) { return leaf }
        throw ArchiveError.ioFailure(L("%@ was not found after extraction.", entry.name))
    }

    private func isNestedTarArchive(_ archive: URL) async throws -> Bool {
        let key = FormatRegistry.format(for: archive)?.key ?? ""
        if Self.alwaysNestedTar.contains(key) { return true }
        guard Self.singleStreamCompressors.contains(key) else { return false }
        let tool = try EngineLocator.requireSevenZip()
        let probe = try await ProcessRunner.run(
            executable: tool,
            arguments: ["l", "-slt", "-p", archive.path] + Self.commonFlags)
        guard probe.exitCode == 0 else { return false }
        let listing = SevenZipListParser.parse(probe.standardOutput)
        return listing.entries.count == 1 && (listing.entries.first?.path.lowercased().hasSuffix(".tar") ?? false)
    }

    // MARK: - Testing

    public func test(archive: URL,
                     password: String?,
                     cancellation: CancellationToken? = nil,
                     progress: ProgressHandler? = nil) async throws -> String {
        let tool = try EngineLocator.requireSevenZip()
        let reporter = ProgressReporter(handler: progress)
        var arguments = ["t", archive.path, "-bsp1"] + Self.commonFlags
        arguments.append(passwordFlag(password))
        let result = try await ProcessRunner.run(executable: tool,
                                                 arguments: arguments,
                                                 cancellation: cancellation,
                                                 onOutput: { reporter.consume($0) })
        if cancellation?.isCancelled == true { throw ArchiveError.cancelled }
        if result.exitCode != 0 && result.exitCode != 1 {
            throw Self.classify(result: result, password: password)
        }
        return Self.summaryTail(of: result.standardOutput)
    }

    // MARK: - Writing

    /// Creates a new archive from files on disk. Items are grouped by parent folder so
    /// each 7zz run can store plain relative names, which keeps the archive root clean.
    public func create(archive: URL,
                       items: [URL],
                       options: CompressionOptions,
                       cancellation: CancellationToken? = nil,
                       progress: ProgressHandler? = nil) async throws {
        guard let format = options.format, format.canWrite else {
            throw ArchiveError.notWritable(options.formatKey)
        }
        if FileManager.default.fileExists(atPath: archive.path) {
            try FileManager.default.removeItem(at: archive)
        }
        try await add(items: items, to: archive, options: options,
                      cancellation: cancellation, progress: progress)
    }

    /// Adds files to a new or existing archive.
    public func add(items: [URL],
                    to archive: URL,
                    options: CompressionOptions,
                    cancellation: CancellationToken? = nil,
                    progress: ProgressHandler? = nil) async throws {
        guard !items.isEmpty else { return }
        let tool = try EngineLocator.requireSevenZip()
        let reporter = ProgressReporter(handler: progress)

        var groups: [URL: [String]] = [:]
        for item in items {
            groups[item.deletingLastPathComponent().standardizedFileURL, default: []]
                .append(item.lastPathComponent)
        }

        for (parent, names) in groups {
            let listFile = try writeListFile(names: names)
            defer { try? FileManager.default.removeItem(at: listFile) }

            var arguments = ["a", archive.path, "-bsp1", "-bb1"] + Self.commonFlags
            arguments.append("-t\(sevenZipType(for: options.formatKey))")
            if let format = options.format, format.supportsCompressionLevel {
                arguments.append("-mx=\(options.level)")
            }
            if options.formatKey == "7z" {
                arguments.append(options.solid ? "-ms=on" : "-ms=off")
            }
            if let password = options.password, !password.isEmpty {
                arguments.append(contentsOf: writePasswordFlags(password))
                if options.formatKey == "zip" { arguments.append("-mem=AES256") }
                if options.encryptFileNames, options.format?.supportsEncryptedHeaders == true {
                    arguments.append("-mhe=on")
                }
            }
            if let volumeSize = options.volumeSize, !volumeSize.isEmpty {
                arguments.append("-v\(volumeSize)")
            }
            if options.excludeMacMetadata {
                arguments.append(contentsOf: ["-xr!.DS_Store", "-xr!__MACOSX", "-xr!._*"])
            }
            arguments.append("@\(listFile.path)")

            let result = try await ProcessRunner.run(executable: tool,
                                                     arguments: arguments,
                                                     currentDirectory: parent,
                                                     cancellation: cancellation,
                                                     onOutput: { reporter.consume($0) })
            if cancellation?.isCancelled == true { throw ArchiveError.cancelled }
            if result.exitCode != 0 && result.exitCode != 1 {
                throw Self.classify(result: result, password: options.password)
            }
        }
        progress?(ArchiveProgress(fraction: 1, currentFile: nil))
    }

    public func delete(entries: [ArchiveEntry], from archive: URL, password: String?) async throws {
        guard !entries.isEmpty else { return }
        let tool = try EngineLocator.requireSevenZip()
        let listFile = try writeListFile(for: entries)
        defer { try? FileManager.default.removeItem(at: listFile) }

        var arguments = ["d", archive.path, "-spd", "@\(listFile.path)"] + Self.commonFlags
        arguments.append(contentsOf: writePasswordFlags(password))
        let result = try await ProcessRunner.run(executable: tool, arguments: arguments)
        if result.exitCode != 0 && result.exitCode != 1 {
            throw Self.classify(result: result, password: password)
        }
    }

    /// Writes an edited copy of one entry back, preserving its path inside the archive.
    public func update(fileAt localURL: URL,
                       entryPath: String,
                       in archive: URL,
                       options: CompressionOptions,
                       cancellation: CancellationToken? = nil,
                       progress: ProgressHandler? = nil) async throws {
        let tool = try EngineLocator.requireSevenZip()
        let staging = try EntryStaging(localURL: localURL, entryPath: entryPath)
        defer { staging.cleanup() }

        var arguments = ["a", archive.path, "-bsp1"] + Self.commonFlags
        arguments.append("-t\(sevenZipType(for: options.formatKey))")
        arguments.append(contentsOf: writePasswordFlags(options.password))
        arguments.append(staging.relativePath)

        let result = try await ProcessRunner.run(executable: tool,
                                                 arguments: arguments,
                                                 currentDirectory: staging.root,
                                                 cancellation: cancellation)
        if result.exitCode != 0 && result.exitCode != 1 {
            throw Self.classify(result: result, password: options.password)
        }
    }

    public func rename(entry: ArchiveEntry, to newPath: String, in archive: URL, password: String?) async throws {
        guard PathSafety.isSafe(entryPath: newPath) else { throw ArchiveError.unsafeEntry(newPath) }
        let tool = try EngineLocator.requireSevenZip()
        var arguments = ["rn", archive.path, entry.path, ArchivePath.normalize(newPath)] + Self.commonFlags
        arguments.append(contentsOf: writePasswordFlags(password))
        let result = try await ProcessRunner.run(executable: tool, arguments: arguments)
        if result.exitCode != 0 && result.exitCode != 1 {
            throw Self.classify(result: result, password: password)
        }
    }

    // MARK: - Helpers

    /// Read commands always get -p so 7zz fails fast instead of prompting on a terminal
    /// we do not have.
    private func passwordFlag(_ password: String?) -> String {
        "-p" + (password ?? "")
    }

    /// Write commands must omit -p entirely when there is no password: a bare -p means
    /// "ask me for a password to encrypt with", which blocks on stdin forever.
    private func writePasswordFlags(_ password: String?) -> [String] {
        guard let password, !password.isEmpty else { return [] }
        return ["-p" + password]
    }

    private func sevenZipType(for key: String) -> String {
        switch key {
        case "tgz", "tbz2", "txz", "tzst": return "tar"
        default: return key
        }
    }

    private func writeListFile(for entries: [ArchiveEntry]) throws -> URL {
        try writeListFile(names: entries.map(\.path))
    }

    private func writeListFile(names: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("justarc-\(UUID().uuidString).lst")
        let text = names.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    static func classify(result: ProcessResult, password: String?) -> ArchiveError {
        let text = result.combined
        let lowered = text.lowercased()
        if lowered.contains("wrong password")
            || lowered.contains("cannot open encrypted archive")
            || lowered.contains("can not open encrypted archive") {
            return (password?.isEmpty ?? true) ? .passwordRequired : .wrongPassword
        }
        if lowered.contains("data error") && (password?.isEmpty == false) {
            // 7-Zip reports a data error rather than a password error for some zip variants.
            return .wrongPassword
        }
        return .engineFailed(code: result.exitCode, message: Self.firstErrorLine(in: text))
    }

    private static func firstErrorLine(in text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let errorLine = lines.first(where: { $0.hasPrefix("ERROR") }) {
            return errorLine.replacingOccurrences(of: "ERROR: ", with: "")
        }
        return lines.suffix(3).joined(separator: " ")
    }

    private static func summaryTail(of text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.suffix(6).joined(separator: "\n")
    }
}

/// Turns the `-bsp1 -bb1` output stream into percentage and current-file updates.
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
