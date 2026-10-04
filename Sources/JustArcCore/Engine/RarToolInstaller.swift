import CryptoKit
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
        /// The download differs from the release it claims to be.
        case checksumMismatch(String)
        /// Nothing was available to check the download against.
        case unverified(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedArchitecture:
                return L("RARLAB does not publish a build for this processor.")
            case .downloadFailed(let detail):
                return L("The download did not finish. %@", detail)
            case .archiveUnreadable:
                return L("The downloaded file could not be unpacked.")
            case .toolMissingFromArchive:
                return L("The download did not contain the rar tool.")
            case .toolDidNotRun(let detail):
                return L("The downloaded tool would not run. %@", detail)
            case .checksumMismatch(let file):
                return L("%@ is not the file that was published under that name, so it was not installed. Try again later.", file)
            case .unverified(let file):
                return L("JustArc has nothing to check %@ against, so it could not confirm the download is genuine.", file)
            }
        }
    }

    public struct Installation {
        public let tool: URL
        public let version: String
        /// False when the user chose to install a download that could not be checked.
        public let wasVerified: Bool
    }

    // MARK: - Checking the download

    /// SHA-256 of the releases JustArc knows about, by file name.
    ///
    /// RARLAB publishes no checksums of its own and signs the tool ad hoc, so the
    /// download cannot be checked against its maker. These come from Homebrew's
    /// cask for rar, which records the hash of each release it packages: a second
    /// source, independent of rarlab.com, that would have to be wrong in the same way.
    static let knownChecksums: [String: String] = [
        "rarmacos-arm-723.tar.gz": "68b393c000758d477fde43c955ff7542f12f76f3f5e87cdda923152fc791bd4d",
        "rarmacos-x64-723.tar.gz": "da1fb3c3d7748136c9b369b683d574b372cb1ed049a634a81f85d93918346d8f",
    ]

    /// Where the hash of a release newer than this build of JustArc is looked up.
    private static let homebrewCask = URL(string: "https://formulae.brew.sh/api/cask/rar.json")!

    /// Reads every "url" and "sha256" pair out of Homebrew's description of the cask,
    /// which lists the Apple silicon build at the top and the Intel one per macOS
    /// version under "variations".
    static func checksums(fromHomebrewCask data: Data) -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        func take(_ entry: [String: Any]) {
            guard let url = entry["url"] as? String, let hash = entry["sha256"] as? String,
                  hash.count == 64, let name = URL(string: url)?.lastPathComponent else { return }
            result[name] = hash.lowercased()
        }
        take(root)
        for case let variation as [String: Any] in (root["variations"] as? [String: Any] ?? [:]).values {
            take(variation)
        }
        return result
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    enum Verdict: Equatable {
        case verified
        /// A hash is on record for this file name and this is not it.
        case mismatch
        /// No hash is on record for this file name anywhere.
        case unknown
    }

    /// Compares a download's hash with every record of what it should be.
    static func verdict(digest: String, fileName: String, published: [String: String]) -> Verdict {
        let expected = [knownChecksums[fileName], published[fileName]].compactMap { $0 }
        if expected.contains(digest.lowercased()) { return .verified }
        return expected.isEmpty ? .unknown : .mismatch
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

    /// Downloads, checks, unpacks and installs the tools, replacing any previous
    /// managed copy.
    ///
    /// - Parameter allowUnverified: install even when there is nothing to check the
    ///   download against, which happens for a release newer than both this build
    ///   and Homebrew's record. A download that fails a check is never installed.
    public static func install(allowUnverified: Bool = false,
                               progress: @escaping @Sendable (Double?) -> Void) async throws -> Installation {
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

        // Nothing from the download is unpacked, let alone run, until it has been
        // checked. Homebrew is only asked when this build has no record of its own.
        let fileName = source.lastPathComponent
        let digest = try sha256(of: tarball)
        var result = verdict(digest: digest, fileName: fileName, published: [:])
        if result != .verified, let (data, _) = try? await URLSession.shared.data(from: homebrewCask) {
            result = verdict(digest: digest, fileName: fileName, published: checksums(fromHomebrewCask: data))
        }
        Diagnostics.log("rar download \(fileName): sha256 \(digest), \(result)")
        switch result {
        case .verified:
            break
        case .mismatch:
            throw InstallerError.checksumMismatch(fileName)
        case .unknown:
            guard allowUnverified else { throw InstallerError.unverified(fileName) }
        }

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

        for name in ["rar", "unrar", "default.sfx"] {
            let item = unpacked.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: item.path) else { continue }
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: item.path)
        }

        // Prove the new copy runs before the working one is given up for it.
        let banner = try await ProcessRunner.run(executable: toolInStaging, arguments: [])
        guard let version = version(fromBanner: banner.combined) else {
            throw InstallerError.toolDidNotRun(banner.combined.prefix(200).description)
        }

        let destination = EngineLocator.managedRARDirectory
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: unpacked)
        } else {
            try FileManager.default.moveItem(at: unpacked, to: destination)
        }

        let tool = destination.appendingPathComponent("rar")
        // Clear any stale override so the freshly installed copy is the one used.
        UserDefaults.standard.removeObject(forKey: "RARToolPath")
        progress(1)
        Diagnostics.log("installed rar \(version) at \(tool.path)")
        return Installation(tool: tool, version: version, wasVerified: result == .verified)
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
            throw InstallerError.downloadFailed(L("The server refused the request."))
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func download(_ url: URL,
                                 to destination: URL,
                                 progress: @escaping @Sendable (Double?) -> Void) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw InstallerError.downloadFailed(L("The server returned an unexpected response."))
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
            throw InstallerError.downloadFailed(L("The file was too small to be the RAR tools."))
        }
        try data.write(to: destination, options: .atomic)
    }
}
