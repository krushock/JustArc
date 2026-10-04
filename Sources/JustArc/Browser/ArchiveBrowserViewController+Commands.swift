import AppKit
import QuickLookUI
import UniformTypeIdentifiers
import JustArcCore

// MARK: - Commands

extension ArchiveBrowserViewController {

    // MARK: Adding

    @objc func addFiles(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = L("Add")
        panel.message = currentFolderPath.isEmpty
            ? L("Choose files or folders to add to %@.", session.displayName)
            : L("Choose files or folders to add to %@ in %@.",
                (currentFolderPath as NSString).lastPathComponent, session.displayName)
        guard panel.runModal() == .OK else { return }
        add(items: panel.urls)
    }

    /// Adds files to the archive.
    /// - Parameter folder: where inside the archive they go. Nil means the folder
    ///   the list is showing, which is where someone looking at it expects them.
    func add(items: [URL], into folder: String? = nil) {
        guard !items.isEmpty else { return }
        let folder = folder ?? currentFolderPath
        guard !session.isReadOnly else {
            present(ArchiveError.notWritable(session.format?.displayName ?? L("this format")))
            return
        }
        guard !isBusy else { return }

        // An untitled window just stages the files until the user saves.
        guard let archiveURL = session.archiveURL else {
            session.stage(items: items, into: folder)
            reloadFromSession()
            return
        }

        // What is added replaces what has the same path, so a copy of the old file
        // that is open for editing no longer stands for anything in the archive.
        for item in items {
            editedFiles.stopTracking(under: ArchivePath.join(folder, item.lastPathComponent))
        }
        Task {
            let done = await runOperation(title: L("Adding to %@", session.displayName)) { cancellation, progress in
                // Files dragged in from a cloud folder have to be fetched first.
                try await CloudFile.materializeAll(items, cancellation: cancellation, progress: progress)
                try await self.withPasswordRetry {
                    try await self.engine.add(items: items, to: archiveURL, into: folder,
                                              options: self.currentCompressionOptions(),
                                              cancellation: cancellation, progress: progress)
                }
            }
            if done != nil { loadArchive() }
        }
    }

    // MARK: Extracting

    func extractSelectedOrAll() {
        selectedEntriesForCommand().isEmpty ? extractAll(nil) : extractSelected(nil)
    }

    @objc func extractSelected(_ sender: Any?) {
        let nodes = selectedNodesForCommand()
        let entries = selectedEntriesForCommand()
        guard !entries.isEmpty else {
            extractAll(nil)
            return
        }
        // The nodes are what the user picked; the entries are every file underneath them.
        extract(entries: entries,
                revealing: nodes.map(\.path),
                label: L("Extracting %d items", entries.count))
    }

    @objc func extractAll(_ sender: Any?) {
        extract(entries: nil,
                revealing: session.tree.root.children.map(\.path),
                label: L("Extracting %@", session.displayName))
    }

    private func extract(entries: [ArchiveEntry]?, revealing archivePaths: [String], label: String) {
        guard let archiveURL = session.archiveURL else {
            present(ArchiveError.ioFailure(L("Save this archive before extracting from it.")))
            return
        }
        guard let destination = chooseFolder(prompt: L("Extract"),
                                             message: L("Choose where to extract the selected items."),
                                             startAt: archiveURL.deletingLastPathComponent())
        else { return }

        // Everything that would be written, so collisions can be found up front.
        let candidates = entries ?? session.listing.entries
        guard let resolution = ConflictPrompt.resolve(entries: candidates,
                                                      roots: archivePaths,
                                                      destination: destination,
                                                      window: view.window) else { return }

        let allEntries = session.listing.entries
        Task {
            let outcome = await runOperation(title: label) { cancellation, progress in
                try await self.withPasswordRetry {
                    let job = ExtractionJob(archive: archiveURL,
                                            destination: destination,
                                            password: self.session.password,
                                            allEntries: allEntries,
                                            selectedEntries: entries,
                                            roots: archivePaths,
                                            folderConflicts: resolution.folderConflicts,
                                            folderResolution: resolution.folder,
                                            fileOverwrite: resolution.file)
                    return try await ExtractionRunner.run(job, engine: self.engine,
                                                          cancellation: cancellation, progress: progress)
                }
            }
            guard let outcome else { return }

            if outcome.extractedNothing, !outcome.skippedFolders.isEmpty {
                let alert = NSAlert()
                alert.messageText = L("Nothing was extracted.")
                alert.informativeText = L("The folders it contains were left as they were.")
                alert.addButton(withTitle: L("OK"))
                alert.runModal()
                return
            }
            if Preferences.revealInFinder {
                let targets = outcome.producedItems.isEmpty ? [destination] : outcome.producedItems
                NSWorkspace.shared.activateFileViewerSelecting(targets)
            }
        }
    }

    // MARK: Opening and previewing

    @objc func openSelectedFile(_ sender: Any?) {
        guard let node = selectedNodesForCommand().first else { return }
        if node.isDirectory {
            navigateToNode(node)
            return
        }
        // A copy that can be written back is kept and watched; from an archive that
        // cannot be changed the file is only there to be looked at.
        let editable = session.archiveURL != nil && session.canModifyContents
            && session.stagedSource(for: node.path) == nil
        Task {
            guard let url = await materialize(node: node, forEditing: editable) else { return }
            if editable, editedFiles.localURL(for: node.path) == nil {
                editedFiles.track(localURL: url, entryPath: node.path)
            }
            NSWorkspace.shared.open(url)
        }
    }

    /// Asks whether edits made in another app should go back into the archive.
    func offerToUpdate(_ changed: [EditedFileWatcher.Tracked]) {
        guard let archiveURL = session.archiveURL, session.canModifyContents else { return }
        // Asked again the next time the app comes forward, once the archive is free
        // and the question already on screen has been answered.
        guard !isBusy, !isOfferingUpdate else { return }
        isOfferingUpdate = true
        defer { isOfferingUpdate = false }

        let alert = NSAlert()
        alert.messageText = changed.count == 1
            ? L("%@ was edited outside JustArc.",
                (changed[0].entryPath as NSString).lastPathComponent)
            : L("%d files opened from this archive were edited outside JustArc.", changed.count)
        alert.informativeText = changed.count == 1
            ? L("Update %@ with the edited file?", session.displayName)
            : L("Update %@ with the edited files?", session.displayName) + "\n\n"
              + changed.map(\.entryPath).joined(separator: "\n")
        alert.addButton(withTitle: L("Update Archive"))
        alert.addButton(withTitle: L("Keep Unchanged"))
        guard alert.runModal() == .alertFirstButtonReturn else {
            for entry in changed { editedFiles.acknowledge(entryPath: entry.entryPath) }
            return
        }

        Task {
            let done = await runOperation(title: L("Updating %@", session.displayName)) { cancellation, progress in
                for entry in changed {
                    try await self.withPasswordRetry {
                        try await self.engine.update(fileAt: entry.localURL,
                                                     entryPath: entry.entryPath,
                                                     in: archiveURL,
                                                     options: self.currentCompressionOptions(),
                                                     cancellation: cancellation,
                                                     progress: progress)
                    }
                    // Only what was actually written back stops being "edited"; a
                    // failure partway leaves the rest to be offered again.
                    await MainActor.run { self.editedFiles.acknowledge(entryPath: entry.entryPath) }
                }
            }
            if done != nil { loadArchive() }
        }
    }

    @objc func toggleQuickLook(_ sender: Any?) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        loadPreviewItems(showing: panel, thenOpen: true)
    }

    /// Extracts one entry into this window's scratch space so it can be opened,
    /// previewed or dragged out.
    ///
    /// - Parameters:
    ///   - forEditing: hand back the copy another app may be editing, making one if
    ///     there is none. Otherwise the file is extracted afresh after every change
    ///     to the archive, so what is shown is what the archive holds.
    ///   - askingForPassword: whether a missing or wrong password may put up the
    ///     prompt. A drag in progress is no moment for a dialog.
    func materialize(node: EntryTree.Node, quiet: Bool = false, forEditing: Bool = false,
                     askingForPassword: Bool = true) async -> URL? {
        if let staged = session.stagedSource(for: node.path) { return staged }
        guard let archiveURL = session.archiveURL, let entry = node.entry else { return nil }

        if forEditing, let open = editedFiles.localURL(for: entry.path),
           FileManager.default.fileExists(atPath: open.path) {
            return open
        }
        let root = forEditing ? editingRoot() : viewingRoot()
        let cached = root.appendingPathComponent(entry.path)
        if !forEditing, FileManager.default.fileExists(atPath: cached.path) { return cached }

        do {
            let extract = {
                try await self.engine.extractSingle(archive: archiveURL, entry: entry, to: root,
                                                    password: self.session.password)
            }
            return askingForPassword ? try await withPasswordRetry(extract) : try await extract()
        } catch let error as ArchiveError where error == .cancelled {
            return nil
        } catch {
            if !quiet { present(error) }
            return nil
        }
    }

    /// Runs work that needs the archive's password, asking for it when the engine
    /// says it is missing or wrong, and trying again.
    ///
    /// A zip lists without its password, so the first sign that one is needed is a
    /// file failing to decode. A password remembered for this path is tried once
    /// before anyone is asked, and forgotten if it no longer works; one typed in is
    /// only put in the keychain after it has decoded something.
    func withPasswordRetry<T>(_ work: () async throws -> T) async throws -> T {
        var attempt = 0
        var triedKeychain = false
        var usingKeychainPassword = false
        while true {
            do {
                let result = try await work()
                if session.listing.containsEncryptedEntries { rememberPasswordIfProven() }
                return result
            } catch let error as ArchiveError where error.isPasswordProblem {
                guard let url = session.archiveURL else { throw error }
                if !triedKeychain {
                    triedKeychain = true
                    if let stored = KeychainStore.password(for: url), stored != session.password {
                        session.password = stored
                        usingKeychainPassword = true
                        continue
                    }
                }
                if usingKeychainPassword {
                    KeychainStore.remove(for: url)
                    usingKeychainPassword = false
                    session.password = nil
                }
                guard let response = PasswordPrompt.ask(archiveName: session.displayName,
                                                        window: view.window,
                                                        retry: attempt > 0 || session.password != nil) else {
                    passwordToRemember = nil
                    throw ArchiveError.cancelled
                }
                session.password = response.password
                passwordToRemember = response.rememberInKeychain ? response.password : nil
                attempt += 1
            }
        }
    }

    /// Extracts a folder and everything in it into this window's scratch space, for
    /// dragging out to the Finder.
    func materializeFolder(node: EntryTree.Node) async -> URL? {
        if let staged = session.stagedSource(for: node.path) { return staged }
        guard let archiveURL = session.archiveURL else { return nil }

        // A drag-specific spot, so files opened for editing earlier are not overwritten.
        let root = scratchRoot().appendingPathComponent("drag-\(UUID().uuidString)")
        let produced = root.appendingPathComponent(node.path)
        do {
            let entries = node.descendantEntries()
            if !entries.isEmpty {
                try await engine.extract(archive: archiveURL, entries: entries, to: root,
                                         password: session.password, overwrite: .overwrite,
                                         flattenPaths: false, cancellation: nil, progress: nil)
            }
            // A folder the archive only implies, or an empty one, still has to exist.
            try FileManager.default.createDirectory(at: produced, withIntermediateDirectories: true)
            return produced
        } catch {
            Diagnostics.log("drag out: \(node.path) failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Deleting and renaming

    @objc func deleteSelected(_ sender: Any?) {
        let nodes = selectedNodesForCommand()
        guard !nodes.isEmpty else { return }
        guard !session.isReadOnly else {
            present(ArchiveError.notWritable(session.format?.displayName ?? L("this format")))
            return
        }
        guard !isBusy else { return }

        // Nothing has been written yet, so taking files back out of a new archive
        // changes nothing on disk and needs no warning.
        guard let archiveURL = session.archiveURL else {
            session.markForDeletion(nodes.map(\.path))
            reloadFromSession()
            return
        }

        let alert = NSAlert()
        alert.messageText = nodes.count == 1
            ? L("Delete %@ from the archive?", nodes[0].name)
            : L("Delete %d items from the archive?", nodes.count)
        alert.informativeText = L("This changes the archive on disk and cannot be undone.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Delete"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let entries = nodes.flatMap { $0.descendantEntries() }
        for node in nodes { editedFiles.stopTracking(under: node.path) }
        Task {
            let done = await runOperation(title: L("Deleting from %@", session.displayName),
                                          cancellable: false) { _, _ in
                try await self.withPasswordRetry {
                    try await self.engine.delete(entries: entries, from: archiveURL,
                                                 password: self.session.password)
                }
            }
            if done != nil { loadArchive() }
        }
    }

    @objc func renameSelected(_ sender: Any?) {
        guard let node = selectedNodesForCommand().first else { return }
        // A folder the archive only implies has no entry of its own, but renaming it
        // still means something: everything under it moves.
        let entry = node.entry ?? ArchiveEntry(path: node.path, isDirectory: node.isDirectory)
        guard let archiveURL = session.archiveURL, !session.isReadOnly else {
            present(ArchiveError.notWritable(session.format?.displayName ?? L("this format")))
            return
        }
        guard !isBusy else { return }

        let alert = NSAlert()
        alert.messageText = L("Rename %@", node.name)
        alert.informativeText = L("Enter a new name for this item inside the archive.")
        alert.addButton(withTitle: L("Rename"))
        alert.addButton(withTitle: L("Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.stringValue = node.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let newName = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != node.name else { return }
        // A slash of either kind would move the item into a folder of that name.
        guard !newName.contains("/"), !newName.contains("\\"), newName != ".", newName != ".." else {
            let alert = NSAlert()
            alert.messageText = L("“%@” cannot be used as a name.", newName)
            alert.informativeText = L("A name cannot contain a slash.")
            alert.addButton(withTitle: L("OK"))
            alert.runModal()
            return
        }
        if node.parent?.children.contains(where: { $0 !== node && $0.name == newName }) == true {
            let alert = NSAlert()
            alert.messageText = L("%@ already exists in the archive.", newName)
            alert.informativeText = L("Choose another name, or delete the other item first.")
            alert.addButton(withTitle: L("OK"))
            alert.runModal()
            return
        }
        let newPath = ArchivePath.join(entry.parentPath, newName)

        // Copies open for editing were made under the old name, files inside a
        // renamed folder included.
        editedFiles.stopTracking(under: entry.path)
        Task {
            let done = await runOperation(title: L("Renaming in %@", session.displayName),
                                          cancellable: false) { _, _ in
                try await self.withPasswordRetry {
                    try await self.engine.rename(entry: entry, to: newPath,
                                                 in: archiveURL, password: self.session.password)
                }
            }
            if done != nil { loadArchive() }
        }
    }

    // MARK: Testing, password, information

    @objc func testArchive(_ sender: Any?) {
        guard let archiveURL = session.archiveURL else { return }
        Task {
            let report = await runOperation(title: L("Testing %@", session.displayName)) { cancellation, progress in
                try await self.withPasswordRetry {
                    try await self.engine.test(archive: archiveURL, password: self.session.password,
                                               cancellation: cancellation, progress: progress)
                }
            }
            guard let report else { return }
            let alert = NSAlert()
            // The engine throws on failure, so reaching here means it passed unless
            // the report itself mentions trouble.
            let lowered = report.lowercased()
            let ok = !lowered.contains("error") && !lowered.contains("warning")
            alert.messageText = ok ? L("No errors found.") : L("The test reported problems.")
            alert.informativeText = report
            alert.alertStyle = ok ? .informational : .warning
            alert.addButton(withTitle: L("OK"))
            alert.runModal()
        }
    }

    @objc func setPassword(_ sender: Any?) {
        guard let url = session.archiveURL else { return }
        guard let response = PasswordPrompt.ask(archiveName: session.displayName,
                                                window: view.window,
                                                retry: false) else { return }
        _ = url
        session.password = response.password
        // Kept for the keychain until it has been seen to open something.
        passwordToRemember = response.rememberInKeychain ? response.password : nil
        loadArchive()
    }

    @objc func showArchiveInfo(_ sender: Any?) {
        let listing = session.listing
        let alert = NSAlert()
        alert.messageText = session.displayName

        var lines: [String] = []
        lines.append(L("Format: %@", listing.info.formatName.isEmpty
            ? (session.format?.displayName ?? L("Unknown")) : listing.info.formatName))
        if let url = session.archiveURL {
            lines.append(L("Location: %@", url.deletingLastPathComponent().path))
        }
        lines.append(L("Archive size: %@", Formatting.bytes(listing.info.physicalSize)))
        lines.append(L("Unpacked size: %@", Formatting.bytes(listing.totalSize)))
        if listing.totalSize > 0 {
            lines.append(L("Compression: %@",
                           Formatting.ratio(size: listing.totalSize, packed: listing.totalPacked)))
        }
        lines.append(L("Files: %@", Formatting.count(listing.fileCount)))
        lines.append(L("Folders: %@", Formatting.count(listing.folderCount)))
        lines.append(L("Solid: %@", listing.info.isSolid ? L("Yes") : L("No")))
        lines.append(L("Encrypted: %@", listing.containsEncryptedEntries ? L("Yes") : L("No")))
        if let volumes = listing.info.volumeCount { lines.append(L("Volumes: %d", volumes)) }
        if let comment = listing.info.comment { lines.append("\n" + L("Comment:") + "\n" + comment) }

        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }

    // MARK: Saving

    @objc func saveArchive(_ sender: Any?) {
        guard session.isUntitled || session.hasUnsavedChanges else { return }
        guard let archiveURL = session.archiveURL else {
            saveArchiveAs(sender)
            return
        }
        performSave(to: archiveURL, options: currentCompressionOptions(), rebuild: false, then: nil)
    }

    @objc func saveArchiveAs(_ sender: Any?) {
        runSaveAs(then: nil)
    }

    /// Asks where and how to save, then saves.
    /// - Parameter completion: told whether the archive was written, once it is known.
    func runSaveAs(then completion: ((Bool) -> Void)?) {
        let accessory = SaveOptionsAccessory()
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.accessoryView = accessory
        panel.prompt = L("Save")
        panel.message = L("Choose a name and format for the archive.")
        panel.nameFieldStringValue = defaultSaveName(for: accessory.selectedFormat)
        accessory.onFormatChange = { [weak panel] format in
            guard let panel else { return }
            let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
            let stem = FormatRegistry.baseName(for: URL(fileURLWithPath: panel.nameFieldStringValue))
            let name = stem.isEmpty ? base : stem
            panel.nameFieldStringValue = "\(name).\(format.extensions[0])"
        }

        guard panel.runModal() == .OK, let chosen = panel.url else {
            completion?(false)
            return
        }
        if accessory.hasUnparseableVolumeSize {
            let warning = NSAlert()
            warning.alertStyle = .warning
            warning.messageText = L("That split size was not understood.")
            warning.informativeText = L("Use a size such as 100m, 700m or 1.5g. Save without splitting?")
            warning.addButton(withTitle: L("Save Without Splitting"))
            warning.addButton(withTitle: L("Cancel"))
            guard warning.runModal() == .alertFirstButtonReturn else {
                completion?(false)
                return
            }
        }

        // The format menu decides what is written, so the name has to agree with it.
        // A name typed with another format's extension, or with none, would otherwise
        // get one kind of archive under another kind's name.
        let format = accessory.selectedFormat
        var url = chosen
        if FormatRegistry.format(for: chosen)?.key != format.key {
            let stem = FormatRegistry.baseName(for: chosen)
            url = chosen.deletingLastPathComponent()
                .appendingPathComponent("\(stem.isEmpty ? L("Archive") : stem).\(format.extensions[0])")
            if PathSafety.itemExists(at: url) {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = L("“%@” already exists. Do you want to replace it?", url.lastPathComponent)
                alert.informativeText = L("The name was given the extension that matches the chosen format.")
                alert.addButton(withTitle: L("Replace"))
                alert.addButton(withTitle: L("Cancel"))
                guard alert.runModal() == .alertFirstButtonReturn else {
                    completion?(false)
                    return
                }
            }
        }
        // Save As always writes the archive afresh, even over itself: the options
        // chosen in the panel take effect only when everything is rewritten.
        performSave(to: url, options: accessory.options(), rebuild: true, then: completion)
    }

    private func defaultSaveName(for format: ArchiveFormat) -> String {
        let stem: String
        if let archiveURL = session.archiveURL {
            stem = FormatRegistry.baseName(for: archiveURL)
        } else if let first = session.stagedRoots.first {
            stem = session.stagedRoots.count == 1
                ? (first.lastPathComponent as NSString).deletingPathExtension
                : L("Archive")
        } else {
            stem = L("Archive")
        }
        return "\(stem.isEmpty ? L("Archive") : stem).\(format.extensions[0])"
    }

    func currentCompressionOptions() -> CompressionOptions {
        CompressionOptions(formatKey: session.format?.key ?? Preferences.defaultFormatKey,
                           level: Preferences.defaultLevel,
                           password: session.password,
                           excludeMacMetadata: Preferences.excludeMacMetadata)
    }

    private func performSave(to url: URL, options: CompressionOptions, rebuild: Bool,
                             then completion: ((Bool) -> Void)?) {
        guard !isBusy else {
            completion?(false)
            return
        }
        Task {
            let done: Void? = await runOperation(title: L("Saving %@", url.lastPathComponent)) { cancellation, progress in
                try await self.withPasswordRetry {
                    try await self.session.save(to: url, options: options, rebuild: rebuild,
                                                cancellation: cancellation, progress: progress)
                }
            }
            if done != nil {
                // A split archive is opened through its first volume, not the name typed.
                let written = session.archiveURL ?? url
                RecentsRecorder.note(written)
                // Open copies were extracted from the archive as it was before.
                editedFiles.removeAll()
                onArchiveChange?(written)
                reloadFromSession()
            }
            completion?(done != nil)
        }
    }

    // MARK: - Shared plumbing

    /// Shows the progress panel, runs the work, and reports any failure.
    /// - Parameter cancellable: false for work the engine cannot stop partway.
    func runOperation<T>(title: String, cancellable: Bool = true,
                         work: @escaping (CancellationToken, @escaping ProgressHandler) async throws -> T) async -> T? {
        let cancellation = CancellationToken()
        let panel = ProgressWindowController(title: title, cancellation: cancellation)
        if !cancellable { panel.hideCancel() }
        beginOperation()
        if let window = view.window {
            window.beginSheet(panel.window!, completionHandler: nil)
        } else {
            panel.showWindow(nil)
        }
        defer {
            if let window = view.window, let sheet = panel.window {
                window.endSheet(sheet)
            }
            panel.finish()
            endOperation()
        }

        do {
            return try await work(cancellation) { progress in
                Task { @MainActor in panel.update(progress) }
            }
        } catch let error as ArchiveError where error == .cancelled {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func chooseFolder(prompt: String, message: String, startAt: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        panel.message = message
        panel.directoryURL = startAt
        return panel.runModal() == .OK ? panel.url : nil
    }

    func present(_ error: Error) {
        Diagnostics.log("error shown: \(error.localizedDescription)")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("JustArc could not complete that command.")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }
}
