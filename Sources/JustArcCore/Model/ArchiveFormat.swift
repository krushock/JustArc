import Foundation
import UniformTypeIdentifiers

/// Capability matrix for every format JustArc knows about.
public struct ArchiveFormat: Sendable, Hashable, Identifiable {
    public var id: String { key }

    /// Stable identifier, stored in preferences and mapped onto 7-Zip's handlers.
    public let key: String
    public let displayName: String
    /// Lowercase, no leading dot. First one is the default when saving.
    public let extensions: [String]
    public let canRead: Bool
    public let canWrite: Bool
    public let canEditInPlace: Bool
    public let supportsPassword: Bool
    public let supportsEncryptedHeaders: Bool
    public let supportsSplitVolumes: Bool
    public let supportsCompressionLevel: Bool
    public let engine: EngineKind

    public enum EngineKind: String, Sendable, Hashable {
        case sevenZip
        case diskImage
        case externalRAR
    }

    public init(key: String, displayName: String, extensions: [String],
                canRead: Bool = true, canWrite: Bool = false, canEditInPlace: Bool = false,
                supportsPassword: Bool = false, supportsEncryptedHeaders: Bool = false,
                supportsSplitVolumes: Bool = false, supportsCompressionLevel: Bool = true,
                engine: EngineKind = .sevenZip) {
        self.key = key
        self.displayName = displayName
        self.extensions = extensions
        self.canRead = canRead
        self.canWrite = canWrite
        self.canEditInPlace = canEditInPlace
        self.supportsPassword = supportsPassword
        self.supportsEncryptedHeaders = supportsEncryptedHeaders
        self.supportsSplitVolumes = supportsSplitVolumes
        self.supportsCompressionLevel = supportsCompressionLevel
        self.engine = engine
    }
}

public enum FormatRegistry {
    public static let all: [ArchiveFormat] = [
        ArchiveFormat(key: "zip", displayName: "ZIP", extensions: ["zip", "jar", "ipa", "apk", "epub", "xpi", "war", "whl", "cbz"],
                      canWrite: true, canEditInPlace: true, supportsPassword: true,
                      supportsSplitVolumes: true),
        ArchiveFormat(key: "7z", displayName: "7-Zip", extensions: ["7z"],
                      canWrite: true, canEditInPlace: true, supportsPassword: true,
                      supportsEncryptedHeaders: true, supportsSplitVolumes: true),
        ArchiveFormat(key: "rar", displayName: "RAR", extensions: ["rar", "cbr"],
                      canWrite: true, canEditInPlace: true, supportsPassword: true,
                      supportsEncryptedHeaders: true, supportsSplitVolumes: true,
                      engine: .externalRAR),
        ArchiveFormat(key: "tar", displayName: "TAR", extensions: ["tar", "cbt"],
                      canWrite: true, canEditInPlace: true, supportsCompressionLevel: false),
        ArchiveFormat(key: "tgz", displayName: L("TAR + GZip"), extensions: ["tar.gz", "tgz"],
                      canWrite: true, canEditInPlace: true),
        ArchiveFormat(key: "tbz2", displayName: L("TAR + BZip2"), extensions: ["tar.bz2", "tbz2", "tbz"],
                      canWrite: true, canEditInPlace: true),
        ArchiveFormat(key: "txz", displayName: L("TAR + XZ"), extensions: ["tar.xz", "txz"],
                      canWrite: true, canEditInPlace: true),
        ArchiveFormat(key: "tzst", displayName: L("TAR + Zstandard"), extensions: ["tar.zst", "tzst"]),
        ArchiveFormat(key: "gzip", displayName: "GZip", extensions: ["gz"], canWrite: true),
        ArchiveFormat(key: "bzip2", displayName: "BZip2", extensions: ["bz2"], canWrite: true),
        ArchiveFormat(key: "xz", displayName: "XZ", extensions: ["xz", "lzma"], canWrite: true),
        ArchiveFormat(key: "zstd", displayName: "Zstandard", extensions: ["zst"]),
        ArchiveFormat(key: "dmg", displayName: L("Disk Image"), extensions: ["dmg"],
                      canWrite: true, supportsPassword: true, engine: .diskImage),
        ArchiveFormat(key: "iso", displayName: L("ISO Image"), extensions: ["iso"], supportsCompressionLevel: false),
        ArchiveFormat(key: "cab", displayName: L("Cabinet"), extensions: ["cab"], supportsCompressionLevel: false),
        ArchiveFormat(key: "xar", displayName: L("XAR / pkg"), extensions: ["xar", "pkg", "mpkg"], supportsCompressionLevel: false),
        ArchiveFormat(key: "cpio", displayName: L("CPIO"), extensions: ["cpio"], supportsCompressionLevel: false),
        ArchiveFormat(key: "ar", displayName: L("Unix Archive"), extensions: ["a", "ar", "deb", "lib"], supportsCompressionLevel: false),
        ArchiveFormat(key: "rpm", displayName: "RPM", extensions: ["rpm"], supportsCompressionLevel: false),
        ArchiveFormat(key: "wim", displayName: "WIM", extensions: ["wim", "swm", "esd"], supportsCompressionLevel: false),
        ArchiveFormat(key: "lzh", displayName: "LZH", extensions: ["lzh", "lha"], supportsCompressionLevel: false),
        ArchiveFormat(key: "arj", displayName: "ARJ", extensions: ["arj"], supportsCompressionLevel: false),
        ArchiveFormat(key: "z", displayName: L("Compress"), extensions: ["z", "taz"], supportsCompressionLevel: false),
        ArchiveFormat(key: "chm", displayName: L("Compiled Help"), extensions: ["chm"], supportsCompressionLevel: false),
        ArchiveFormat(key: "msi", displayName: L("Windows Installer"), extensions: ["msi", "msp"], supportsCompressionLevel: false),
        ArchiveFormat(key: "vhd", displayName: L("Virtual Disk"), extensions: ["vhd", "vhdx", "vdi", "vmdk", "qcow2"], supportsCompressionLevel: false),
        ArchiveFormat(key: "squashfs", displayName: L("SquashFS"), extensions: ["squashfs", "sfs"], supportsCompressionLevel: false),
        // The first volume of an archive cut into pieces: "name.7z.001". What is
        // inside is whatever was cut, which 7-Zip works out when it joins them.
        ArchiveFormat(key: "split", displayName: L("Split Archive"), extensions: ["001"], supportsCompressionLevel: false),
    ]

    /// Formats offered in the Save As menu, in presentation order.
    public static var writable: [ArchiveFormat] {
        let order = ["zip", "7z", "tgz", "tar", "tbz2", "txz", "dmg", "gzip", "bzip2", "xz", "rar"]
        return order.compactMap { key in all.first { $0.key == key && $0.canWrite } }
    }

    public static func format(forKey key: String) -> ArchiveFormat? {
        all.first { $0.key == key }
    }

    /// Longest-suffix match so "tar.gz" beats "gz".
    public static func format(for url: URL) -> ArchiveFormat? {
        let name = url.lastPathComponent.lowercased()
        var best: (ArchiveFormat, Int)?
        for format in all {
            for ext in format.extensions where name.hasSuffix("." + ext) {
                if best == nil || ext.count > best!.1 { best = (format, ext.count) }
            }
        }
        return best?.0
    }

    public static func isArchive(_ url: URL) -> Bool {
        format(for: url) != nil
    }

    /// The name to save under: what was typed, with the extension of the format that
    /// was chosen. An archive extension already on the name is replaced; anything
    /// else that merely looks like one is part of the name, so "Backup 2024.10.05"
    /// stays whole.
    public static func saveName(typed: String, format: ArchiveFormat) -> String {
        var stem = typed
        while let current = self.format(for: URL(fileURLWithPath: "/" + stem)) {
            if stem == typed, current.key == format.key { return typed }
            let stripped = baseName(for: URL(fileURLWithPath: "/" + stem))
            if stripped == stem || stripped.isEmpty { break }
            stem = stripped
        }
        return "\(stem.isEmpty ? L("Archive") : stem).\(format.extensions[0])"
    }

    /// Strips every known archive suffix so "site.tar.gz" becomes "site".
    public static func baseName(for url: URL) -> String {
        let name = url.lastPathComponent
        let lower = name.lowercased()
        var bestLength = 0
        for format in all {
            for ext in format.extensions where lower.hasSuffix("." + ext) {
                bestLength = max(bestLength, ext.count + 1)
            }
        }
        guard bestLength > 0 else { return (name as NSString).deletingPathExtension }
        return String(name.dropLast(bestLength))
    }
}
