import Foundation

public enum ArchiveError: LocalizedError, Sendable {
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

    public var errorDescription: String? {
        switch self {
        case .passwordRequired:
            return "This archive is password protected."
        case .wrongPassword:
            return "The password is incorrect."
        case .unsupportedFormat(let f):
            return "JustArc cannot read \(f) archives."
        case .notWritable(let f):
            return "JustArc cannot write \(f) archives. Save a copy in another format."
        case .engineFailed(let code, let message):
            return message.isEmpty ? "The archive engine failed with code \(code)." : message
        case .engineMissing(let path):
            return "The bundled archive engine is missing at \(path)."
        case .cancelled:
            return "The operation was cancelled."
        case .unsafeEntry(let p):
            return "The archive contains an unsafe path and was not extracted: \(p)"
        case .ioFailure(let m):
            return m
        case .externalToolMissing(let name, let hint):
            return "\(name) is not installed. \(hint)"
        }
    }

    public var isPasswordProblem: Bool {
        switch self {
        case .passwordRequired, .wrongPassword: return true
        default: return false
        }
    }
}
