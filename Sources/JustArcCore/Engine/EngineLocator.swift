import Foundation

/// Finds the bundled 7-Zip library and any optional user-installed tools.
public enum EngineLocator {
    public static let sevenZipName = "7zz"

    /// The 7zz command-line tool. The app itself no longer runs it (see
    /// `sevenZipLibrary`); the tests use it to build fixtures independently of the
    /// code under test. Search order: JUSTARC_7ZZ override, the repository Vendor
    /// folder, then Homebrew.
    public static var sevenZip: URL? = {
        var candidates: [URL] = []

        if let override = ProcessInfo.processInfo.environment["JUSTARC_7ZZ"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        candidates.append(contentsOf: developmentVendorCandidates(for: sevenZipName))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/\(sevenZipName)"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/\(sevenZipName)"))

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    public static let sevenZipLibraryName = "7z.so"

    /// 7-Zip's format library, loaded into the app so archives are read and written
    /// without a helper process. Search order: the app bundle's Frameworks folder, a
    /// JUSTARC_7Z_LIBRARY override, then the repository Vendor folder during development.
    public static var sevenZipLibrary: URL? = {
        var candidates: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            let contents = resourceURL.deletingLastPathComponent()
            candidates.append(contents.appendingPathComponent("Frameworks/\(sevenZipLibraryName)"))
        }
        if let override = ProcessInfo.processInfo.environment["JUSTARC_7Z_LIBRARY"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        candidates.append(contentsOf: developmentVendorCandidates(for: sevenZipLibraryName))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }()

    public static let bsdTar = URL(fileURLWithPath: "/usr/bin/bsdtar")
    public static let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")

    /// Where JustArc keeps things it downloads. The app bundle is not used, because
    /// writing into it breaks the code signature and it may sit on a read-only volume.
    public static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("JustArc", isDirectory: true)
    }

    /// The folder a downloaded copy of RARLAB's tools is installed into.
    public static var managedRARDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("rar", isDirectory: true)
    }

    /// RAR writing needs RARLAB's own tool, which cannot be redistributed with the app.
    /// It is found where the user pointed us, where JustArc installed it, or on PATH.
    public static var externalRAR: URL? {
        var candidates: [URL] = []
        if let override = UserDefaults.standard.string(forKey: "RARToolPath"), !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        candidates.append(managedRARDirectory.appendingPathComponent("rar"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/rar"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/rar"))
        candidates.append(URL(fileURLWithPath: "/opt/local/bin/rar"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static func requireSevenZip() throws -> URL {
        guard let sevenZip else {
            throw ArchiveError.engineMissing("Vendor/\(sevenZipName)")
        }
        return sevenZip
    }

    /// Walks up from the compiled binary to find Vendor/ when running from a build folder.
    private static func developmentVendorCandidates(for name: String) -> [URL] {
        var results: [URL] = []
        var directory = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .deletingLastPathComponent()
        for _ in 0..<6 {
            results.append(directory.appendingPathComponent("Vendor/\(name)"))
            directory = directory.deletingLastPathComponent()
        }
        results.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Vendor/\(name)"))
        return results
    }
}
