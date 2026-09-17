import Foundation

/// Parses the key/value output of `7zz l -slt`.
///
/// The stream looks like:
///
///     Listing archive: demo.zip
///     --
///     Path = demo.zip
///     Type = zip
///     ----------
///     Path = notes.txt
///     Size = 42
///     ...
public enum SevenZipListParser {
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone.current
        return f
    }()

    public static func parse(_ text: String) -> ArchiveListing {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        var info = ArchiveInfo()
        var entries: [ArchiveEntry] = []

        var inEntries = false
        var seenHeaderSeparator = false
        var current: [String: String] = [:]

        func flush() {
            defer { current = [:] }
            guard let rawPath = current["Path"], !rawPath.isEmpty else { return }
            entries.append(makeEntry(from: current, path: rawPath))
        }

        for line in lines {
            if line.hasPrefix("----------") {
                if !inEntries {
                    applyArchiveProperties(current, to: &info)
                    current = [:]
                }
                inEntries = true
                continue
            }
            if !inEntries, line == "--" {
                seenHeaderSeparator = true
                current = [:]
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if inEntries { flush() }
                continue
            }
            guard let range = line.range(of: " = ") else { continue }
            let key = String(line[line.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let value = String(line[range.upperBound...])
            guard !key.isEmpty else { continue }
            if !inEntries && !seenHeaderSeparator { continue }
            current[key] = value
        }
        if inEntries { flush() } else { applyArchiveProperties(current, to: &info) }

        return ArchiveListing(info: info, entries: entries)
    }

    private static func applyArchiveProperties(_ props: [String: String], to info: inout ArchiveInfo) {
        if let type = props["Type"] { info.formatName = type }
        if let size = props["Physical Size"].flatMap({ UInt64($0) }) { info.physicalSize = size }
        if let solid = props["Solid"] { info.isSolid = solid == "+" }
        if let encrypted = props["Encrypted"] { info.hasEncryptedHeader = encrypted == "+" }
        if let comment = props["Comment"], !comment.isEmpty { info.comment = comment }
        if let volumes = props["Volumes"].flatMap({ Int($0) }) { info.volumeCount = volumes }
    }

    private static func makeEntry(from props: [String: String], path: String) -> ArchiveEntry {
        let attributes = props["Attributes"]
        let isDirectory: Bool = {
            if let folder = props["Folder"] { return folder == "+" }
            if let attributes, attributes.hasPrefix("D") { return true }
            return false
        }()

        let size = props["Size"].flatMap { UInt64($0) } ?? 0
        let packed = props["Packed Size"].flatMap { UInt64($0) } ?? 0
        let crc = props["CRC"].flatMap { $0.isEmpty ? nil : $0 }
        let encrypted = props["Encrypted"] == "+"
        let method = props["Method"].flatMap { $0.isEmpty ? nil : $0 }

        var modified: Date?
        if let raw = props["Modified"], raw.count >= 19 {
            modified = timestampFormatter.date(from: String(raw.prefix(19)))
        }

        return ArchiveEntry(path: path,
                            isDirectory: isDirectory,
                            size: size,
                            packedSize: packed,
                            modified: modified,
                            crc: crc,
                            attributes: attributes,
                            isEncrypted: encrypted,
                            method: method)
    }
}
