import Foundation

/// A disk image that is currently attached. Kept alive for as long as a window
/// has the image open, so browsing does not remount on every click.
struct MountedImage: Sendable {
    /// The whole-disk device, for example /dev/disk4. Detaching this releases the image.
    let devEntry: String
    /// One per mountable filesystem. Most images have exactly one.
    let mountPoints: [URL]
    /// The temporary directory the volumes were mounted under.
    let mountRoot: URL
}

/// Tracks attached images so they can be detached on window close and on quit.
final class DMGMountRegistry: @unchecked Sendable {
    static let shared = DMGMountRegistry()

    private let lock = NSLock()
    private var mounts: [String: MountedImage] = [:]

    private init() {}

    private func key(_ archive: URL) -> String { archive.standardizedFileURL.path }

    func existing(for archive: URL) -> MountedImage? {
        lock.lock(); defer { lock.unlock() }
        return mounts[key(archive)]
    }

    /// Stores a freshly attached image. If another attach for the same archive won the
    /// race, the loser is handed back so the caller can detach it again.
    func store(_ image: MountedImage, for archive: URL) -> MountedImage? {
        lock.lock()
        let identifier = key(archive)
        if let winner = mounts[identifier] {
            lock.unlock()
            return winner
        }
        mounts[identifier] = image
        lock.unlock()
        return nil
    }

    func forget(_ archive: URL) -> MountedImage? {
        lock.lock(); defer { lock.unlock() }
        return mounts.removeValue(forKey: key(archive))
    }

    func drainAll() -> [MountedImage] {
        lock.lock(); defer { lock.unlock() }
        let all = Array(mounts.values)
        mounts.removeAll()
        return all
    }

    func unmountAll() {
        for image in drainAll() {
            DMGEngine.detachSynchronously(image)
        }
    }
}

/// Reads and writes Apple disk images through the system `hdiutil` tool.
///
/// Reading works by attaching the image read-only at a private mount point and
/// treating the mounted filesystem as the archive contents, which is the only way
/// to see inside HFS+ and APFS images correctly.
public struct DMGEngine: ArchiveEngine {
    public init() {}

    /// Volume housekeeping that macOS creates on every mount and that nobody wants
    /// to see listed as archive contents.
    private static let volumeSystemItems: Set<String> = [
        ".Trashes", ".fseventsd", ".Spotlight-V100", ".TemporaryItems",
        ".DocumentRevisions-V100", ".vol", ".apdisk", ".PKInstallSandboxManager",
        ".PKInstallSandboxManager-SystemSoftware", ".file",
    ]

    // MARK: - Listing

    public func list(archive: URL, password: String?, encodingCodePage: Int?) async throws -> ArchiveListing {
        let image = try await attach(archive: archive, password: password)

        var entries: [ArchiveEntry] = []
        let usePrefix = image.mountPoints.count > 1
        for mountPoint in image.mountPoints {
            let prefix = usePrefix ? volumeName(of: mountPoint) : ""
            if usePrefix {
                entries.append(ArchiveEntry(path: prefix, isDirectory: true,
                                            modified: modificationDate(of: mountPoint)))
            }
            entries.append(contentsOf: Self.entries(under: mountPoint, prefix: prefix))
        }

        var info = ArchiveInfo()
        info.formatName = (try? await formatDescription(archive: archive, password: password))
            ?? L("Disk Image")
        info.physicalSize = fileSize(of: archive)
        info.hasEncryptedHeader = (try? await Self.isEncrypted(archive: archive)) ?? false
        return ArchiveListing(info: info, entries: entries)
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
        if let entries, let unsafePath = PathSafety.firstUnsafePath(in: entries) {
            throw ArchiveError.unsafeEntry(unsafePath)
        }

        let image = try await attach(archive: archive, password: password)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        // Work out the concrete source/destination pairs to copy.
        var jobs: [(source: URL, relativePath: String)] = []
        if let entries {
            for entry in entries where !entry.isDirectory || entryHasNoChildren(entry, in: entries) {
                guard let source = resolve(path: entry.path, in: image) else { continue }
                jobs.append((source, entry.path))
            }
        } else {
            let usePrefix = image.mountPoints.count > 1
            for mountPoint in image.mountPoints {
                let prefix = usePrefix ? volumeName(of: mountPoint) : ""
                for child in topLevelChildren(of: mountPoint) {
                    jobs.append((child, ArchivePath.join(prefix, child.lastPathComponent)))
                }
            }
        }

        Diagnostics.log("extract \(archive.lastPathComponent): \(jobs.count) job(s) from \(image.mountPoints.count) mount(s) -> \(destination.path)")
        guard !jobs.isEmpty else {
            throw ArchiveError.ioFailure(
                L("Nothing in %@ could be read. The image mounted but appeared empty.", archive.lastPathComponent))
        }

        let totalBytes = jobs.reduce(UInt64(0)) { $0 + Self.recursiveSize(of: $1.source) }
        let counter = ByteCounter(total: totalBytes, progress: progress)

        for job in jobs {
            if cancellation?.isCancelled == true { throw ArchiveError.cancelled }
            let relative = flattenPaths ? (job.relativePath as NSString).lastPathComponent : job.relativePath
            let target = try PathSafety.resolvedURL(for: relative, in: destination)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try copy(from: job.source, to: target, overwrite: overwrite,
                     counter: counter, cancellation: cancellation)
        }
        progress?(ArchiveProgress(fraction: 1, currentFile: nil))
    }

    /// True when no other selected entry lives inside this folder, meaning the folder
    /// itself should be copied whole.
    private func entryHasNoChildren(_ entry: ArchiveEntry, in entries: [ArchiveEntry]) -> Bool {
        let prefix = entry.path + "/"
        return !entries.contains { $0.path.hasPrefix(prefix) }
    }

    private func resolve(path: String, in image: MountedImage) -> URL? {
        let normalized = ArchivePath.normalize(path)
        if image.mountPoints.count > 1 {
            var components = normalized.split(separator: "/").map(String.init)
            guard !components.isEmpty else { return nil }
            let volume = components.removeFirst()
            guard let mountPoint = image.mountPoints.first(where: { volumeName(of: $0) == volume }) else {
                return nil
            }
            let candidate = components.isEmpty
                ? mountPoint
                : mountPoint.appendingPathComponent(components.joined(separator: "/"))
            return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        }
        guard let mountPoint = image.mountPoints.first else { return nil }
        let candidate = mountPoint.appendingPathComponent(normalized)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Recursive copy that reports progress per file and honours the overwrite mode.
    ///
    /// A folder merges into a folder of the same name that is already there; the
    /// overwrite mode is a rule for files, applied to each file inside. Nothing that
    /// exists is ever removed to make room for a folder, and a folder is never removed
    /// to make room for a file.
    ///
    /// Files and symlinks go through copyItem, which preserves permissions, extended
    /// attributes and resource forks; directories are recreated and given the source's
    /// metadata afterwards.
    private func copy(from source: URL,
                      to proposedTarget: URL,
                      overwrite: OverwriteMode,
                      counter: ByteCounter,
                      cancellation: CancellationToken?) throws {
        if cancellation?.isCancelled == true { throw ArchiveError.cancelled }
        let fm = FileManager.default

        let values = try? source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey])
        let isSymlink = values?.isSymbolicLink ?? false
        let isDirectory = !isSymlink && (values?.isDirectory ?? false)

        if isDirectory {
            var target = proposedTarget
            if PathSafety.itemExists(at: target), !Self.isRealDirectory(target) {
                // A file where the folder should go. It stays; the folder goes beside it.
                if overwrite == .skip {
                    counter.skip(Self.recursiveSize(of: source))
                    return
                }
                target = PathSafety.uniqueURL(for: target)
            }
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for child in topLevelChildren(of: source) {
                try copy(from: child,
                         to: target.appendingPathComponent(child.lastPathComponent),
                         overwrite: overwrite,
                         counter: counter,
                         cancellation: cancellation)
            }
            Self.copyMetadata(from: source, to: target)
            return
        }

        var target = proposedTarget
        if PathSafety.itemExists(at: target) {
            switch overwrite {
            case .skip:
                counter.skip(UInt64(values?.fileSize ?? 0))
                return
            case .renameNew:
                target = PathSafety.uniqueURL(for: target)
            case .renameExisting, .overwrite:
                if Self.isRealDirectory(target) {
                    throw ArchiveError.ioFailure(
                        L("%@ was not extracted: a folder with the same name is in the way.",
                          target.lastPathComponent))
                }
            }
        }

        // Copied under a temporary name first, so what is already there is only
        // replaced by a complete file.
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".justarc-\(UUID().uuidString).part")
        do {
            try fm.copyItem(at: source, to: temporary)
            if overwrite == .renameExisting, PathSafety.itemExists(at: target) {
                try fm.moveItem(at: target, to: PathSafety.uniqueURL(for: target))
            }
            guard Darwin.rename(temporary.path, target.path) == 0 else {
                throw ArchiveError.ioFailure(String(cString: strerror(errno)))
            }
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
        counter.advance(UInt64(values?.fileSize ?? 0), file: source.lastPathComponent)
    }

    /// A directory that is not a symbolic link to one.
    private static func isRealDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    // MARK: - Verifying

    public func test(archive: URL,
                     password: String?,
                     cancellation: CancellationToken? = nil,
                     progress: ProgressHandler? = nil) async throws -> String {
        var arguments = ["verify", archive.path, "-puppetstrings"]
        if try await Self.isEncrypted(archive: archive) {
            guard let password, !password.isEmpty else { throw ArchiveError.passwordRequired }
            arguments.append("-stdinpass")
        }

        let reporter = PuppetStringsReporter(handler: progress)
        let result = try await ProcessRunner.run(executable: EngineLocator.hdiutil,
                                                 arguments: arguments,
                                                 stdin: stdinPayload(password: password),
                                                 cancellation: cancellation,
                                                 onOutput: { reporter.consume($0) })
        if cancellation?.isCancelled == true { throw ArchiveError.cancelled }
        guard result.exitCode == 0 else { throw Self.classify(result: result, password: password) }
        return Self.readableTail(of: result.combined, fallback: L("The disk image verified successfully."))
    }

    // MARK: - Creating

    public func create(archive: URL,
                       items: [URL],
                       options: CompressionOptions,
                       cancellation: CancellationToken? = nil,
                       progress: ProgressHandler? = nil) async throws {
        guard !items.isEmpty else {
            throw ArchiveError.ioFailure(L("There is nothing to put in the disk image."))
        }

        let staging = try stage(items: items)
        defer { staging.cleanup() }

        let volumeName = Self.volumeName(for: archive)
        var arguments = ["create", archive.path,
                         "-srcfolder", staging.folder.path,
                         "-volname", volumeName,
                         "-fs", "HFS+",
                         "-ov", "-puppetstrings"]
        arguments.append(contentsOf: Self.imageFormatArguments(level: options.level))

        if let password = options.password, !password.isEmpty {
            arguments.append(contentsOf: ["-encryption", "AES-256", "-stdinpass"])
        }

        let reporter = PuppetStringsReporter(handler: progress)
        let result = try await ProcessRunner.run(executable: EngineLocator.hdiutil,
                                                 arguments: arguments,
                                                 stdin: stdinPayload(password: options.password),
                                                 cancellation: cancellation,
                                                 onOutput: { reporter.consume($0) })
        if cancellation?.isCancelled == true {
            try? FileManager.default.removeItem(at: archive)
            throw ArchiveError.cancelled
        }
        guard result.exitCode == 0 else {
            throw Self.classify(result: result, password: options.password)
        }
        progress?(ArchiveProgress(fraction: 1, currentFile: nil))
    }

    /// hdiutil takes a single source folder and puts its contents at the top of the
    /// image, so the items are gathered into one, each under its own name. A single
    /// folder is gathered too, or it would be dissolved into the image's root and no
    /// longer be what the window showed. Hard links keep this cheap on one volume.
    private func stage(items: [URL]) throws -> StagingFolder {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("justarc-dmg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for item in items {
            let target = folder.appendingPathComponent(item.lastPathComponent)
            do {
                try FileManager.default.linkItem(at: item, to: target)
            } catch {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: item, to: target)
            }
        }
        return StagingFolder(folder: folder, ownsFolder: true)
    }

    private struct StagingFolder {
        let folder: URL
        let ownsFolder: Bool
        func cleanup() {
            guard ownsFolder else { return }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Maps our 0-9 compression scale onto hdiutil's image formats.
    static func imageFormatArguments(level: Int) -> [String] {
        switch level {
        case ..<1:
            return ["-format", "UDRO"]                                   // read-only, uncompressed
        case 1...6:
            return ["-format", "UDZO", "-imagekey", "zlib-level=\(level)"] // zlib
        default:
            return ["-format", "ULFO"]                                   // LZFSE, best ratio and fast
        }
    }

    static func volumeName(for archive: URL) -> String {
        let raw = FormatRegistry.baseName(for: archive)
        let cleaned = raw.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        let name = cleaned.isEmpty ? L("Disk Image") : cleaned
        // HFS+ volume names are limited to 27 characters.
        return String(name.prefix(27))
    }

    // MARK: - Attaching and detaching

    public func release(archive: URL) {
        guard let image = DMGMountRegistry.shared.forget(archive) else { return }
        Self.detachSynchronously(image)
    }

    private func attach(archive: URL, password: String?) async throws -> MountedImage {
        if let existing = DMGMountRegistry.shared.existing(for: archive),
           existing.mountPoints.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
            return existing
        }
        if let stale = DMGMountRegistry.shared.forget(archive) {
            // Its mount points are gone, but the device may still be attached.
            Self.detachSynchronously(stale)
        }

        let encrypted = try await Self.isEncrypted(archive: archive)
        if encrypted, password == nil || password!.isEmpty {
            throw ArchiveError.passwordRequired
        }

        let mountRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("justarc-mount-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true)

        var arguments = ["attach", archive.path, "-plist", "-nobrowse", "-readonly",
                         "-noverify", "-noautoopen", "-mountroot", mountRoot.path]
        if encrypted { arguments.append("-stdinpass") }

        // Sending "Y" answers the licence prompt on images that carry one; hdiutil
        // ignores it otherwise. An encrypted image gets the password instead.
        let result = try await ProcessRunner.run(executable: EngineLocator.hdiutil,
                                                 arguments: arguments,
                                                 stdin: stdinPayload(password: encrypted ? password : nil))

        guard result.exitCode == 0 else {
            Diagnostics.log("attach failed for \(archive.lastPathComponent): exit \(result.exitCode) — \(result.standardError)")
            try? FileManager.default.removeItem(at: mountRoot)
            throw Self.classify(result: result, password: password)
        }

        let (devEntry, mountPoints) = Self.parseAttachOutput(result.standardOutput)
        Diagnostics.log("attached \(archive.lastPathComponent): dev=\(devEntry ?? "nil") mounts=\(mountPoints.map(\.path))")
        guard let devEntry, !mountPoints.isEmpty else {
            // Attached but with nothing mounted: it must still be given back, or the
            // device stays attached and, being hidden from the Finder, unnoticed.
            if let devEntry {
                Self.detachSynchronously(MountedImage(devEntry: devEntry, mountPoints: [], mountRoot: mountRoot))
            }
            try? FileManager.default.removeItem(at: mountRoot)
            throw ArchiveError.engineFailed(
                code: 0,
                message: L("%@ has no mountable file systems.", archive.lastPathComponent))
        }

        let image = MountedImage(devEntry: devEntry, mountPoints: mountPoints, mountRoot: mountRoot)
        if let winner = DMGMountRegistry.shared.store(image, for: archive) {
            // Another attach got there first; give ours back.
            Self.detachSynchronously(image)
            return winner
        }
        return image
    }

    /// Reads hdiutil's attach plist and returns the whole-disk device plus every mount point.
    static func parseAttachOutput(_ text: String) -> (devEntry: String?, mountPoints: [URL]) {
        guard let data = text.data(using: .utf8),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = root as? [String: Any],
              let systemEntities = dictionary["system-entities"] as? [[String: Any]] else {
            return (nil, [])
        }

        var devEntries: [String] = []
        var mountPoints: [URL] = []
        for entity in systemEntities {
            if let dev = entity["dev-entry"] as? String { devEntries.append(dev) }
            if let mount = entity["mount-point"] as? String, !mount.isEmpty {
                mountPoints.append(URL(fileURLWithPath: mount))
            }
        }
        // The shortest device path is the whole disk, for example /dev/disk4 next to /dev/disk4s1.
        let whole = devEntries.min { $0.count < $1.count }
        return (whole, mountPoints)
    }

    static func detachSynchronously(_ image: MountedImage) {
        func run(_ arguments: [String]) -> Int32 {
            let process = Process()
            process.executableURL = EngineLocator.hdiutil
            process.arguments = arguments
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return -1 }
            process.waitUntilExit()
            return process.terminationStatus
        }

        if run(["detach", image.devEntry]) != 0 {
            _ = run(["detach", image.devEntry, "-force"])
        }
        try? FileManager.default.removeItem(at: image.mountRoot)
    }

    // MARK: - Image metadata

    static func isEncrypted(archive: URL) async throws -> Bool {
        let result = try await ProcessRunner.run(executable: EngineLocator.hdiutil,
                                                 arguments: ["isencrypted", archive.path, "-plist"])
        guard result.exitCode == 0 else { return false }
        if let data = result.standardOutput.data(using: .utf8),
           let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let dictionary = root as? [String: Any],
           let encrypted = dictionary["encrypted"] as? Bool {
            return encrypted
        }
        return result.standardOutput.lowercased().contains("encrypted: yes")
    }

    private func formatDescription(archive: URL, password: String?) async throws -> String {
        var arguments = ["imageinfo", archive.path, "-plist"]
        if try await Self.isEncrypted(archive: archive) { arguments.append("-stdinpass") }
        let result = try await ProcessRunner.run(executable: EngineLocator.hdiutil,
                                                 arguments: arguments,
                                                 stdin: stdinPayload(password: password))
        guard result.exitCode == 0,
              let data = result.standardOutput.data(using: .utf8),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = root as? [String: Any] else {
            return L("Disk Image")
        }
        if let description = dictionary["Format Description"] as? String, !description.isEmpty {
            return description
        }
        if let format = dictionary["Format"] as? String, !format.isEmpty {
            return L("Disk Image (%@)", format)
        }
        return L("Disk Image")
    }

    /// hdiutil reads either a password or a licence answer from stdin, never both.
    private func stdinPayload(password: String?) -> String {
        if let password, !password.isEmpty { return password }
        return "Y\n"
    }

    // MARK: - Filesystem walking

    static func entries(under mountPoint: URL, prefix: String) -> [ArchiveEntry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey,
                                      .fileSizeKey, .contentModificationDateKey]
        guard let walker = fm.enumerator(at: mountPoint,
                                         includingPropertiesForKeys: keys,
                                         options: [.skipsPackageDescendants]) else { return [] }

        let rootPath = mountPoint.standardizedFileURL.path
        let prefixLength = rootPath.hasSuffix("/") ? rootPath.count : rootPath.count + 1

        var results: [ArchiveEntry] = []
        for case let url as URL in walker {
            let fullPath = url.standardizedFileURL.path
            guard fullPath.count > prefixLength else { continue }
            let relative = String(fullPath.dropFirst(prefixLength))

            // Volume housekeeping lives at the root and is never archive content.
            if let firstComponent = relative.split(separator: "/").first,
               volumeSystemItems.contains(String(firstComponent)) {
                walker.skipDescendants()
                continue
            }

            let values = try? url.resourceValues(forKeys: Set(keys))
            let isSymlink = values?.isSymbolicLink ?? false
            let isDirectory = !isSymlink && (values?.isDirectory ?? false)

            results.append(ArchiveEntry(path: ArchivePath.join(prefix, relative),
                                        isDirectory: isDirectory,
                                        size: UInt64(values?.fileSize ?? 0),
                                        packedSize: 0,
                                        modified: values?.contentModificationDate,
                                        attributes: isSymlink ? "L" : nil))
        }
        return results
    }

    private func topLevelChildren(of directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [])) ?? []
        return contents.filter { !Self.volumeSystemItems.contains($0.lastPathComponent) }
    }

    private func volumeName(of mountPoint: URL) -> String {
        let values = try? mountPoint.resourceValues(forKeys: [.volumeNameKey])
        let name = values?.volumeName ?? mountPoint.lastPathComponent
        return name.replacingOccurrences(of: "/", with: "-")
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func fileSize(of url: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    static func recursiveSize(of url: URL) -> UInt64 {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        if values?.isSymbolicLink == true { return 0 }
        if values?.isDirectory != true { return UInt64(values?.fileSize ?? 0) }

        var total: UInt64 = 0
        guard let walker = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: []) else { return 0 }
        for case let child as URL in walker {
            let childValues = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if childValues?.isRegularFile == true {
                total += UInt64(childValues?.fileSize ?? 0)
            }
        }
        return total
    }

    /// Brings a directory's permissions, ACLs and extended attributes across.
    static func copyMetadata(from source: URL, to target: URL) {
        source.withUnsafeFileSystemRepresentation { sourcePath in
            target.withUnsafeFileSystemRepresentation { targetPath in
                guard let sourcePath, let targetPath else { return }
                let flags = copyfile_flags_t(COPYFILE_METADATA)
                _ = copyfile(sourcePath, targetPath, nil, flags)
            }
        }
    }

    // MARK: - Errors

    static func classify(result: ProcessResult, password: String?) -> ArchiveError {
        let text = result.combined
        let lowered = text.lowercased()
        if lowered.contains("authentication error")
            || lowered.contains("decryption")
            || lowered.contains("corrupt image") && (password?.isEmpty == false) {
            return (password?.isEmpty ?? true) ? .passwordRequired : .wrongPassword
        }
        if lowered.contains("no mountable file systems") {
            return .engineFailed(code: result.exitCode, message: L("The disk image has no mountable file systems."))
        }
        if lowered.contains("resource busy") || lowered.contains("resource temporarily unavailable") {
            return .engineFailed(code: result.exitCode,
                                 message: L("The disk image is in use by another program."))
        }
        return .engineFailed(code: result.exitCode,
                             message: readableTail(of: text, fallback: L("hdiutil failed.")))
    }

    static func readableTail(of text: String, fallback: String) -> String {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("PERCENT:") && !$0.hasPrefix("STATUS:")
                      && !$0.hasPrefix("MESSAGE:") && !$0.hasPrefix("PHASE:") }
        guard !lines.isEmpty else { return fallback }
        return lines.suffix(4).joined(separator: "\n")
    }
}

/// Converts copied bytes into progress updates.
final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let total: UInt64
    private var done: UInt64 = 0
    private let progress: ProgressHandler?

    init(total: UInt64, progress: ProgressHandler?) {
        self.total = total
        self.progress = progress
    }

    func advance(_ bytes: UInt64, file: String?) {
        guard let progress else { return }
        lock.lock()
        done += bytes
        let fraction = total > 0 ? min(Double(done) / Double(total), 1) : nil
        lock.unlock()
        progress(ArchiveProgress(fraction: fraction, currentFile: file))
    }

    func skip(_ bytes: UInt64) {
        advance(bytes, file: nil)
    }
}

/// Parses hdiutil's `-puppetstrings` output, which emits `PERCENT:12.5` lines.
final class PuppetStringsReporter: @unchecked Sendable {
    private let handler: ProgressHandler?
    private let lock = NSLock()
    private var lastMessage: String?

    init(handler: ProgressHandler?) {
        self.handler = handler
    }

    func consume(_ chunk: String) {
        guard let handler else { return }
        for rawLine in chunk.components(separatedBy: CharacterSet(charactersIn: "\r\n")) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("PERCENT:") {
                let value = Double(line.dropFirst("PERCENT:".count)) ?? -1
                // hdiutil emits -1 while a phase has no measurable progress.
                guard value >= 0 else { continue }
                lock.lock(); let message = lastMessage; lock.unlock()
                handler(ArchiveProgress(fraction: min(value / 100, 1), currentFile: message))
            } else if line.hasPrefix("MESSAGE:") || line.hasPrefix("PHASE:") {
                let message = String(line.drop(while: { $0 != ":" }).dropFirst())
                lock.lock(); lastMessage = message.isEmpty ? nil : message; lock.unlock()
            }
        }
    }
}
