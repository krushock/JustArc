import AppKit
import JustArcCore

/// Lets a sandboxed JustArc write where it has to.
///
/// In the App Sandbox an app may touch only what the user has handed it: a file
/// opened from the Finder, a folder picked in an open or save panel. Extracting
/// beside an archive writes into a folder nobody picked, and so does a split
/// archive's second volume or the archive Quick Compress makes. Before any of that,
/// JustArc asks once for the folder, with an open panel, and keeps the answer as a
/// security-scoped bookmark, so that a folder granted once, or any folder inside it,
/// is never asked for again. The same bookmarks let Open Recent reopen an archive
/// after a restart.
///
/// Outside the sandbox, which is to say in the website edition, none of this does
/// anything.
@MainActor
final class FolderAccess {
    static let shared = FolderAccess(defaults: .standard, isSandboxed: Distribution.isSandboxed)

    private let defaults: UserDefaults
    private let isSandboxed: Bool
    private static let foldersKey = "GrantedFolders"
    private static let filesKey = "RememberedFiles"

    /// Asks the user for a folder; replaceable for tests. Returns what was chosen.
    var askForFolder: (_ folder: URL, _ message: String) -> URL? = FolderAccess.openPanel
    /// Says that the folder chosen does not cover the one needed; replaceable for tests.
    var refuse: (_ name: String) -> Void = { name in
        let alert = NSAlert()
        alert.messageText = L("“%@” is not inside the folder you chose.", name)
        alert.informativeText = L("JustArc still cannot save there. Choose the folder itself or one that contains it.")
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }
    /// Whether this process may write in a folder right now; replaceable for tests,
    /// whose process is not sandboxed and may write anywhere.
    var mayWrite: (URL) -> Bool = FolderAccess.probe

    /// Folders granted and being accessed, by their resolved path.
    private var granted: [String: URL] = [:]

    init(defaults: UserDefaults, isSandboxed: Bool) {
        self.defaults = defaults
        self.isSandboxed = isSandboxed
        guard isSandboxed else { return }
        for data in defaults.array(forKey: Self.foldersKey) as? [Data] ?? [] {
            if let folder = resolve(data) { granted[Self.key(folder)] = folder }
        }
    }

    // MARK: - Folders

    /// The folders the user has granted, for Settings.
    var grantedFolders: [URL] {
        granted.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Makes sure JustArc may write in `folder`, asking for it if it may not.
    /// Returns false when the user would not grant it, and nothing should be written.
    @discardableResult
    func ensure(_ folder: URL, reason: String) -> Bool {
        guard isSandboxed else { return true }
        if covering(folder) != nil || mayWrite(folder) { return true }

        Diagnostics.log("folder access: asking for \(folder.path)")
        let name = FileManager.default.displayName(atPath: folder.path)
        let message = L("%@ To allow it, choose Allow. Choosing a folder that contains “%@”, such as your home folder, covers every folder inside it, and JustArc will not ask again.", reason, name)
        guard let chosen = askForFolder(folder, message) else { return false }
        _ = chosen.startAccessingSecurityScopedResource()
        guard Self.contains(chosen, folder) else {
            chosen.stopAccessingSecurityScopedResource()
            refuse(name)
            return false
        }
        grant(chosen)
        Diagnostics.log("folder access: granted \(chosen.path)")
        return true
    }

    /// Adds a folder from Settings.
    func grant(_ folder: URL) {
        guard isSandboxed else { return }
        granted[Self.key(folder)] = folder
        save()
    }

    func revoke(_ folder: URL) {
        guard let existing = granted.removeValue(forKey: Self.key(folder)) else { return }
        existing.stopAccessingSecurityScopedResource()
        save()
    }

    private func covering(_ folder: URL) -> URL? {
        granted.values.first { Self.contains($0, folder) }
    }

    private func save() {
        let bookmarks = granted.values.compactMap {
            try? $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        defaults.set(bookmarks, forKey: Self.foldersKey)
    }

    // MARK: - Archives opened before

    /// Keeps the right to reopen an archive the user opened, for Open Recent.
    func remember(file: URL) {
        guard isSandboxed,
              let data = try? file.bookmarkData(options: .withSecurityScope,
                                                includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return }
        var files = defaults.dictionary(forKey: Self.filesKey) as? [String: Data] ?? [:]
        files[Self.key(file)] = data
        // Only as many as Open Recent can show.
        let recent = Set(RecentArchives.shared.urls.map(Self.key))
        files = files.filter { recent.contains($0.key) || $0.key == Self.key(file) }
        defaults.set(files, forKey: Self.filesKey)
    }

    /// Takes up the right to an archive opened before, so it can be opened again.
    func reopen(_ file: URL) {
        guard isSandboxed,
              covering(file.deletingLastPathComponent()) == nil,
              let data = (defaults.dictionary(forKey: Self.filesKey) as? [String: Data])?[Self.key(file)]
        else { return }
        _ = resolve(data)
    }

    // MARK: - Helpers

    private func resolve(_ data: Data) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return nil }
        return url
    }

    /// Paths are compared with links followed: in the sandbox, ~/Desktop as the
    /// system names it is a link from the app's container to the real one.
    private static func key(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func contains(_ outer: URL, _ inner: URL) -> Bool {
        let outerPath = key(outer), innerPath = key(inner)
        return innerPath == outerPath || innerPath.hasPrefix(outerPath.hasSuffix("/") ? outerPath : outerPath + "/")
    }

    /// Tries to create a file in the folder. Asking the file system is the only sure
    /// answer: the sandbox decides when something is opened, not when it is looked at.
    private static func probe(_ folder: URL) -> Bool {
        let path = folder.appendingPathComponent(".justarc-access-\(UUID().uuidString)").path
        let descriptor = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        unlink(path)
        return true
    }

    private static func openPanel(_ folder: URL, _ message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Allow")
        panel.message = message
        panel.directoryURL = folder
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
}
