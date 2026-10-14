import AppKit
import JustArcCore

/// Backs the entries JustArc adds to the Finder's Services menu.
///
/// Each handler receives the selected files on a pasteboard. The names here must match
/// the NSMessage values declared under NSServices in Info.plist.
@MainActor
final class ServicesProvider: NSObject {
    private let quickExtract: QuickExtractCoordinator
    private let beginJob: () -> Void
    private let endJob: () -> Void
    private let openInBrowser: (URL) -> Void
    private let stageIntoNewWindow: ([URL]) -> Void
    private let engine = SevenZipEngine()

    init(quickExtract: QuickExtractCoordinator,
         beginJob: @escaping () -> Void,
         endJob: @escaping () -> Void,
         openInBrowser: @escaping (URL) -> Void,
         stageIntoNewWindow: @escaping ([URL]) -> Void) {
        self.quickExtract = quickExtract
        self.beginJob = beginJob
        self.endJob = endJob
        self.openInBrowser = openInBrowser
        self.stageIntoNewWindow = stageIntoNewWindow
    }

    // MARK: - Service entry points

    /// "Quick Compress with JustArc": an archive beside the selection, in the default
    /// format, with nothing asked.
    @objc func compressSelection(_ pasteboard: NSPasteboard,
                                 userData: String?,
                                 error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let items = Self.fileURLs(from: pasteboard)
        guard !items.isEmpty else {
            error.pointee = L("Select one or more files in the Finder first.") as NSString
            return
        }
        beginJob()
        Task {
            await compress(items: items, askForOptions: false)
            endJob()
        }
    }

    /// "Compress with JustArc": a new archive window with the selection already in
    /// it, where the format, password and the rest are chosen when it is saved.
    @objc func compressSelectionInWindow(_ pasteboard: NSPasteboard,
                                         userData: String?,
                                         error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let items = Self.fileURLs(from: pasteboard)
        guard !items.isEmpty else {
            error.pointee = L("Select one or more files in the Finder first.") as NSString
            return
        }
        // Staging them into a new window lets the user pick the format and options.
        beginJob()
        stageIntoNewWindow(items)
        endJob()
    }

    @objc func extractSelection(_ pasteboard: NSPasteboard,
                                userData: String?,
                                error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let archives = Self.fileURLs(from: pasteboard).filter { FormatRegistry.isArchive($0) }
        guard !archives.isEmpty else {
            error.pointee = L("None of the selected files is an archive JustArc can read.") as NSString
            return
        }
        beginJob()
        for archive in archives { RecentsRecorder.note(archive) }
        quickExtract.enqueue(archives)
        endJob()
    }

    @objc func openSelection(_ pasteboard: NSPasteboard,
                             userData: String?,
                             error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let archives = Self.fileURLs(from: pasteboard).filter { FormatRegistry.isArchive($0) }
        guard !archives.isEmpty else {
            error.pointee = L("None of the selected files is an archive JustArc can read.") as NSString
            return
        }
        beginJob()
        for archive in archives { openInBrowser(archive) }
        NSApp.activate(ignoringOtherApps: true)
        endJob()
    }

    // MARK: - Work

    private func compress(items: [URL], askForOptions: Bool) async {
        guard var format = FormatRegistry.format(forKey: Preferences.defaultFormatKey)
            ?? FormatRegistry.format(forKey: "zip") else { return }
        // GZip, BZip2 and XZ each hold one file. Asked to compress a folder or
        // several things, the tar form of the same compression is what was meant.
        let tarForms = ["gzip": "tgz", "bzip2": "tbz2", "xz": "txz"]
        let isOneFile = items.count == 1
            && (try? items[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
        if !isOneFile, let tar = tarForms[format.key].flatMap(FormatRegistry.format(forKey:)) {
            format = tar
        }

        let parent = items[0].deletingLastPathComponent()
        guard FolderAccess.shared.ensure(parent, reason: L("JustArc needs your permission to save the archive in this folder.")) else { return }
        let stem = items.count == 1
            ? (items[0].lastPathComponent as NSString).deletingPathExtension
            : parent.lastPathComponent
        let name = "\(stem.isEmpty ? L("Archive") : stem).\(format.extensions[0])"
        let destination = PathSafety.uniqueURL(for: parent.appendingPathComponent(name))

        let options = CompressionOptions(formatKey: format.key,
                                         level: Preferences.defaultLevel,
                                         excludeMacMetadata: Preferences.excludeMacMetadata)

        let cancellation = CancellationToken()
        let panel = ProgressWindowController(title: L("Creating %@", destination.lastPathComponent),
                                             cancellation: cancellation)
        panel.showWindow(nil)
        panel.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        do {
            try await CloudFile.materializeAll(items, cancellation: cancellation,
                                               progress: { progress in
                                                   Task { @MainActor in panel.update(progress) }
                                               })
            let writer = EngineFactory.engine(for: destination)
            try await writer.create(archive: destination, items: items, options: options,
                                    cancellation: cancellation,
                                    progress: { progress in
                                        Task { @MainActor in panel.update(progress) }
                                    })
            panel.finish()
            if Preferences.revealInFinder {
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            }
        } catch let archiveError as ArchiveError where archiveError == .cancelled {
            panel.finish()
            try? FileManager.default.removeItem(at: destination)
        } catch {
            panel.finish()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L("JustArc could not create %@.", destination.lastPathComponent)
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: L("OK"))
            alert.runModal()
        }
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        return urls ?? []
    }
}
