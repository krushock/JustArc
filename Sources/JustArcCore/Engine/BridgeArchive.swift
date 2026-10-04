import Foundation
import SevenZipBridge

/// An archive opened in process through the 7-Zip bridge. Owns the bridge handle and
/// closes it when released. Every method blocks, so call them off the main thread.
final class BridgeArchive {
    private let handle: OpaquePointer
    let url: URL
    let password: String?

    private init(handle: OpaquePointer, url: URL, password: String?) {
        self.handle = handle
        self.url = url
        self.password = password
    }

    deinit {
        sz_close(handle)
    }

    static func open(_ url: URL, password: String?, codePage: Int?) throws -> BridgeArchive {
        try SevenZipLibrary.ensureLoaded()
        var error = SZError()
        let handle: OpaquePointer? = withOptionalCString(password) { passwordPointer in
            withOptionalCString(url.pathExtension.lowercased()) { hint in
                url.path.withCString { path in
                    var options = SZOpenOptions(password: passwordPointer,
                                                extensionHint: hint,
                                                codePage: Int32(codePage ?? -1),
                                                fallbackCodePage: Int32(ArchiveTextEncoding.likelyLegacyCodePage))
                    return sz_open(path, &options, &error)
                }
            }
        }
        guard let handle else {
            throw BridgeError.archiveError(error.status, &error, password: password)
        }
        return BridgeArchive(handle: handle, url: url, password: password)
    }

    // MARK: - Reading

    var info: ArchiveInfo {
        var raw = SZArchiveInfo()
        sz_archive_info(handle, &raw)
        return ArchiveInfo(formatName: String(cString: raw.formatName),
                           physicalSize: raw.physicalSize,
                           isSolid: raw.isSolid,
                           hasEncryptedHeader: raw.headersEncrypted,
                           comment: raw.comment.map { String(cString: $0) })
    }

    var formatName: String {
        var raw = SZArchiveInfo()
        sz_archive_info(handle, &raw)
        return String(cString: raw.formatName)
    }

    var itemCount: UInt32 {
        sz_item_count(handle)
    }

    func item(_ index: UInt32) -> ArchiveEntry? {
        var raw = SZItem()
        guard sz_item(handle, index, &raw) else { return nil }

        var modified: Date?
        if raw.hasModified {
            modified = Date(timeIntervalSince1970: TimeInterval(raw.modifiedSeconds)
                            + TimeInterval(raw.modifiedNanoseconds) / 1_000_000_000)
        }
        return ArchiveEntry(path: String(cString: raw.path),
                            isDirectory: raw.isDirectory,
                            size: raw.size,
                            packedSize: raw.packedSize,
                            modified: modified,
                            crc: raw.hasCRC ? String(format: "%08X", raw.crc) : nil,
                            attributes: raw.hasPosixMode ? Self.modeString(raw.posixMode, link: raw.isSymlink) : nil,
                            isEncrypted: raw.encrypted,
                            method: raw.method.map { String(cString: $0) })
    }

    func entries() -> [ArchiveEntry] {
        (0..<itemCount).compactMap(item)
    }

    /// Every item's index, keyed by its normalized path.
    func indices() -> [(index: UInt32, path: String)] {
        (0..<itemCount).compactMap { index in
            item(index).map { (index, $0.path) }
        }
    }

    // MARK: - Extracting

    @discardableResult
    func extract(indices: [UInt32]?,
                 destination: URL?,
                 password: String?,
                 overwrite: OverwriteMode,
                 flatten: Bool,
                 testOnly: Bool,
                 progress: BridgeProgress) throws -> SZExtractSummary {
        var error = SZError()
        var summary = SZExtractSummary()
        let status: SZStatus = withOptionalCString(destination?.path) { destinationPointer in
            withOptionalCString(password ?? self.password) { passwordPointer in
                var options = SZExtractOptions(destination: destinationPointer,
                                               password: passwordPointer,
                                               overwrite: overwrite.bridgeValue,
                                               flatten: flatten,
                                               testOnly: testOnly)
                return withExtendedLifetime(progress) {
                    if let indices {
                        return indices.withUnsafeBufferPointer { buffer in
                            sz_extract(handle, buffer.baseAddress, UInt32(buffer.count), &options,
                                       progress.callback, progress.context, &summary, &error)
                        }
                    }
                    return sz_extract(handle, nil, 0, &options, progress.callback, progress.context,
                                      &summary, &error)
                }
            }
        }
        guard status == SZStatusOK else {
            throw BridgeError.archiveError(status, &error, password: password ?? self.password)
        }
        return summary
    }

    // MARK: - Writing

    /// Writes a new archive carrying this one's items over, less `removed`, with
    /// `renames` applied and `added` appended.
    func write(removed: [UInt32],
               renames: [(index: UInt32, path: String)],
               added: [NewItem],
               to output: URL,
               settings: WriteSettings,
               progress: BridgeProgress) throws {
        try Self.write(source: handle, removed: removed, renames: renames, added: added,
                       to: output, settings: settings, progress: progress)
    }

    /// Writes a new archive from files on disk alone.
    static func create(added: [NewItem], to output: URL, settings: WriteSettings,
                       progress: BridgeProgress) throws {
        try SevenZipLibrary.ensureLoaded()
        try write(source: nil, removed: [], renames: [], added: added, to: output,
                  settings: settings, progress: progress)
    }

    struct NewItem {
        let archivePath: String
        let diskURL: URL
    }

    struct WriteSettings {
        /// 7-Zip's handler name, such as "zip", "7z" or "gzip".
        var formatName: String
        var level: Int
        var password: String?
        var zipEncryption: CompressionOptions.ZipEncryption
        var encryptHeaders: Bool
        var solid: Bool?
    }

    private static func write(source: OpaquePointer?,
                              removed: [UInt32],
                              renames: [(index: UInt32, path: String)],
                              added: [NewItem],
                              to output: URL,
                              settings: WriteSettings,
                              progress: BridgeProgress) throws {
        // The bridge holds on to these pointers only for the duration of the call.
        let strings = CStringArena()
        let newItems = added.map {
            SZNewItem(archivePath: strings.copy($0.archivePath), diskPath: strings.copy($0.diskURL.path))
        }
        let renameItems = renames.map { SZRename(index: $0.index, newPath: strings.copy($0.path)) }

        var error = SZError()
        let password = settings.password?.isEmpty == false ? settings.password : nil
        var options = SZWriteOptions(formatName: strings.copy(settings.formatName),
                                     level: Int32(settings.level),
                                     password: password.map(strings.copy),
                                     zipEncryption: strings.copy(settings.zipEncryption.rawValue),
                                     encryptHeaders: settings.encryptHeaders,
                                     solid: settings.solid.map { $0 ? 1 : 0 } ?? -1)

        let status = withExtendedLifetime((strings, progress)) {
            removed.withUnsafeBufferPointer { removedBuffer in
                renameItems.withUnsafeBufferPointer { renameBuffer in
                    newItems.withUnsafeBufferPointer { addedBuffer in
                        output.path.withCString { outputPath in
                            sz_write(source,
                                     removedBuffer.baseAddress, UInt32(removedBuffer.count),
                                     renameBuffer.baseAddress, UInt32(renameBuffer.count),
                                     addedBuffer.baseAddress, UInt32(addedBuffer.count),
                                     outputPath, &options,
                                     progress.callback, progress.context, &error)
                        }
                    }
                }
            }
        }
        guard status == SZStatusOK else {
            throw BridgeError.archiveError(status, &error, password: password)
        }
    }

    // MARK: - Helpers

    /// "-rw-r--r--" style, for the rare place a mode is worth showing.
    private static func modeString(_ mode: UInt32, link: Bool) -> String {
        let type: Character = link ? "l" : ((mode & 0o170000) == 0o040000 ? "d" : "-")
        let flags: [(UInt32, Character)] = [
            (0o400, "r"), (0o200, "w"), (0o100, "x"),
            (0o040, "r"), (0o020, "w"), (0o010, "x"),
            (0o004, "r"), (0o002, "w"), (0o001, "x"),
        ]
        return String(type) + String(flags.map { mode & $0.0 != 0 ? $0.1 : "-" })
    }
}

extension OverwriteMode {
    var bridgeValue: SZOverwrite {
        switch self {
        case .overwrite: return SZOverwriteReplace
        case .skip: return SZOverwriteSkip
        case .renameNew: return SZOverwriteRenameNew
        case .renameExisting: return SZOverwriteRenameExisting
        }
    }
}

/// Relays the bridge's progress to a Swift handler, a few times a second at most, and
/// turns cancellation into the `false` the bridge understands.
final class BridgeProgress: @unchecked Sendable {
    private let handler: ProgressHandler?
    private let cancellation: CancellationToken?
    private let lock = NSLock()
    private var lastReport: TimeInterval = 0
    /// Maps this step's 0...1 into a slice of the whole operation, for work done in
    /// several bridge calls such as unwrapping a .tar.gz before extracting it.
    private let offset: Double
    private let span: Double
    /// Consulted on every report; answering false stops the operation, as a cancel does.
    private let guardian: (() -> Bool)?

    init(handler: ProgressHandler?, cancellation: CancellationToken?,
         offset: Double = 0, span: Double = 1, guardian: (() -> Bool)? = nil) {
        self.handler = handler
        self.cancellation = cancellation
        self.offset = offset
        self.span = span
        self.guardian = guardian
    }

    /// The same progress, stopped as soon as `check` answers false.
    func guarded(by check: @escaping () -> Bool) -> BridgeProgress {
        BridgeProgress(handler: handler, cancellation: cancellation, offset: offset, span: span,
                       guardian: check)
    }

    /// A progress for the slice `offset..<offset + span` of the same operation.
    func slice(offset: Double, span: Double) -> BridgeProgress {
        BridgeProgress(handler: handler, cancellation: cancellation, offset: offset, span: span)
    }

    static var silent: BridgeProgress { BridgeProgress(handler: nil, cancellation: nil) }

    var callback: SZProgressCallback { bridgeProgressTrampoline }
    var context: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    func report(completed: UInt64, total: UInt64, path: UnsafePointer<CChar>?) -> Bool {
        if cancellation?.isCancelled == true { return false }
        if let guardian, !guardian() { return false }
        guard let handler else { return true }

        let now = ProcessInfo.processInfo.systemUptime
        let finished = total > 0 && completed >= total && span >= 1
        lock.lock()
        let due = finished || now - lastReport >= 0.05
        if due { lastReport = now }
        lock.unlock()
        guard due else { return true }

        let fraction = total > 0 ? offset + span * min(Double(completed) / Double(total), 1) : nil
        let file = path.map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 }
        handler(ArchiveProgress(fraction: fraction, currentFile: file))
        return true
    }
}

private let bridgeProgressTrampoline: SZProgressCallback = { context, completed, total, path in
    guard let context else { return true }
    return Unmanaged<BridgeProgress>.fromOpaque(context).takeUnretainedValue()
        .report(completed: completed, total: total, path: path)
}

/// Keeps C copies of Swift strings alive for the length of a bridge call.
final class CStringArena {
    private var pointers: [UnsafeMutablePointer<CChar>] = []

    func copy(_ string: String) -> UnsafePointer<CChar> {
        let pointer = strdup(string)!
        pointers.append(pointer)
        return UnsafePointer(pointer)
    }

    deinit {
        // Wipe before freeing, since one of these may be a password.
        for pointer in pointers {
            memset(pointer, 0, strlen(pointer))
            free(pointer)
        }
    }
}

func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) throws -> R) rethrows -> R {
    guard let string else { return try body(nil) }
    return try string.withCString(body)
}
