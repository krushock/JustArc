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
        panel.prompt = "Add"
        panel.message = "Choose files or folders to add to \(session.displayName)."
        guard panel.runModal() == .OK else { return }
        add(items: panel.urls)
    }

    func add(items: [URL]) {
        guard !items.isEmpty else { return }
        guard !session.isReadOnly else {
            present(ArchiveError.notWritable(session.format?.displayName ?? "this format"))
            return
        }

        // An untitled window just stages the files until the user saves.
        guard let archiveURL = session.archiveURL else {
            session.stage(items: items)
            reloadFromSession()
            return
        }

        Task {
            let options = CompressionOptions(formatKey: session.format?.key ?? "zip",
                                             level: Preferences.defaultLevel,
                                             password: session.password,
                                             excludeMacMetadata: Preferences.excludeMacMetadata)
            let done = await runOperation(title: "Adding to \(session.displayName)") { cancellation, progress in
                try await self.engine.add(items: items, to: archiveURL, options: options,
                                          cancellation: cancellation, progress: progress)
            }
            if done != nil { loadArchive() }
        }
    }

    // MARK: Extracting

    func extractSelectedOrAll() {
        selectedEntriesForCommand().isEmpty ? extractAll(nil) : extractSelected(nil)
    }

    @objc func extractSelected(_ sender: Any?) {
        let entries = selectedEntriesForCommand()
        guard !entries.isEmpty else {
            extractAll(nil)
            return
        }
        extract(entries: entries, label: "Extracting \(entries.count) item(s)")
    }

    @objc func extractAll(_ sender: Any?) {
        extract(entries: nil, label: "Extracting \(session.displayName)")
    }

    private func extract(entries: [ArchiveEntry]?, label: String) {
        guard let archiveURL = session.archiveURL else {
            present(ArchiveError.ioFailure("Save this archive before extracting from it."))
            return
        }
        guard let destination = chooseFolder(prompt: "Extract",
                                             message: "Choose where to extract the selected items.",
                                             startAt: archiveURL.deletingLastPathComponent())
        else { return }

        Task {
            let done = await runOperation(title: label) { cancellation, progress in
                try await self.engine.extract(archive: archiveURL,
                                              entries: entries,
                                              to: destination,
                                              password: self.session.password,
                                              overwrite: .renameNew,
                                              flattenPaths: false,
                                              cancellation: cancellation,
                                              progress: progress)
            }
            if done != nil, Preferences.revealInFinder {
                NSWorkspace.shared.activateFileViewerSelecting([destination])
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
        Task {
            guard let url = await materialize(node: node) else { return }
            // Remember what it looked like, so an edit in another app can be written back.
            if session.archiveURL != nil, session.canModifyContents, session.stagedSource(for: node.path) == nil {
                editedFiles.track(localURL: url, entryPath: node.path)
            }
            NSWorkspace.shared.open(url)
        }
    }

    /// Asks whether edits made in another app should go back into the archive.
    func offerToUpdate(_ changed: [EditedFileWatcher.Tracked]) {
        guard let archiveURL = session.archiveURL, session.canModifyContents else { return }

        let alert = NSAlert()
        alert.messageText = changed.count == 1
            ? "\((changed[0].entryPath as NSString).lastPathComponent) was edited outside JustArc."
            : "\(changed.count) files opened from this archive were edited outside JustArc."
        alert.informativeText = changed.count == 1
            ? "Update \(session.displayName) with the edited file?"
            : "Update \(session.displayName) with the edited files?\n\n"
              + changed.map(\.entryPath).joined(separator: "\n")
        alert.addButton(withTitle: changed.count == 1 ? "Update Archive" : "Update Archive")
        alert.addButton(withTitle: "Keep Unchanged")
        guard alert.runModal() == .alertFirstButtonReturn else {
            for entry in changed { editedFiles.acknowledge(entryPath: entry.entryPath) }
            return
        }

        let options = currentCompressionOptions()
        Task {
            let done = await runOperation(title: "Updating \(session.displayName)") { cancellation, progress in
                for entry in changed {
                    try await self.engine.update(fileAt: entry.localURL,
                                                 entryPath: entry.entryPath,
                                                 in: archiveURL,
                                                 options: options,
                                                 cancellation: cancellation,
                                                 progress: progress)
                }
            }
            for entry in changed { editedFiles.acknowledge(entryPath: entry.entryPath) }
            if done != nil { loadArchive() }
        }
    }

    @objc func toggleQuickLook(_ sender: Any?) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        let nodes = selectedNodesForCommand().filter { !$0.isDirectory }
        guard !nodes.isEmpty else { return }
        Task {
            var urls: [URL] = []
            for node in nodes.prefix(20) {
                if let url = await materialize(node: node, quiet: true) { urls.append(url) }
            }
            guard !urls.isEmpty else { return }
            setPreviewItems(urls)
            panel.makeKeyAndOrderFront(nil)
            panel.reloadData()
        }
    }

    /// Extracts one entry into this window's scratch folder so it can be opened or previewed.
    func materialize(node: EntryTree.Node, quiet: Bool = false) async -> URL? {
        if let staged = session.stagedSource(for: node.path) { return staged }
        guard let archiveURL = session.archiveURL, let entry = node.entry else { return nil }

        let cached = scratchURL(for: entry)
        if FileManager.default.fileExists(atPath: cached.path) { return cached }

        do {
            return try await engine.extractSingle(archive: archiveURL,
                                                  entry: entry,
                                                  to: scratchRoot(),
                                                  password: session.password)
        } catch {
            if !quiet { present(error) }
            return nil
        }
    }

    // MARK: Deleting and renaming

    @objc func deleteSelected(_ sender: Any?) {
        let nodes = selectedNodesForCommand()
        guard !nodes.isEmpty else { return }
        guard !session.isReadOnly else {
            present(ArchiveError.notWritable(session.format?.displayName ?? "this format"))
            return
        }

        let alert = NSAlert()
        alert.messageText = nodes.count == 1
            ? "Delete \(nodes[0].name) from the archive?"
            : "Delete \(nodes.count) items from the archive?"
        alert.informativeText = "This changes the archive on disk and cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard let archiveURL = session.archiveURL else {
            for node in nodes {
                if let source = session.stagedSource(for: node.path) {
                    session.unstage(root: source)
                } else {
                    session.markForDeletion([node.path])
                }
            }
            reloadFromSession()
            return
        }

        let entries = nodes.flatMap { $0.descendantEntries() }
        for entry in entries { editedFiles.stopTracking(entryPath: entry.path) }
        Task {
            let done = await runOperation(title: "Deleting from \(session.displayName)") { _, _ in
                try await self.engine.delete(entries: entries, from: archiveURL,
                                             password: self.session.password)
            }
            if done != nil { loadArchive() }
        }
    }

    @objc func renameSelected(_ sender: Any?) {
        guard let node = selectedNodesForCommand().first, let entry = node.entry else { return }
        guard let archiveURL = session.archiveURL, !session.isReadOnly else {
            present(ArchiveError.notWritable(session.format?.displayName ?? "this format"))
            return
        }

        let alert = NSAlert()
        alert.messageText = "Rename \(node.name)"
        alert.informativeText = "Enter a new name for this item inside the archive."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.stringValue = node.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let newName = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != node.name, !newName.contains("/") else { return }
        let newPath = ArchivePath.join(entry.parentPath, newName)

        editedFiles.stopTracking(entryPath: entry.path)
        Task {
            let done = await runOperation(title: "Renaming in \(session.displayName)") { _, _ in
                try await self.engine.rename(entry: entry, to: newPath,
                                             in: archiveURL, password: self.session.password)
            }
            if done != nil { loadArchive() }
        }
    }

    // MARK: Testing, password, information

    @objc func testArchive(_ sender: Any?) {
        guard let archiveURL = session.archiveURL else { return }
        Task {
            let report = await runOperation(title: "Testing \(session.displayName)") { cancellation, progress in
                try await self.engine.test(archive: archiveURL, password: self.session.password,
                                           cancellation: cancellation, progress: progress)
            }
            guard let report else { return }
            let alert = NSAlert()
            // The engine throws on failure, so reaching here means it passed unless
            // the report itself mentions trouble.
            let lowered = report.lowercased()
            let ok = !lowered.contains("error") && !lowered.contains("warning")
            alert.messageText = ok ? "No errors found." : "The test reported problems."
            alert.informativeText = report
            alert.alertStyle = ok ? .informational : .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc func setPassword(_ sender: Any?) {
        guard let url = session.archiveURL else { return }
        guard let response = PasswordPrompt.ask(archiveName: session.displayName,
                                                window: view.window,
                                                retry: false) else { return }
        session.password = response.password
        if response.rememberInKeychain {
            KeychainStore.save(password: response.password, for: url)
        }
        loadArchive()
    }

    @objc func showArchiveInfo(_ sender: Any?) {
        let listing = session.listing
        let alert = NSAlert()
        alert.messageText = session.displayName

        var lines: [String] = []
        lines.append("Format: \(listing.info.formatName.isEmpty ? (session.format?.displayName ?? "Unknown") : listing.info.formatName)")
        if let url = session.archiveURL { lines.append("Location: \(url.deletingLastPathComponent().path)") }
        lines.append("Archive size: \(Formatting.bytes(listing.info.physicalSize))")
        lines.append("Unpacked size: \(Formatting.bytes(listing.totalSize))")
        if listing.totalSize > 0 {
            lines.append("Compression: \(Formatting.ratio(size: listing.totalSize, packed: listing.totalPacked))")
        }
        lines.append("Files: \(Formatting.count(listing.fileCount))")
        lines.append("Folders: \(Formatting.count(listing.folderCount))")
        lines.append("Solid: \(listing.info.isSolid ? "Yes" : "No")")
        lines.append("Encrypted: \(listing.containsEncryptedEntries ? "Yes" : "No")")
        if let volumes = listing.info.volumeCount { lines.append("Volumes: \(volumes)") }
        if let comment = listing.info.comment { lines.append("\nComment:\n\(comment)") }

        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: Saving

    @objc func saveArchive(_ sender: Any?) {
        guard session.isUntitled || session.hasUnsavedChanges else { return }
        guard session.archiveURL != nil else {
            saveArchiveAs(sender)
            return
        }
        performSave(to: session.archiveURL!, options: currentCompressionOptions())
    }

    @objc func saveArchiveAs(_ sender: Any?) {
        let accessory = SaveOptionsAccessory()
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.accessoryView = accessory
        panel.prompt = "Save"
        panel.message = "Choose a name and format for the archive."
        panel.nameFieldStringValue = defaultSaveName(for: accessory.selectedFormat)
        accessory.onFormatChange = { [weak panel] format in
            guard let panel else { return }
            let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
            let stem = FormatRegistry.baseName(for: URL(fileURLWithPath: panel.nameFieldStringValue))
            let name = stem.isEmpty ? base : stem
            panel.nameFieldStringValue = "\(name).\(format.extensions[0])"
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        if accessory.hasUnparseableVolumeSize {
            let warning = NSAlert()
            warning.alertStyle = .warning
            warning.messageText = "That split size was not understood."
            warning.informativeText = "Use a size such as 100m, 700m or 1.5g. Save without splitting?"
            warning.addButton(withTitle: "Save Without Splitting")
            warning.addButton(withTitle: "Cancel")
            guard warning.runModal() == .alertFirstButtonReturn else { return }
        }
        performSave(to: url, options: accessory.options())
    }

    private func defaultSaveName(for format: ArchiveFormat) -> String {
        let stem: String
        if let archiveURL = session.archiveURL {
            stem = FormatRegistry.baseName(for: archiveURL)
        } else if let first = session.stagedRoots.first {
            stem = session.stagedRoots.count == 1
                ? (first.lastPathComponent as NSString).deletingPathExtension
                : "Archive"
        } else {
            stem = "Archive"
        }
        return "\(stem.isEmpty ? "Archive" : stem).\(format.extensions[0])"
    }

    func currentCompressionOptions() -> CompressionOptions {
        CompressionOptions(formatKey: session.format?.key ?? Preferences.defaultFormatKey,
                           level: Preferences.defaultLevel,
                           password: session.password,
                           excludeMacMetadata: Preferences.excludeMacMetadata)
    }

    private func performSave(to url: URL, options: CompressionOptions) {
        Task {
            let done = await runOperation(title: "Saving \(url.lastPathComponent)") { cancellation, progress in
                try await self.session.save(to: url, options: options,
                                            cancellation: cancellation, progress: progress)
            }
            if done != nil {
                reloadFromSession()
            }
        }
    }

    // MARK: - Shared plumbing

    /// Shows the progress panel, runs the work, and reports any failure.
    func runOperation<T>(title: String,
                         work: @escaping (CancellationToken, @escaping ProgressHandler) async throws -> T) async -> T? {
        let cancellation = CancellationToken()
        let panel = ProgressWindowController(title: title, cancellation: cancellation)
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
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "JustArc could not complete that command."
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
