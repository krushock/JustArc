import AppKit
import JustArcCore

/// Notices when a file that was opened out of an archive is edited in another app,
/// so the archive can be updated. Checking happens when JustArc comes back to the
/// front, which survives the atomic save-and-replace that most editors perform and
/// that defeats a file descriptor watch.
@MainActor
final class EditedFileWatcher {
    struct Tracked {
        let localURL: URL
        let entryPath: String
        var stamp: Stamp
    }

    struct Stamp: Equatable {
        let modified: Date?
        let size: UInt64

        static func read(_ url: URL) -> Stamp? {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                return nil
            }
            return Stamp(modified: attributes[.modificationDate] as? Date,
                         size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0)
        }
    }

    private var tracked: [String: Tracked] = [:]
    private nonisolated(unsafe) var activationToken: NSObjectProtocol?

    /// Called with the files that changed since they were opened or last acknowledged.
    var onChangesDetected: (([Tracked]) -> Void)?

    init() {
        activationToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkForChanges() }
            }
    }

    deinit {
        if let activationToken { NotificationCenter.default.removeObserver(activationToken) }
    }

    var isTrackingAnything: Bool { !tracked.isEmpty }

    func track(localURL: URL, entryPath: String) {
        guard let stamp = Stamp.read(localURL) else { return }
        tracked[entryPath] = Tracked(localURL: localURL, entryPath: entryPath, stamp: stamp)
    }

    /// Records the file's current state as the new baseline, after it has been written back
    /// or after the user chose to leave the archive alone.
    func acknowledge(entryPath: String) {
        guard var entry = tracked[entryPath],
              let stamp = Stamp.read(entry.localURL) else {
            tracked.removeValue(forKey: entryPath)
            return
        }
        entry.stamp = stamp
        tracked[entryPath] = entry
    }

    func stopTracking(entryPath: String) {
        tracked.removeValue(forKey: entryPath)
    }

    func removeAll() {
        tracked.removeAll()
    }

    /// Exposed so the browser can also check at moments of its own choosing.
    func checkForChanges() {
        var changed: [Tracked] = []
        for (path, entry) in tracked {
            guard let current = Stamp.read(entry.localURL) else {
                // The file was deleted; there is nothing left to write back.
                tracked.removeValue(forKey: path)
                continue
            }
            if current != entry.stamp { changed.append(entry) }
        }
        guard !changed.isEmpty else { return }
        onChangesDetected?(changed.sorted { $0.entryPath < $1.entryPath })
    }
}
