import AppKit
import JustArcCore

/// Drives the double-click path: unpack the archive, optionally reveal it,
/// then let the app quit. No main window is ever created.
@MainActor
final class QuickExtractCoordinator {
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

        // Disk images go through hdiutil, everything else through 7-Zip.
        let engine = EngineFactory.engine(for: archive)
        defer { engine.release(archive: archive) }

        // Step 0: the archive may be a cloud placeholder that is not on disk yet.
        do {
            try await downloadIfNeeded(archive)
        } catch {
            present(error: error, archive: archive)
            return
        }

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
            present(message: L("%@ is empty.", archive.lastPathComponent),
                    informative: L("There is nothing to extract."))
            return
        }
        guard confirmIfSuspicious(listing: listing, archive: archive) else { return }

        let plan = ExtractionPlan.make(archive: archive,
                                       into: parent,
                                       listing: listing,
                                       smartFolder: Preferences.smartFolder)

        // Step 2: a wrapper folder is created unique, so only extracting into a folder
        // that is already there can collide with its contents.
        let roots = EntryTree(entries: listing.entries).root.children.map(\.path)
        var resolution = ConflictPrompt.Resolution(folder: .merge, file: .renameNew)
        if !plan.createdWrapperFolder {
            guard let chosen = ConflictPrompt.resolve(entries: listing.entries,
                                                      roots: roots,
                                                      destination: plan.destination,
                                                      window: nil) else { return }
            resolution = chosen
        }

        // Step 3: extract, showing the progress panel.
        let cancellation = CancellationToken()
        let panel = ProgressWindowController(
            title: L("Extracting %@", archive.lastPathComponent),
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
            let outcome = try await extractWithPasswordRetry(engine: engine,
                                                             archive: archive,
                                                             listing: listing,
                                                             plan: plan,
                                                             roots: roots,
                                                             resolution: resolution,
                                                             password: &password,
                                                             cancellation: cancellation,
                                                             panel: panel)
            panel.finish()
            finishUp(archive: archive, plan: plan, outcome: outcome)
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

    private func extractWithPasswordRetry(engine: ArchiveEngine,
                                          archive: URL,
                                          listing: ArchiveListing,
                                          plan: ExtractionPlan,
                                          roots: [String],
                                          resolution: ConflictPrompt.Resolution,
                                          password: inout String?,
                                          cancellation: CancellationToken,
                                          panel: ProgressWindowController) async throws -> ExtractionOutcome {
        var attempt = 0
        while true {
            do {
                let job = ExtractionJob(archive: archive,
                                        destination: plan.destination,
                                        password: password,
                                        allEntries: listing.entries,
                                        selectedEntries: nil,
                                        roots: roots,
                                        folderConflicts: resolution.folderConflicts,
                                        folderResolution: resolution.folder,
                                        fileOverwrite: resolution.file)
                return try await ExtractionRunner.run(job, engine: engine,
                                                      cancellation: cancellation,
                                                      progress: { progress in
                                                          Task { @MainActor in panel.update(progress) }
                                                      })
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

    private func finishUp(archive: URL, plan: ExtractionPlan, outcome: ExtractionOutcome) {
        if outcome.extractedNothing, !outcome.skippedFolders.isEmpty {
            // Everything in the archive was skipped, so say so rather than silently
            // opening a folder that did not change.
            let alert = NSAlert()
            alert.messageText = L("Nothing was extracted from %@.", archive.lastPathComponent)
            alert.informativeText = L("The folders it contains were left as they were.")
            alert.addButton(withTitle: L("OK"))
            alert.runModal()
            return
        }

        if Preferences.moveArchiveToTrash {
            try? FileManager.default.trashItem(at: archive, resultingItemURL: nil)
        }
        if Preferences.revealInFinder {
            // A wrapper folder is the thing to show; otherwise show what was produced.
            var targets = outcome.producedItems
            if plan.createdWrapperFolder || targets.isEmpty {
                targets = [FileManager.default.fileExists(atPath: plan.revealTarget.path)
                    ? plan.revealTarget : plan.destination]
            }
            NSWorkspace.shared.activateFileViewerSelecting(targets)
        }
    }

    // MARK: - Helpers

    /// Shows a panel while a cloud provider fetches the archive, since that can be slow.
    private func downloadIfNeeded(_ archive: URL) async throws {
        guard CloudFile.status(of: archive).needsDownload else { return }

        let cancellation = CancellationToken()
        let panel = ProgressWindowController(
            title: L("Downloading %@", archive.lastPathComponent),
            cancellation: cancellation)
        panel.showWindow(nil)
        panel.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { panel.finish() }

        try await CloudFile.materialize(archive, cancellation: cancellation, progress: nil)
        if cancellation.isCancelled { throw ArchiveError.cancelled }
    }

    private func resolveDestinationParent(for archive: URL) -> URL? {
        if let folder = Preferences.destinationFolder(for: archive) { return folder }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("Extract")
        panel.message = L("Choose where to extract %@.", archive.lastPathComponent)
        panel.directoryURL = archive.deletingLastPathComponent()
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func confirmIfSuspicious(listing: ArchiveListing, archive: URL) -> Bool {
        let verdict = PathSafety.evaluate(listing: listing)
        guard verdict.isSuspicious else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("%@ expands to a very large amount of data.", archive.lastPathComponent)
        alert.informativeText = L("It contains %@ items totalling %@. Extract it anyway?",
                                  Formatting.count(verdict.entryCount),
                                  Formatting.bytes(verdict.expandedBytes))
        alert.addButton(withTitle: L("Extract"))
        alert.addButton(withTitle: L("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func present(error: Error, archive: URL) {
        Diagnostics.log("error shown for \(archive.lastPathComponent): \(error.localizedDescription)")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("JustArc could not extract %@.", archive.lastPathComponent)
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }

    private func present(message: String, informative: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }
}
