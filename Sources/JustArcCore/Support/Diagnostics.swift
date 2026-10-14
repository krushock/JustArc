import Foundation
import os

/// Engine-level logging. Read it with:
/// `log show --last 5m --predicate 'subsystem == "com.justarc.JustArc"'`, or set
/// JUSTARC_VERBOSE=1 and run the binary from a terminal.
///
/// What is interpolated into a message is private unless marked `public:`. The
/// system log is kept for days and goes into every sysdiagnose, and the names of
/// someone's files and folders have no business there. Counts, exit codes and the
/// like are what make a log useful, and are marked public where they are logged.
public enum Diagnostics {
    public static let engine = Logger(subsystem: "com.justarc.JustArc", category: "engine")

    /// Set JUSTARC_VERBOSE=1 to mirror engine logging onto stderr, in full, which is
    /// how the app is debugged when it is launched from a terminal.
    private static let echoesToStandardError =
        ProcessInfo.processInfo.environment["JUSTARC_VERBOSE"] == "1"

    public static func log(_ message: DiagnosticsMessage) {
        if message.hasPrivateParts {
            // In full only where private data is shown, such as on a Mac set up for
            // debugging; elsewhere the line reads with "<private>" in its place.
            engine.notice("\(message.redacted, privacy: .public) — \(message.full, privacy: .private)")
        } else {
            engine.notice("\(message.full, privacy: .public)")
        }
        guard echoesToStandardError else { return }
        FileHandle.standardError.write(Data("[justarc] \(message.full)\n".utf8))
    }
}

/// A log line, written as a string literal with interpolations. `\(name)` is kept
/// private; `\(public: count)` is logged as it is.
public struct DiagnosticsMessage: ExpressibleByStringInterpolation {
    public struct StringInterpolation: StringInterpolationProtocol {
        fileprivate var redacted = ""
        fileprivate var full = ""
        fileprivate var hasPrivateParts = false

        public init(literalCapacity: Int, interpolationCount: Int) {}

        public mutating func appendLiteral(_ literal: String) {
            redacted += literal
            full += literal
        }

        /// File names, paths, error descriptions: anything that may say what is on
        /// someone's disk.
        public mutating func appendInterpolation<T>(_ value: T) {
            redacted += "<private>"
            full += String(describing: value)
            hasPrivateParts = true
        }

        public mutating func appendInterpolation<T>(public value: T) {
            let text = String(describing: value)
            redacted += text
            full += text
        }
    }

    let redacted: String
    let full: String
    let hasPrivateParts: Bool

    public init(stringLiteral value: String) {
        redacted = value
        full = value
        hasPrivateParts = false
    }

    public init(stringInterpolation: StringInterpolation) {
        redacted = stringInterpolation.redacted
        full = stringInterpolation.full
        hasPrivateParts = stringInterpolation.hasPrivateParts
    }
}
