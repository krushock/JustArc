import Foundation

/// A kind of archive the user can choose a default app for in Settings.
///
/// macOS types a file by its last extension only, so `site.tar.gz` is a GZip file as
/// far as the Finder is concerned; that is why GZip, BZip2 and XZ mention the tar
/// variants they also cover.
public struct AssociableFileType: Sendable, Hashable {
    public let title: String
    /// Lowercase, no dot. The first one is used to look the type up.
    public let extensions: [String]
    /// Shown beside the title, when the plain extension list would mislead.
    public let detail: String?
    /// Disk images mount, and that is what people expect of them, so "use JustArc
    /// for everything" leaves them alone.
    public let isIncludedInAll: Bool

    public init(_ title: String, _ extensions: [String], detail: String? = nil, isIncludedInAll: Bool = true) {
        self.title = title
        self.extensions = extensions
        self.detail = detail
        self.isIncludedInAll = isIncludedInAll
    }

    public var extensionList: String {
        detail ?? extensions.map { "." + $0 }.joined(separator: ", ")
    }

    public static let all: [AssociableFileType] = [
        AssociableFileType("ZIP", ["zip"]),
        AssociableFileType("RAR", ["rar"]),
        AssociableFileType("7-Zip", ["7z"]),
        AssociableFileType("TAR", ["tar"]),
        AssociableFileType("GZip", ["gz"], detail: ".gz, .tar.gz"),
        AssociableFileType(L("TAR + GZip"), ["tgz"]),
        AssociableFileType("BZip2", ["bz2"], detail: ".bz2, .tar.bz2"),
        AssociableFileType(L("TAR + BZip2"), ["tbz2", "tbz"]),
        AssociableFileType("XZ", ["xz"], detail: ".xz, .tar.xz"),
        AssociableFileType(L("TAR + XZ"), ["txz"]),
        AssociableFileType("Zstandard", ["zst"], detail: ".zst, .tar.zst"),
        AssociableFileType(L("TAR + Zstandard"), ["tzst"]),
        AssociableFileType(L("Cabinet"), ["cab"]),
        AssociableFileType("LZH", ["lzh", "lha"]),
        AssociableFileType("ARJ", ["arj"]),
        AssociableFileType(L("CPIO"), ["cpio"]),
        AssociableFileType("WIM", ["wim"]),
        AssociableFileType(L("Debian Package"), ["deb"]),
        AssociableFileType("RPM", ["rpm"]),
        AssociableFileType(L("ISO Image"), ["iso"], isIncludedInAll: false),
        AssociableFileType(L("Disk Image"), ["dmg"], isIncludedInAll: false),
    ]
}
