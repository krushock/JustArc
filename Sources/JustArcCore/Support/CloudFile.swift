import Foundation

/// Handles files that live in iCloud Drive, Google Drive, Dropbox and the like.
///
/// macOS shows those as ordinary files, but the data may not be on disk. Such a file is
/// flagged dataless and occupies no blocks. Reading it asks the provider to fetch it, and
/// when the provider is slow or not running that read fails with a bare errno, which is
/// not something anyone can act on. Asking the provider through a file coordinator
/// instead gives both a wait that can be cancelled and a reason worth showing.
public enum CloudFile {
    /// SF_DATALESS: the file is a placeholder whose contents live in the cloud.
    private static let datalessFlag = UInt32(SF_DATALESS)

    public struct Status: Sendable {
        public let isCloudItem: Bool
        /// False when the file is a placeholder with no local contents.
        public let isMaterialized: Bool
        /// "Google Drive", "iCloud Drive" and so on, when it can be worked out.
        public let providerName: String?

        public var needsDownload: Bool { isCloudItem && !isMaterialized }
    }

    public static func status(of url: URL) -> Status {
        var info = stat()
        let stated = stat(url.path, &info) == 0
        let dataless = stated && (info.st_flags & datalessFlag) != 0

        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey])
        let ubiquitous = values?.isUbiquitousItem ?? false
        let provider = providerName(for: url)

        return Status(isCloudItem: dataless || ubiquitous || provider != nil,
                      isMaterialized: !dataless,
                      providerName: provider)
    }

    /// Cloud providers mount under ~/Library/CloudStorage/<Provider>-<account>, and
    /// iCloud Drive under Mobile Documents. The name is only ever used in a message.
    public static func providerName(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        if path.contains("/Library/Mobile Documents/") { return "iCloud Drive" }

        guard let range = path.range(of: "/Library/CloudStorage/") else { return nil }
        let rest = path[range.upperBound...]
        guard let folder = rest.split(separator: "/").first else { return nil }
        // "GoogleDrive-someone@example.com" becomes "GoogleDrive".
        let vendor = folder.split(separator: "-").first.map(String.init) ?? String(folder)
        return spaced(vendor)
    }

    /// Splits a run-together vendor name so "GoogleDrive" reads as "Google Drive".
    static func spaced(_ name: String) -> String {
        var result = ""
        for (offset, character) in name.enumerated() {
            if offset > 0, character.isUppercase,
               let previous = result.last, !previous.isUppercase {
                result.append(" ")
            }
            result.append(character)
        }
        return result
    }

    /// Makes sure the file's contents are on disk, asking the provider to fetch them
    /// if they are not. Returns immediately for ordinary files.
    public static func materialize(_ url: URL,
                                   cancellation: CancellationToken? = nil,
                                   progress: ProgressHandler? = nil) async throws {
        let before = status(of: url)
        guard before.needsDownload else { return }

        Diagnostics.log("materializing \(url.lastPathComponent) from "
                        + "\(before.providerName ?? "a cloud provider")")
        progress?(ArchiveProgress(fraction: nil, currentFile: url.lastPathComponent))

        // Harmless for non-iCloud providers, and it starts the fetch for iCloud ones.
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)

        do {
            try await coordinatedRead(url, cancellation: cancellation)
        } catch {
            throw notDownloadedError(url, status: before, reason: error.localizedDescription)
        }

        // The coordinator can return without the placeholder having been filled in.
        let after = status(of: url)
        if after.needsDownload {
            throw notDownloadedError(url, status: after, reason: nil)
        }
    }

    /// Internal rather than private so the wording can be pinned down by a test.
    static func notDownloadedError(_ url: URL,
                                   status: Status,
                                   reason: String?) -> ArchiveError {
        let provider = status.providerName ?? L("the cloud")
        // Kept as one literal: a key built by concatenation cannot be extracted for translation.
        var message = L("%@ is stored in %@ and has not been downloaded to this Mac. Open it in Finder to download it, and check that %@ is running.",
                        url.lastPathComponent, provider, provider)
        if let reason, !reason.isEmpty {
            message += "\n\n" + reason
        }
        return .notDownloaded(message)
    }

    /// Reads one byte through a file coordinator, which is what makes the provider
    /// materialise the file and wait properly instead of failing on a kernel timeout.
    private static func coordinatedRead(_ url: URL, cancellation: CancellationToken?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let coordinator = NSFileCoordinator(filePresenter: nil)
            cancellation?.onCancel { coordinator.cancel() }

            DispatchQueue.global(qos: .userInitiated).async {
                var coordinationError: NSError?
                var readError: Error?

                coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { resolved in
                    do {
                        let handle = try FileHandle(forReadingFrom: resolved)
                        defer { try? handle.close() }
                        _ = try handle.read(upToCount: 1)
                    } catch {
                        readError = error
                    }
                }

                if let coordinationError {
                    continuation.resume(throwing: coordinationError)
                } else if let readError {
                    continuation.resume(throwing: readError)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Materialises several files in turn, which is what adding cloud files to an
    /// archive needs.
    public static func materializeAll(_ urls: [URL],
                                      cancellation: CancellationToken? = nil,
                                      progress: ProgressHandler? = nil) async throws {
        for url in urls {
            if cancellation?.isCancelled == true { throw ArchiveError.cancelled }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                try await materializeTree(url, cancellation: cancellation, progress: progress)
            } else {
                try await materialize(url, cancellation: cancellation, progress: progress)
            }
        }
    }

    private static func materializeTree(_ root: URL,
                                        cancellation: CancellationToken?,
                                        progress: ProgressHandler?) async throws {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { return }
        for case let child as URL in walker {
            if cancellation?.isCancelled == true { throw ArchiveError.cancelled }
            let values = try? child.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            try await materialize(child, cancellation: cancellation, progress: progress)
        }
    }
}
