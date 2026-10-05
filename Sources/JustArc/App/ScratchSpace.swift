import Foundation

/// Where files opened or previewed out of archives are kept, some of them decrypted.
///
/// Each running copy of JustArc has a folder of its own, named for its process, so
/// that one copy starting or quitting never sweeps away what another is using. A
/// folder whose process is gone was left by a crash or a kill, and is cleared at the
/// next launch.
enum ScratchSpace {
    private static let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("JustArc", isDirectory: true)

    static let root: URL = base.appendingPathComponent(String(ProcessInfo.processInfo.processIdentifier),
                                                       isDirectory: true)

    /// A fresh folder for one window.
    static func makeWindowFolder() -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func removeOwn() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Clears what processes that no longer exist left behind.
    static func removeAbandoned() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        for name in names {
            // kill with signal 0 only asks whether the process is there.
            if let pid = pid_t(name), pid != ProcessInfo.processInfo.processIdentifier,
               kill(pid, 0) == 0 || errno == EPERM {
                continue
            }
            if name == String(ProcessInfo.processInfo.processIdentifier) { continue }
            try? FileManager.default.removeItem(at: base.appendingPathComponent(name))
        }
    }
}
