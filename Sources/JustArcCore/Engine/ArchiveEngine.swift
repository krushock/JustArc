import Foundation

public struct ArchiveProgress: Sendable {
    /// 0...1, or nil while the engine has not reported a percentage yet.
    public var fraction: Double?
    public var currentFile: String?

    public init(fraction: Double?, currentFile: String?) {
        self.fraction = fraction
        self.currentFile = currentFile
    }
}

public enum OverwriteMode: String, Sendable, CaseIterable {
    case overwrite      // -aoa
    case skip           // -aos
    case renameNew      // -aou
    case renameExisting // -aot

    var sevenZipFlag: String {
        switch self {
        case .overwrite: return "-aoa"
        case .skip: return "-aos"
        case .renameNew: return "-aou"
        case .renameExisting: return "-aot"
        }
    }
}

public struct CompressionOptions: Sendable {
    public var formatKey: String
    /// 0 store, 1 fastest, 5 normal, 9 ultra.
    public var level: Int
    public var password: String?
    public var encryptFileNames: Bool
    public var solid: Bool
    /// 7-Zip volume spec such as "100m" or "4480m".
    public var volumeSize: String?
    public var excludeMacMetadata: Bool
    /// How zip archives are encrypted. AES-256 is strong; ZipCrypto opens in more
    /// tools, including Info-ZIP `unzip`, but is weak.
    public var zipEncryption: ZipEncryption

    public enum ZipEncryption: String, Sendable, CaseIterable {
        case aes256 = "AES256"
        case aes192 = "AES192"
        case aes128 = "AES128"
        case zipCrypto = "ZipCrypto"
    }

    public init(formatKey: String = "zip",
                level: Int = 5,
                password: String? = nil,
                encryptFileNames: Bool = false,
                solid: Bool = true,
                volumeSize: String? = nil,
                excludeMacMetadata: Bool = true,
                zipEncryption: ZipEncryption = .aes256) {
        self.formatKey = formatKey
        self.level = level
        self.password = password
        self.encryptFileNames = encryptFileNames
        self.solid = solid
        self.volumeSize = volumeSize
        self.excludeMacMetadata = excludeMacMetadata
        self.zipEncryption = zipEncryption
    }

    public var format: ArchiveFormat? { FormatRegistry.format(forKey: formatKey) }
}

public typealias ProgressHandler = @Sendable (ArchiveProgress) -> Void

/// Every backend (7-Zip, disk images, external RAR) implements this.
///
/// Reading is required. The writing operations have default implementations that
/// refuse, so a read-only backend only implements what it can actually do.
public protocol ArchiveEngine: Sendable {
    func list(archive: URL, password: String?, encodingCodePage: Int?) async throws -> ArchiveListing

    func extract(archive: URL,
                 entries: [ArchiveEntry]?,
                 to destination: URL,
                 password: String?,
                 overwrite: OverwriteMode,
                 flattenPaths: Bool,
                 cancellation: CancellationToken?,
                 progress: ProgressHandler?) async throws

    func test(archive: URL,
              password: String?,
              cancellation: CancellationToken?,
              progress: ProgressHandler?) async throws -> String

    func extractSingle(archive: URL,
                       entry: ArchiveEntry,
                       to scratch: URL,
                       password: String?,
                       cancellation: CancellationToken?) async throws -> URL

    func create(archive: URL,
                items: [URL],
                options: CompressionOptions,
                cancellation: CancellationToken?,
                progress: ProgressHandler?) async throws

    /// Adds files and folders to an archive, each under its own name inside `folder`.
    /// - Parameter folder: a path inside the archive, or "" for its root.
    func add(items: [URL],
             to archive: URL,
             into folder: String,
             options: CompressionOptions,
             cancellation: CancellationToken?,
             progress: ProgressHandler?) async throws

    func delete(entries: [ArchiveEntry], from archive: URL, password: String?) async throws

    func rename(entry: ArchiveEntry, to newPath: String, in archive: URL, password: String?) async throws

    /// Writes an edited copy of one entry back into the archive, keeping its path.
    func update(fileAt localURL: URL,
                entryPath: String,
                in archive: URL,
                options: CompressionOptions,
                cancellation: CancellationToken?,
                progress: ProgressHandler?) async throws

    /// Frees anything the engine is holding for this archive, such as a mounted
    /// disk image. Safe to call on an archive the engine never opened.
    func release(archive: URL)
}

public extension ArchiveEngine {
    /// Pulls one entry into a scratch folder, which is how the browser opens or previews a file.
    func extractSingle(archive: URL,
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
        // Some backends normalise separators or drop leading folders.
        let leaf = scratch.appendingPathComponent(entry.name)
        if FileManager.default.fileExists(atPath: leaf.path) { return leaf }
        throw ArchiveError.ioFailure(L("%@ was not found after extraction.", entry.name))
    }

    func create(archive: URL, items: [URL], options: CompressionOptions,
                cancellation: CancellationToken? = nil, progress: ProgressHandler? = nil) async throws {
        throw ArchiveError.notWritable(options.format?.displayName ?? options.formatKey)
    }

    func add(items: [URL], to archive: URL, into folder: String, options: CompressionOptions,
             cancellation: CancellationToken?, progress: ProgressHandler?) async throws {
        throw ArchiveError.notWritable(FormatRegistry.format(for: archive)?.displayName ?? "this format")
    }

    /// Adds at the root of the archive.
    func add(items: [URL], to archive: URL, options: CompressionOptions,
             cancellation: CancellationToken? = nil, progress: ProgressHandler? = nil) async throws {
        try await add(items: items, to: archive, into: "", options: options,
                      cancellation: cancellation, progress: progress)
    }

    func delete(entries: [ArchiveEntry], from archive: URL, password: String?) async throws {
        throw ArchiveError.notWritable(FormatRegistry.format(for: archive)?.displayName ?? "this format")
    }

    func rename(entry: ArchiveEntry, to newPath: String, in archive: URL, password: String?) async throws {
        throw ArchiveError.notWritable(FormatRegistry.format(for: archive)?.displayName ?? "this format")
    }

    func update(fileAt localURL: URL, entryPath: String, in archive: URL,
                options: CompressionOptions, cancellation: CancellationToken? = nil,
                progress: ProgressHandler? = nil) async throws {
        throw ArchiveError.notWritable(FormatRegistry.format(for: archive)?.displayName ?? "this format")
    }

    func release(archive: URL) {}
}

/// Picks the backend for a format. Everything that is not a disk image goes to 7-Zip.
public enum EngineFactory {
    public static func engine(for archive: URL) -> ArchiveEngine {
        engine(for: FormatRegistry.format(for: archive))
    }

    public static func engine(for format: ArchiveFormat?) -> ArchiveEngine {
        switch format?.engine {
        case .diskImage:
            return DMGEngine()
        case .externalRAR:
            return RarEngine()
        case .sevenZip, .none:
            return SevenZipEngine()
        }
    }

    public static func engine(forKey key: String) -> ArchiveEngine {
        engine(for: FormatRegistry.format(forKey: key))
    }

    /// Releases every resource any engine is holding, for app termination.
    public static func releaseAll() {
        DMGMountRegistry.shared.unmountAll()
        NestedTarCache.shared.forgetAll()
    }
}
