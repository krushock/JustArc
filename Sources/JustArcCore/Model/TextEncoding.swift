import Foundation

/// Filename encodings for archives that predate UTF-8. Zip in particular stores names
/// in whatever code page the machine that made it was using, and 7-Zip takes the
/// override as `-mcp=<code page>`.
public struct ArchiveTextEncoding: Sendable, Hashable, Identifiable {
    public var id: Int { codePage ?? 0 }
    public let title: String
    /// nil means "let the engine decide".
    public let codePage: Int?

    public init(title: String, codePage: Int?) {
        self.title = title
        self.codePage = codePage
    }

    public static let automatic = ArchiveTextEncoding(title: "Automatic", codePage: nil)

    public static let all: [ArchiveTextEncoding] = [
        automatic,
        ArchiveTextEncoding(title: "Unicode (UTF-8)", codePage: 65001),
        ArchiveTextEncoding(title: "Western (Windows 1252)", codePage: 1252),
        ArchiveTextEncoding(title: "Western (DOS 437)", codePage: 437),
        ArchiveTextEncoding(title: "Central European (Windows 1250)", codePage: 1250),
        ArchiveTextEncoding(title: "Cyrillic (Windows 1251)", codePage: 1251),
        ArchiveTextEncoding(title: "Cyrillic (DOS 866)", codePage: 866),
        ArchiveTextEncoding(title: "Japanese (Shift JIS)", codePage: 932),
        ArchiveTextEncoding(title: "Simplified Chinese (GBK)", codePage: 936),
        ArchiveTextEncoding(title: "Korean (EUC-KR)", codePage: 949),
        ArchiveTextEncoding(title: "Traditional Chinese (Big5)", codePage: 950),
    ]

    public static func named(codePage: Int?) -> ArchiveTextEncoding {
        all.first { $0.codePage == codePage } ?? automatic
    }

    /// Only the zip family stores names without declaring an encoding, so the override
    /// is meaningless elsewhere.
    public static func isOverridable(_ format: ArchiveFormat?) -> Bool {
        guard let format else { return false }
        return format.key == "zip"
    }
}
