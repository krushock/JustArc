import AppKit
import JustArcCore

/// Backs the entries JustArc adds to the Finder's Services menu.
///
/// Each handler receives the selected files on a pasteboard. The names here must match
/// the NSMessage values declared under NSServices in Info.plist.
@MainActor
final class ServicesProvider: NSObject {
    private let quickExtract: QuickExtractCoordinator
    private let openInBrowser: (URL) -> Void
    private let stageIntoNewWindow: ([URL]) -> Void
    private let engine = SevenZipEngine()

    init(quickExtract: QuickExtractCoordinator,
         openInBrowser: @escaping (URL) -> Void,
         stageIntoNewWindow: @escaping ([URL]) -> Void) {
        self.quickExtract = quickExtract
        self.openInBrowser = openInBrowser
        self.stageIntoNewWindow = stageIntoNewWindow
    }

    // MARK: - Service entry points

    @objc func compressSelection(_ pasteboard: NSPasteboard,
                                 userData: String?,
                                 error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let items = Self.fileURLs(from: pasteboard)
        guard !items.isEmpty else {
            error.pointee = "Select one or more files in the Finder first." as NSString
            return
        }
        Task { await compress(items: items, askForOptions: false) }
    }

    @objc func compressSelectionWithOptions(_ pasteboard: NSPasteboard,
                                            userData: String?,
                                            error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let items = Self.fileURLs(from: pasteboard)
        guard !items.isEmpty else {
            error.pointee = "Select one or more files in the Finder first." as NSString
            return
        }
        // Staging them into a new window lets the user pick the format and options.
        stageIntoNewWindow(items)
    }

    @objc func extractSelection(_ pasteboard: NSPasteboard,
                                userData: String?,
                                error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let archives = Self.fileURLs(from: pasteboard).filter { FormatRegistry.isArchive($0) }
        guard !archives.isEmpty else {
            error.pointee = "None of the selected files is an archive JustArc can read." as NSString
            return
        }
        quickExtract.enqueue(archives)
    }

    @objc func openSelection(_ pasteboard: NSPasteboard,
                             userData: String?,
                             error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let archives = Self.fileURLs(from: pasteboard).filter { FormatRegistry.isArchive($0) }
        guard !archives.isEmpty else {
            error.pointee = "None of the selected files is an archive JustArc can read." as NSString
            return
        }
        for archive in archives { openInBrowser(archive) }
    }

    // MARK: - Work

    private func compress(items: [URL], askForOptions: Bool) async {
        guard let format = FormatRegistry.format(forKey: Preferences.defaultFormatKey)
            ?? FormatRegistry.format(forKey: "zip") else { return }

        let parent = items[0].deletingLastPathComponent()
        let stem = items.count == 1
            ? (items[0].lastPathComponent as NSString).deletingPathExtension
            : parent.lastPathComponent
        let name = "\(stem.isEmpty ? "Archive" : stem).\(format.extensions[0])"
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
