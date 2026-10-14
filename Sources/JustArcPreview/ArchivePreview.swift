import Foundation
import JustArcCore

/// What Quick Look shows for an archive: what it is, and what is in it.
///
/// Read without asking anything of anyone. Quick Look is a glance: there is no one
/// to type a password, and no patience for a wait.
public struct ArchivePreview: Sendable {
    public enum Contents: Sendable {
        case listing(ArchiveListing)
        /// The names themselves are encrypted.
        case locked
        /// A compressed tar has no index, so listing it means decompressing all of
        /// it first, and this one is too big for that to be a glance.
        case tooLargeToList
        case unreadable(String)
    }

    public let url: URL
    public let formatName: String
    /// The archive's own size on disk.
    public let fileSize: UInt64
    public let contents: Contents

    /// The largest compressed tar that is unwrapped just to be looked at.
    public static let unwrapLimit: UInt64 = 256 << 20

    public static func load(_ url: URL, unwrapLimit: UInt64 = ArchivePreview.unwrapLimit) async -> ArchivePreview {
        let format = FormatRegistry.format(for: url)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        func preview(_ contents: Contents, named name: String? = nil) -> ArchivePreview {
            ArchivePreview(url: url,
                           formatName: format?.displayName ?? name ?? url.pathExtension.uppercased(),
                           fileSize: fileSize, contents: contents)
        }

        let compressedTars: Set<String> = ["tgz", "tbz2", "txz", "tzst"]
        if let format, compressedTars.contains(format.key), fileSize > unwrapLimit {
            return preview(.tooLargeToList)
        }

        // Always 7-Zip, whatever the format: a disk image would have to be mounted,
        // which is not something to do because a file was glanced at.
        let engine = SevenZipEngine()
        do {
            let listing = try await engine.list(archive: url, password: nil, encodingCodePage: nil)
            // Nothing here will be extracted, so what was unwrapped to list a
            // compressed tar is given back at once.
            engine.release(archive: url)
            Diagnostics.log("preview: \(url.lastPathComponent) lists \(public: listing.entries.count) entries")
            return preview(.listing(listing), named: listing.info.formatName.uppercased())
        } catch let error as ArchiveError where error.isPasswordProblem {
            return preview(.locked)
        } catch {
            Diagnostics.log("preview: \(url.lastPathComponent) could not be listed: \(error.localizedDescription)")
            return preview(.unreadable(error.localizedDescription))
        }
    }

    /// The line under the archive's name: its format and how much it holds.
    public var summary: String {
        var parts = [formatName]
        if case .listing(let listing) = contents {
            let folders = Set(listing.entries.flatMap { entry -> [String] in
                var paths = entry.isDirectory ? [entry.path] : []
                var parent = Substring(entry.path)
                while let slash = parent.lastIndex(of: "/") {
                    parent = parent[..<slash]
                    paths.append(String(parent))
                }
                return paths
            }).count
            parts.append(L("Files: %@", Formatting.count(listing.fileCount)))
            if folders > 0 { parts.append(L("Folders: %@", Formatting.count(folders))) }
            parts.append(L("Size: %@", Formatting.bytes(fileSize)))
            parts.append(L("Unpacked size: %@", Formatting.bytes(listing.totalSize)))
            if listing.containsEncryptedEntries { parts.append(L("Encrypted")) }
        } else {
            parts.append(L("Size: %@", Formatting.bytes(fileSize)))
            if case .locked = contents { parts.append(L("Encrypted")) }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }

    /// What is said in place of the list when there is none to show.
    public var message: String? {
        switch contents {
        case .listing(let listing):
            return listing.entries.isEmpty ? L("This archive is empty.") : nil
        case .locked:
            return L("The names of the files in this archive are encrypted. Open it in JustArc to enter the password.")
        case .tooLargeToList:
            return L("This archive has to be decompressed in full before its contents can be listed. Open it in JustArc to see what is inside.")
        case .unreadable(let reason):
            return reason
        }
    }
}
