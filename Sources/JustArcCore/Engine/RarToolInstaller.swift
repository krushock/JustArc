import Foundation

/// Downloads RARLAB's command line tools on request and installs them into
/// Application Support.
///
/// The tools are not shipped with JustArc because RAR is proprietary and cannot be
/// redistributed. They are also not written into the app bundle: that would invalidate
/// the code signature, and the bundle is usually on a volume the user cannot write to.
public enum RarToolInstaller {
    /// Used when the download page cannot be read, so the button still works offline-ish.
    public static let fallbackVersion = "723"
    private static let downloadPage = URL(string: "https://www.rarlab.com/download.htm")!

    public enum InstallerError: LocalizedError {
        case unsupportedArchitecture
        case downloadFailed(String)
        case archiveUnreadable
        case toolMissingFromArchive
        case toolDidNotRun(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedArchitecture:
                return "RARLAB does not publish a build for this processor."
            case .downloadFailed(let detail):
                return "The download did not finish. \(detail)"
            case .archiveUnreadable:
                return "The downloaded file could not be unpacked."
            case .toolMissingFromArchive:
                return "The download did not contain the rar tool."
            case .toolDidNotRun(let detail):
                return "The downloaded tool would not run. \(detail)"
            }
        }
    }

    public struct Installation {
        public let tool: URL
        public let version: String
    }

    /// arm for Apple silicon, x64 for Intel. RARLAB names its files this way.
    public static var architectureSlug: String? {
        #if arch(arm64)
        return "arm"
        #elseif arch(x86_64)
        return "x64"
        #else
        return nil
        #endif
    }

    public static var isInstalled: Bool {
        EngineLocator.externalRAR != nil
    }

    /// Whether the copy in use is one JustArc downloaded, as opposed to the user's own.
    public static var isManagedInstall: Bool {
        guard let tool = EngineLocator.externalRAR else { return false }
        return tool.standardizedFileURL.path
            .hasPrefix(EngineLocator.managedRARDirectory.standardizedFileURL.path)
    }

    /// Reads `rar`'s banner, which starts with "RAR 7.23 Copyright…".
    public static func installedVersion() async -> String? {
        guard let tool = EngineLocator.externalRAR else { return nil }
        guard let result = try? await ProcessRunner.run(executable: tool, arguments: []) else { return nil }
        return version(fromBanner: result.combined)
    }

    public static func version(fromBanner banner: String) -> String? {
        guard let line = banner.components(separatedBy: .newlines).first(where: { $0.contains("RAR") }),
              let range = line.range(of: #"\d+\.\d+"#, options: .regularExpression) else { return nil }
        return String(line[range])
    }

    /// Picks the newest macOS build listed on RARLAB's download page.
    public static func latestDownloadURL() async -> URL {
        let slug = architectureSlug ?? "arm"
        if let page = try? await fetchText(downloadPage),
           let newest = newestVersion(onPage: page, slug: slug) {
            return URL(string: "https://www.rarlab.com/rar/rarmacos-\(slug)-\(newest).tar.gz")!
        }
        return URL(string: "https://www.rarlab.com/rar/rarmacos-\(slug)-\(fallbackVersion).tar.gz")!
    }

    public static func newestVersion(onPage page: String, slug: String) -> String? {
        let pattern = "rarmacos-\(slug)-([0-9]+)\\.tar\\.gz"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(page.startIndex..., in: page)
        var versions: [String] = []
        regex.enumerateMatches(in: page, range: range) { match, _, _ in
            guard let match, let captured = Range(match.range(at: 1), in: page) else { return }
            versions.append(String(page[captured]))
        }
        // Version strings are digit runs like "723"; the numerically largest is newest.
        return versions.max { ($0.count, $0) < ($1.count, $1) }
    }

    /// Downloads, unpacks and installs the tools, replacing any previous managed copy.
    public static func install(progress: @escaping @Sendable (Double?) -> Void) async throws -> Installation {
        guard architectureSlug != nil else { throw InstallerError.unsupportedArchitecture }

        progress(nil)
        let source = await latestDownloadURL()
        Diagnostics.log("downloading rar from \(source.absoluteString)")

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("justarc-rar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let tarball = staging.appendingPathComponent("rar.tar.gz")
        try await download(source, to: tarball, progress: progress)

        // bsdtar ships with macOS and handles the gzip layer itself.
        let unpack = try await ProcessRunner.run(
            executable: EngineLocator.bsdTar,
            arguments: ["-xzf", tarball.path, "-C", staging.path])
        guard unpack.exitCode == 0 else { throw InstallerError.archiveUnreadable }

        let unpacked = staging.appendingPathComponent("rar")
        let toolInStaging = unpacked.appendingPathComponent("rar")
        guard FileManager.default.fileExists(atPath: toolInStaging.path) else {
            throw InstallerError.toolMissingFromArchive
        }

        let destination = EngineLocator.managedRARDirectory
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: unpacked, to: destination)

        let tool = destination.appendingPathComponent("rar")
        for name in ["rar", "unrar", "default.sfx"] {
            let item = destination.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: item.path) else { continue }
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: item.path)
        }

        // Prove it actually runs before reporting success.
        let banner = try await ProcessRunner.run(executable: tool, arguments: [])
        guard let version = version(fromBanner: banner.combined) else {
            throw InstallerError.toolDidNotRun(banner.combined.prefix(200).description)
        }

        // Clear any stale override so the freshly installed copy is the one used.
        UserDefaults.standard.removeObject(forKey: "RARToolPath")
        progress(1)
        Diagnostics.log("installed rar \(version) at \(tool.path)")
        return Installation(tool: tool, version: version)
    }

    public static func removeManagedInstall() throws {
        let directory = EngineLocator.managedRARDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    /// The licence text that came with the download, if it is there.
    public static var licenseURL: URL? {
        let url = EngineLocator.managedRARDirectory.appendingPathComponent("license.txt")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Networking

    private static func fetchText(_ url: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw InstallerError.downloadFailed("The server refused the request.")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func download(_ url: URL,
                                 to destination: URL,
                                 progress: @escaping @Sendable (Double?) -> Void) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw InstallerError.downloadFailed("The server returned an unexpected response.")
        }

        let expected = response.expectedContentLength
        var data = Data()
        data.reserveCapacity(expected > 0 ? Int(expected) : 1_000_000)
        var lastReport = Date.distantPast

        for try await byte in bytes {
            data.append(byte)
            if expected > 0, Date().timeIntervalSince(lastReport) > 0.1 {
                lastReport = Date()
                progress(min(Double(data.count) / Double(expected), 1))
            }
        }

        guard data.count > 100_000 else {
            throw InstallerError.downloadFailed("The file was too small to be the RAR tools.")
        }
        try data.write(to: destination, options: .atomic)
    }
}
