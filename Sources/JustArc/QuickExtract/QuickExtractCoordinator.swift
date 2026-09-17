import AppKit
import JustArcCore

/// Drives the double-click path: unpack the archive, optionally reveal it,
/// then let the app quit. No main window is ever created.
@MainActor
final class QuickExtractCoordinator {
    private let engine = SevenZipEngine()
    private var queue: [URL] = []
    private var isRunning = false

    var onAllJobsFinished: (() -> Void)?

    var hasActiveJobs: Bool { isRunning || !queue.isEmpty }

    func enqueue(_ archives: [URL]) {
        queue.append(contentsOf: archives)
        guard !isRunning else { return }
        Task { await drain() }
    }

    private func drain() async {
        isRunning = true
        while !queue.isEmpty {
            let archive = queue.removeFirst()
            await process(archive)
        }
        isRunning = false
        onAllJobsFinished?()
    }

    private func process(_ archive: URL) async {
        guard let parent = resolveDestinationParent(for: archive) else { return }

        // Step 1: read the table of contents, asking for a password if the archive needs one.
        var password: String? = KeychainStore.password(for: archive)
        var listing: ArchiveListing
        var attempt = 0
        while true {
            do {
                listing = try await engine.list(archive: archive, password: password, encodingCodePage: nil)
                break
            } catch let error as ArchiveError where error.isPasswordProblem {
                guard let response = PasswordPrompt.ask(archiveName: archive.lastPathComponent,
                                                        window: nil,
                                                        retry: attempt > 0) else { return }
                password = response.password
                if response.rememberInKeychain {
                    KeychainStore.save(password: response.password, for: archive)
                }
                attempt += 1
            } catch {
                present(error: error, archive: archive)
                return
            }
        }

        guard !listing.entries.isEmpty else {
            present(message: "\(archive.lastPathComponent) is empty.",
                    informative: "There is nothing to extract.")
            return
        }
        guard confirmIfSuspicious(listing: listing, archive: archive) else { return }

        let plan = ExtractionPlan.make(archive: archive,
                                       into: parent,
                                       listing: listing,
                                       smartFolder: Preferences.smartFolder)

        // Step 2: extract, showing the progress panel.
        let cancellation = CancellationToken()
        let panel = ProgressWindowController(
            title: "Extracting \(archive.lastPathComponent)",
            cancellation: cancellation)
        panel.showWindow(nil)
        panel.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Entries may be encrypted even when the header was readable without a password.
        if listing.entries.contains(where: \.isEncrypted), password == nil {
            guard let response = PasswordPrompt.ask(archiveName: archive.lastPathComponent,
                                                    window: panel.window,
                                                    retry: false) else {
                panel.finish()
                return
            }
            password = response.password
            if response.rememberInKeychain {
                KeychainStore.save(password: response.password, for: archive)
            }
        }

        do {
            try await extractWithPasswordRetry(archive: archive,
                                               plan: plan,
                                               password: &password,
                                               cancellation: cancellation,
                                               panel: panel)
            panel.finish()
            finishUp(archive: archive, plan: plan)
        } catch let error as ArchiveError where error == .cancelled {
            panel.finish()
            if plan.createdWrapperFolder {
                try? FileManager.default.removeItem(at: plan.destination)
            }
        } catch {
            panel.finish()
            present(error: error, archive: archive)
        }
    }

    private func extractWithPasswordRetry(archive: URL,
                                          plan: ExtractionPlan,
                                          password: inout String?,
                                          cancellation: CancellationToken,
                                          panel: ProgressWindowController) async throws {
        var attempt = 0
        while true {
            do {
                let current = password
                try await engine.extract(archive: archive,
                                         entries: nil,
                                         to: plan.destination,
                                         password: current,
                                         overwrite: .renameNew,
                                         flattenPaths: false,
                                         cancellation: cancellation,
                                         progress: { progress in
                                             Task { @MainActor in panel.update(progress) }
                                         })
                return
            } catch let error as ArchiveError where error.isPasswordProblem {
                guard attempt < 3,
                      let response = PasswordPrompt.ask(archiveName: archive.lastPathComponent,
                                                        window: panel.window,
                                                        retry: true) else { throw error }
                password = response.password
                if response.rememberInKeychain {
                    KeychainStore.save(password: response.password, for: archive)
                }
                attempt += 1
            }
        }
    }

    private func finishUp(archive: URL, plan: ExtractionPlan) {
        if Preferences.moveArchiveToTrash {
            try? FileManager.default.trashItem(at: archive, resultingItemURL: nil)
        }
        if Preferences.revealInFinder {
            let target = FileManager.default.fileExists(atPath: plan.revealTarget.path)
                ? plan.revealTarget
                : plan.destination
            NSWorkspace.shared.activateFileViewerSelecting([target])
        }
    }

    // MARK: - Helpers

    private func resolveDestinationParent(for archive: URL) -> URL? {
        if let folder = Preferences.destinationFolder(for: archive) { return folder }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Extract"
        panel.message = "Choose where to extract \(archive.lastPathComponent)."
        panel.directoryURL = archive.deletingLastPathComponent()
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func confirmIfSuspicious(listing: ArchiveListing, archive: URL) -> Bool {
        let verdict = PathSafety.evaluate(listing: listing)
        guard verdict.isSuspicious else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(archive.lastPathComponent) expands to a very large amount of data."
        alert.informativeText = """
        It contains \(Formatting.count(verdict.entryCount)) items \
        totalling \(Formatting.bytes(verdict.expandedBytes)).
        Extract it anyway?
        """
        alert.addButton(withTitle: "Extract")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func present(error: Error, archive: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "JustArc could not extract \(archive.lastPathComponent)."
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func present(message: String, informative: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

extension ArchiveError: @retroactive Equatable {
    public static func == (lhs: ArchiveError, rhs: ArchiveError) -> Bool {
        switch (lhs, rhs) {
        case (.cancelled, .cancelled), (.passwordRequired, .passwordRequired),
             (.wrongPassword, .wrongPassword):
            return true
        default:
            return false
        }
    }
}
