import Foundation

/// One item inside an archive. Paths use "/" separators and never start with "/".
public struct ArchiveEntry: Sendable, Hashable, Identifiable {
    public var id: String { path }

    public let path: String
    public let isDirectory: Bool
    public let size: UInt64
    public let packedSize: UInt64
    public let modified: Date?
    public let crc: String?
    public let attributes: String?
    public let isEncrypted: Bool
    public let method: String?

    public init(path: String,
                isDirectory: Bool,
                size: UInt64 = 0,
                packedSize: UInt64 = 0,
                modified: Date? = nil,
                crc: String? = nil,
                attributes: String? = nil,
                isEncrypted: Bool = false,
                method: String? = nil) {
        self.path = ArchivePath.normalize(path)
        self.isDirectory = isDirectory
        self.size = size
        self.packedSize = packedSize
        self.modified = modified
        self.crc = crc
        self.attributes = attributes
        self.isEncrypted = isEncrypted
        self.method = method
    }

    public var name: String {
        String(path.split(separator: "/").last ?? "")
    }

    /// Parent directory path, "" for items at the archive root.
    public var parentPath: String {
        var parts = path.split(separator: "/")
        guard parts.count > 1 else { return "" }
        parts.removeLast()
        return parts.joined(separator: "/")
    }

    public var ratio: Double? {
        guard !isDirectory, size > 0 else { return nil }
        return Double(packedSize) / Double(size)
    }
}

public enum ArchivePath {
    /// Collapses separators and strips leading "./" and "/" so paths are archive-relative.
    public static func normalize(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\\", with: "/")
        while s.hasPrefix("./") { s.removeFirst(2) }
        while s.hasPrefix("/") { s.removeFirst() }
        while s.hasSuffix("/") { s.removeLast() }
        while s.contains("//") { s = s.replacingOccurrences(of: "//", with: "/") }
        return s
    }

    public static func join(_ parent: String, _ child: String) -> String {
        parent.isEmpty ? child : parent + "/" + child
    }
}

/// Archive-level properties reported by the engine.
public struct ArchiveInfo: Sendable, Hashable {
    public var formatName: String
    public var physicalSize: UInt64
    public var isSolid: Bool
    public var hasEncryptedHeader: Bool
    public var comment: String?
    public var volumeCount: Int?

    public init(formatName: String = "",
                physicalSize: UInt64 = 0,
                isSolid: Bool = false,
                hasEncryptedHeader: Bool = false,
                comment: String? = nil,
                volumeCount: Int? = nil) {
        self.formatName = formatName
        self.physicalSize = physicalSize
        self.isSolid = isSolid
        self.hasEncryptedHeader = hasEncryptedHeader
        self.comment = comment
        self.volumeCount = volumeCount
    }
}

public struct ArchiveListing: Sendable {
    public var info: ArchiveInfo
    public var entries: [ArchiveEntry]

    public init(info: ArchiveInfo, entries: [ArchiveEntry]) {
        self.info = info
        self.entries = entries
    }

    public var containsEncryptedEntries: Bool {
        info.hasEncryptedHeader || entries.contains { $0.isEncrypted }
    }

    public var totalSize: UInt64 { entries.reduce(0) { $0 + $1.size } }
    public var totalPacked: UInt64 { entries.reduce(0) { $0 + $1.packedSize } }
    public var fileCount: Int { entries.filter { !$0.isDirectory }.count }
    public var folderCount: Int { entries.filter(\.isDirectory).count }
}
