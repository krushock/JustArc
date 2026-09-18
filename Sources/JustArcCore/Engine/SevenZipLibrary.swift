import Foundation
import SevenZipBridge

/// Loads 7-Zip's format library into the process once, and answers questions about it.
public enum SevenZipLibrary {
    private static let lock = NSLock()
    private static var loadError: ArchiveError?
    private static var attempted = false

    /// Loads the library on first use. Throws the same error on every later call if
    /// loading failed, rather than retrying on each operation.
    public static func ensureLoaded() throws {
        lock.lock()
        defer { lock.unlock() }
        if sz_is_loaded() { return }
        if attempted, let loadError { throw loadError }
        attempted = true

        guard let url = EngineLocator.sevenZipLibrary else {
            let error = ArchiveError.engineMissing("Contents/Frameworks/\(EngineLocator.sevenZipLibraryName)")
            loadError = error
            throw error
        }
        var status = SZError()
        guard sz_load(url.path, &status) == SZStatusOK else {
            let error = ArchiveError.engineMissing(url.path + " (" + BridgeError.message(from: &status) + ")")
            loadError = error
            throw error
        }
    }

    public static var isAvailable: Bool {
        (try? ensureLoaded()) != nil
    }

    /// The 7-Zip version the bridge was built from.
    public static var version: String {
        String(cString: sz_version())
    }

    /// Every format the loaded library can read, by 7-Zip's own name.
    public static var formatNames: [String] {
        guard (try? ensureLoaded()) != nil else { return [] }
        return (0..<sz_format_count()).map { String(cString: sz_format_name($0)) }
    }

    /// Formats the library can also write.
    public static var writableFormatNames: [String] {
        guard (try? ensureLoaded()) != nil else { return [] }
        return (0..<sz_format_count()).filter { sz_format_can_write($0) }
            .map { String(cString: sz_format_name($0)) }
    }
}

/// Turns the bridge's status codes into the app's errors.
enum BridgeError {
    static func message(from error: inout SZError) -> String {
        withUnsafeBytes(of: &error.message) { buffer in
            let bytes = buffer.bindMemory(to: CChar.self)
            return String(cString: bytes.baseAddress!)
        }
    }

    static func archiveError(_ status: SZStatus, _ error: inout SZError, password: String?) -> ArchiveError {
        let message = message(from: &error)
        switch status {
        case SZStatusPasswordRequired:
            return .passwordRequired
        case SZStatusWrongPassword:
            return (password?.isEmpty ?? true) ? .passwordRequired : .wrongPassword
        case SZStatusCancelled:
            return .cancelled
        case SZStatusUnsafePath:
            return .unsafeEntry(message)
        case SZStatusLibraryMissing:
            return .engineMissing(message)
        default:
            return .engineFailed(code: Int32(status.rawValue), message: message)
        }
    }
}
