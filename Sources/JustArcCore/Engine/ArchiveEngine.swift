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

    public init(formatKey: String = "zip",
                level: Int = 5,
                password: String? = nil,
                encryptFileNames: Bool = false,
                solid: Bool = true,
                volumeSize: String? = nil,
                excludeMacMetadata: Bool = true) {
        self.formatKey = formatKey
        self.level = level
        self.password = password
        self.encryptFileNames = encryptFileNames
        self.solid = solid
        self.volumeSize = volumeSize
        self.excludeMacMetadata = excludeMacMetadata
    }

    public var format: ArchiveFormat? { FormatRegistry.format(forKey: formatKey) }
}

public typealias ProgressHandler = @Sendable (ArchiveProgress) -> Void

/// Every backend (7-Zip, disk images, external RAR) implements this.
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
}
