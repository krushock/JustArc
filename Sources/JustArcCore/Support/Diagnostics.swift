import Foundation
import os

/// Engine-level logging. Read it with:
/// `log show --last 5m --predicate 'subsystem == "com.justarc.JustArc"'`, or set
/// JUSTARC_VERBOSE=1 and run the binary from a terminal.
public enum Diagnostics {
    public static let engine = Logger(subsystem: "com.justarc.JustArc", category: "engine")

    /// Set JUSTARC_VERBOSE=1 to mirror engine logging onto stderr, which is how the
    /// app is debugged when it is launched from a terminal.
    private static let echoesToStandardError =
        ProcessInfo.processInfo.environment["JUSTARC_VERBOSE"] == "1"

    public static func log(_ message: String) {
        engine.notice("\(message, privacy: .public)")
        guard echoesToStandardError else { return }
        FileHandle.standardError.write(Data("[justarc] \(message)\n".utf8))
    }
}
