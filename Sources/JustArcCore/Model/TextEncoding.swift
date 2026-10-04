import Foundation

/// Filename encodings for archives that predate UTF-8. Zip in particular stores names
/// in whatever code page the machine that made it was using, and says nothing about
/// which. Names that are valid UTF-8 are read as UTF-8; the rest are decoded with the
/// encoding chosen here, or with a guess when it is left on Automatic.
public struct ArchiveTextEncoding: Sendable, Hashable, Identifiable {
    public var id: Int { codePage ?? 0 }
    public let title: String
    /// nil means "let the engine decide".
    public let codePage: Int?

    public init(title: String, codePage: Int?) {
        self.title = title
        self.codePage = codePage
    }

    public static let automatic = ArchiveTextEncoding(title: L("Automatic"), codePage: nil)

    public static let all: [ArchiveTextEncoding] = [
        automatic,
        ArchiveTextEncoding(title: L("Unicode (UTF-8)"), codePage: 65001),
        ArchiveTextEncoding(title: L("Western (Windows 1252)"), codePage: 1252),
        ArchiveTextEncoding(title: L("Western (DOS 437)"), codePage: 437),
        ArchiveTextEncoding(title: L("Central European (Windows 1250)"), codePage: 1250),
        ArchiveTextEncoding(title: L("Cyrillic (Windows 1251)"), codePage: 1251),
        ArchiveTextEncoding(title: L("Cyrillic (DOS 866)"), codePage: 866),
        ArchiveTextEncoding(title: L("Japanese (Shift JIS)"), codePage: 932),
        ArchiveTextEncoding(title: L("Simplified Chinese (GBK)"), codePage: 936),
        ArchiveTextEncoding(title: L("Korean (EUC-KR)"), codePage: 949),
        ArchiveTextEncoding(title: L("Traditional Chinese (Big5)"), codePage: 950),
    ]

    /// The DOS code page old archives are most likely to use for someone who reads
    /// this language. An archive from a Russian Windows machine is in 866, from a
    /// Japanese one in 932; 437 is what the zip format specifies when nothing is known.
    public static func legacyCodePage(forLanguage language: String) -> Int {
        let code = language.lowercased()
        let prefixes: [(String, Int)] = [
            ("zh-hant", 950), ("zh-tw", 950), ("zh-hk", 950), ("zh", 936),
            ("ja", 932), ("ko", 949),
            ("ru", 866), ("uk", 866), ("be", 866), ("bg", 866), ("kk", 866), ("sr", 866), ("mk", 866),
            ("pl", 852), ("cs", 852), ("sk", 852), ("hu", 852), ("ro", 852), ("hr", 852), ("sl", 852),
            ("el", 737), ("tr", 857), ("he", 862), ("ar", 720), ("th", 874),
            ("lt", 775), ("lv", 775), ("et", 775),
        ]
        return prefixes.first { code.hasPrefix($0.0) }?.1 ?? 437
    }

    /// The guess for this Mac, from the language the user prefers.
    public static var likelyLegacyCodePage: Int {
        legacyCodePage(forLanguage: Locale.preferredLanguages.first ?? "en")
    }

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
