import Foundation

public enum ArchiveError: LocalizedError, Sendable, Equatable {
    case passwordRequired
    case wrongPassword
    case unsupportedFormat(String)
    case notWritable(String)
    case engineFailed(code: Int32, message: String)
    case engineMissing(String)
    case cancelled
    case unsafeEntry(String)
    case ioFailure(String)
    case externalToolMissing(name: String, hint: String)
    /// A cloud provider holds the file and has not put it on disk yet.
    case notDownloaded(String)

    public var errorDescription: String? {
        switch self {
        case .passwordRequired:
            return L("This archive is password protected.")
        case .wrongPassword:
            return L("The password is incorrect.")
        case .unsupportedFormat(let f):
            return L("JustArc cannot read %@ archives.", f)
        case .notWritable(let f):
            return L("JustArc cannot write %@ archives. Save a copy in another format.", f)
        case .engineFailed(let code, let message):
            return message.isEmpty ? L("The archive engine failed with code %d.", code) : message
        case .engineMissing(let path):
            return L("The bundled archive engine is missing at %@.", path)
        case .cancelled:
            return L("The operation was cancelled.")
        case .unsafeEntry(let p):
            return L("The archive contains an unsafe path and was not extracted: %@", p)
        case .ioFailure(let m):
            return m
        case .externalToolMissing(let name, let hint):
            return L("%@ is not installed. %@", name, hint)
        case .notDownloaded(let message):
            return message
        }
    }

    /// Compared by case, not by message, so `error == .cancelled` reads naturally.
    public static func == (lhs: ArchiveError, rhs: ArchiveError) -> Bool {
        switch (lhs, rhs) {
        case (.passwordRequired, .passwordRequired),
             (.wrongPassword, .wrongPassword),
             (.cancelled, .cancelled):
            return true
        case let (.unsupportedFormat(a), .unsupportedFormat(b)),
             let (.notWritable(a), .notWritable(b)),
             let (.engineMissing(a), .engineMissing(b)),
             let (.unsafeEntry(a), .unsafeEntry(b)),
             let (.ioFailure(a), .ioFailure(b)):
            return a == b
        case let (.engineFailed(codeA, messageA), .engineFailed(codeB, messageB)):
            return codeA == codeB && messageA == messageB
        case let (.externalToolMissing(nameA, hintA), .externalToolMissing(nameB, hintB)):
            return nameA == nameB && hintA == hintB
        case let (.notDownloaded(a), .notDownloaded(b)):
            return a == b
        default:
            return false
        }
    }

    public var isPasswordProblem: Bool {
        switch self {
        case .passwordRequired, .wrongPassword: return true
        default: return false
        }
    }
}
