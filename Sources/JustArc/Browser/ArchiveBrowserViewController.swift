import AppKit
import QuickLookUI
import UniformTypeIdentifiers
import JustArcCore

/// The WinRAR-style archive window: command strip, address row, file list, status bar.
@MainActor
final class ArchiveBrowserViewController: NSViewController, NSMenuItemValidation {
    let session: ArchiveSession
    /// Follows the session, so a disk image window drives hdiutil.
    var engine: ArchiveEngine { session.engine }

    private let toolbar = ArchiveToolbarView()
    private let pathBar = ArchivePathBar()
    private let statusBar = ArchiveStatusBar()
    private let folderTree = FolderTreeView()
    private let splitView = NSSplitView()
    private let scrollView = NSScrollView()
    private let table = ArchiveOutlineView()
    private let listSource = ArchiveListDataSource()

    private var currentPath = ""
    private var history: [String] = [""]
    private var historyIndex = 0
    private var filterText = ""
    private var previewItems: [URL] = []

    /// Watches files opened out of the archive so edits can be written back.
    let editedFiles = EditedFileWatcher()
    var currentPreviewItems: [URL] { previewItems }

    /// Per-window scratch space for files opened or previewed out of the archive.
    /// Created eagerly so `deinit`, which is not main-actor isolated, can clean it up.
    nonisolated let scratchDirectory: URL = {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("JustArc", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    var onTitleChange: ((String, URL?) -> Void)?

    init(session: ArchiveSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        let directory = scratchDirectory
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Layout

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
        buildTable()
        buildSplit()
        assemble()
        wireCallbacks()
        applyFolderTreeVisibility()
        refreshChrome()
    }

    private func buildTable() {
        table.dataSource = listSource
        table.delegate = listSource
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.rowHeight = 20
        table.intercellSpacing = NSSize(width: 4, height: 0)
        table.doubleAction = #selector(tableDoubleClicked)
        table.target = self
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setDraggingSourceOperationMask([.copy], forLocal: false)
        table.registerForDraggedTypes([.fileURL])
        table.indentationPerLevel = 14
        table.indentationMarkerFollowsCell = true
        table.autoresizesOutlineColumn = false

        var nameColumn: NSTableColumn?
        for column in ArchiveColumn.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 50
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            if column.isRightAligned {
                tableColumn.headerCell.alignment = .right
            }
            table.addTableColumn(tableColumn)
            if column == .name { nameColumn = tableColumn }
        }
        // The disclosure triangles belong next to the names.
        table.outlineTableColumn = nameColumn
        table.sortDescriptors = [NSSortDescriptor(key: ArchiveColumn.name.rawValue, ascending: true)]

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let menu = NSMenu()
        menu.addItem(withTitle: L("Open"), action: #selector(openSelectedFile(_:)), keyEquivalent: "")
        menu.addItem(withTitle: L("Quick Look"), action: #selector(toggleQuickLook(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Extract Selected…"), action: #selector(extractSelected(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Rename…"), action: #selector(renameSelected(_:)), keyEquivalent: "")
        menu.addItem(withTitle: L("Delete"), action: #selector(deleteSelected(_:)), keyEquivalent: "")
        for item in menu.items { item.target = self }
        table.menu = menu
    }

    private func buildSplit() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false

        let treeScroll = NSScrollView()
        treeScroll.documentView = folderTree.outlineView
        treeScroll.hasVerticalScroller = true
        treeScroll.borderType = .noBorder
        treeScroll.identifier = NSUserInterfaceItemIdentifier("folderTreePane")
        folderTree.scrollView = treeScroll

        splitView.addArrangedSubview(treeScroll)
        splitView.addArrangedSubview(scrollView)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
    }

    private func assemble() {
        let stack = NSStackView(views: [toolbar, pathBar, splitView, statusBar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            toolbar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pathBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            splitView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func wireCallbacks() {
        toolbar.onCommand = { [weak self] command in
            guard let self else { return }
            switch command {
            case .add: self.addFiles(nil)
            case .extractTo: self.extractSelectedOrAll()
            case .test: self.testArchive(nil)
            case .view: self.openSelectedFile(nil)
            case .delete: self.deleteSelected(nil)
            case .find: self.focusFilterField(nil)
            case .info: self.showArchiveInfo(nil)
            case .password: self.setPassword(nil)
            case .save: self.saveArchive(nil)
            }
        }

        pathBar.onGoUp = { [weak self] in self?.goUp(nil) }
        pathBar.onNavigate = { [weak self] path in self?.navigate(to: path) }
        pathBar.onFilterChanged = { [weak self] text in
            self?.filterText = text
            self?.reloadList()
        }

        table.onOpen = { [weak self] in self?.openSelectedFile(nil) }
        table.onPreview = { [weak self] in self?.toggleQuickLook(nil) }
        table.onDelete = { [weak self] in self?.deleteSelected(nil) }
        table.onGoUp = { [weak self] in self?.goUp(nil) }

        listSource.onSelectionChange = { [weak self] in self?.refreshStatusBar() }
        listSource.onSortChange = { [weak self] column, ascending in
            self?.listSource.sortColumn = column
            self?.listSource.sortAscending = ascending
            self?.reloadList()
        }
        listSource.onDropFiles = { [weak self] urls in self?.add(items: urls) }
        listSource.promiseProvider = { [weak self] entry in self?.makePromise(for: entry) }

        folderTree.onSelect = { [weak self] path in self?.navigate(to: path) }

        editedFiles.onChangesDetected = { [weak self] changed in
            self?.offerToUpdate(changed)
        }
    }

    // MARK: - Loading

    func loadArchive() {
        guard !session.isUntitled else {
            reloadList()
            return
        }
        Task { await performLoad() }
    }

    private func performLoad() async {
        if session.password == nil, let url = session.archiveURL {
            session.password = KeychainStore.password(for: url)
        }
        var attempt = 0
        while true {
            do {
                try await loadWithDownloadPanel()
                reloadList()
                refreshChrome()
                return
            } catch let error as ArchiveError where error.isPasswordProblem {
                guard let name = session.archiveURL?.lastPathComponent,
                      let response = PasswordPrompt.ask(archiveName: name,
                                                        window: view.window,
                                                        retry: attempt > 0) else {
                    view.window?.close()
                    return
                }
                session.password = response.password
                if response.rememberInKeychain, let url = session.archiveURL {
                    KeychainStore.save(password: response.password, for: url)
                }
                attempt += 1
            } catch {
                present(error)
                view.window?.close()
                return
            }
        }
    }

    /// Loading can start with a download when the archive lives in a cloud folder,
    /// so that wait gets the same progress panel as any other long operation.
    private func loadWithDownloadPanel() async throws {
        guard let url = session.archiveURL, CloudFile.status(of: url).needsDownload else {
            try await session.load()
            return
        }
        let cancellation = CancellationToken()
        let panel = ProgressWindowController(title: L("Downloading %@", url.lastPathComponent),
                                             cancellation: cancellation)
        if let window = view.window {
            window.beginSheet(panel.window!, completionHandler: nil)
        } else {
            panel.showWindow(nil)
        }
        defer {
            if let window = view.window, let sheet = panel.window { window.endSheet(sheet) }
            panel.finish()
        }
        try await session.load(cancellation: cancellation)
    }

    func reloadFromSession() {
        session.rebuild()
        reloadList()
        refreshChrome()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Without this the filter field takes focus and swallows the space bar,
        // so Quick Look never fires.
        view.window?.makeFirstResponder(table)
    }

    func reloadList() {
        if session.tree.node(at: currentPath) == nil { currentPath = "" }
        listSource.reload(tree: session.tree, path: currentPath, filter: filterText)
        table.reloadData()
        expandSingleRootFolder()
        Diagnostics.log("list: \(session.visibleEntries.count) entries, "
                        + "\(table.numberOfRows) rows at \"\(currentPath)\"")
        folderTree.reload(tree: session.tree, archiveName: session.displayName)
        folderTree.select(path: currentPath)
        refreshChrome()
    }

    /// Most archives wrap everything in one folder named after the archive. Showing a
    /// single collapsed row tells the user nothing, so open it for them.
    private func expandSingleRootFolder() {
        guard currentPath.isEmpty, !listSource.isFiltering,
              table.numberOfRows == 1,
              let only = table.item(atRow: 0),
              let node = listSource.node(for: only), node.isDirectory,
              table.isExpandable(only) else { return }
        table.expandItem(only)
    }

    private func refreshChrome() {
        let icon = session.archiveURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "doc.zipper", accessibilityDescription: nil)
        icon?.size = NSSize(width: 14, height: 14)
        pathBar.update(archiveName: session.displayName, currentPath: currentPath, icon: icon)

        // Adding and deleting need in-place editing; Save As works for any writable format.
        let editable = session.canModifyContents
        toolbar.setEnabled(editable, for: .add)
        toolbar.setEnabled(editable, for: .delete)
        toolbar.setEnabled(session.canSaveAs, for: .save)
        toolbar.setEnabled(!session.isUntitled, for: .test)
        toolbar.setEnabled(!session.isUntitled, for: .password)

        var title = session.displayName
        if session.hasUnsavedChanges { title += L(" — Edited") }
        onTitleChange?(title, session.archiveURL)
        refreshStatusBar()
    }

    private func refreshStatusBar() {
        statusBar.update(selection: selectedEntriesForCommand(),
                         listing: ArchiveListing(info: session.listing.info,
                                                 entries: session.visibleEntries),
                         isEncrypted: session.listing.containsEncryptedEntries)
    }

    // MARK: - Navigation

    func navigate(to path: String, recordHistory: Bool = true) {
        currentPath = path
        if recordHistory {
            history.removeSubrange((historyIndex + 1)...)
            history.append(path)
            historyIndex = history.count - 1
        }
        table.deselectAll(nil)
        reloadList()
        view.window?.makeFirstResponder(table)
    }

    @objc func goUp(_ sender: Any?) {
        guard !currentPath.isEmpty else { return }
        var parts = currentPath.split(separator: "/")
        parts.removeLast()
        navigate(to: parts.joined(separator: "/"))
    }

    @objc func goBack(_ sender: Any?) {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        navigate(to: history[historyIndex], recordHistory: false)
    }

    @objc func goForward(_ sender: Any?) {
        guard historyIndex + 1 < history.count else { return }
        historyIndex += 1
        navigate(to: history[historyIndex], recordHistory: false)
    }

    @objc private func tableDoubleClicked() {
        let row = table.clickedRow
        guard row >= 0, let item = table.item(atRow: row) else { return }
        guard let node = listSource.node(for: item) else {
            goUp(nil)
            return
        }
        if node.isDirectory {
            navigate(to: node.path)
        } else {
            openSelectedFile(nil)
        }
    }

    // MARK: - Selection

    func selectedNodesForCommand() -> [EntryTree.Node] {
        table.selectedRowIndexes.compactMap { listSource.node(for: table.item(atRow: $0)) }
    }

    func selectedEntriesForCommand() -> [ArchiveEntry] {
        selectedNodesForCommand().flatMap { $0.descendantEntries() }
    }

    @objc func invertSelection(_ sender: Any?) {
        let current = table.selectedRowIndexes
        let all = IndexSet(integersIn: 0..<table.numberOfRows)
        table.selectRowIndexes(all.subtracting(current), byExtendingSelection: false)
    }

    @objc func focusFilterField(_ sender: Any?) {
        pathBar.focusFilter()
    }

    @objc func toggleFolderTree(_ sender: Any?) {
        Preferences.showFolderTree.toggle()
        applyFolderTreeVisibility()
    }

    private func applyFolderTreeVisibility() {
        guard let pane = folderTree.scrollView else { return }
        let visible = Preferences.showFolderTree
        pane.isHidden = !visible
        if visible {
            splitView.setPosition(210, ofDividerAt: 0)
        }
    }

    @objc func reloadArchive(_ sender: Any?) {
        loadArchive()
    }

    // MARK: - Filename encoding

    @objc func setTextEncoding(_ sender: NSMenuItem) {
        let codePage = sender.tag == 0 ? nil : sender.tag
        guard session.encodingCodePage != codePage else { return }
        session.encodingCodePage = codePage
        loadArchive()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(setTextEncoding(_:)) {
            let current = session.encodingCodePage ?? 0
            menuItem.state = menuItem.tag == current ? .on : .off
            return ArchiveTextEncoding.isOverridable(session.format) && !session.isUntitled
        }
        if menuItem.action == #selector(toggleFolderTree(_:)) {
            menuItem.state = Preferences.showFolderTree ? .on : .off
        }
        return true
    }

    @objc func revealArchiveInFinder(_ sender: Any?) {
        guard let url = session.archiveURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Helpers shared with the command extension

    func navigateToNode(_ node: EntryTree.Node) {
        navigate(to: node.path)
    }

    /// Root of this window's scratch space, where opened and previewed files land.
    func scratchRoot() -> URL { scratchDirectory }

    func scratchURL(for entry: ArchiveEntry) -> URL {
        scratchDirectory.appendingPathComponent(entry.path)
    }

    func setPreviewItems(_ urls: [URL]) {
        previewItems = urls
    }

    /// Supplies a promise so entries can be dragged straight into Finder.
    func makePromise(for node: EntryTree.Node) -> NSFilePromiseProvider? {
        guard !node.isDirectory, node.entry != nil else { return nil }
        let ext = (node.name as NSString).pathExtension
        let type = UTType(filenameExtension: ext) ?? .data
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
        provider.userInfo = node.path
        return provider
    }
}

// MARK: - Dragging entries out to Finder

extension ArchiveBrowserViewController: NSFilePromiseProviderDelegate {
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             fileNameForType fileType: String) -> String {
        let path = (filePromiseProvider.userInfo as? String) ?? "item"
        return (path as NSString).lastPathComponent
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        guard let path = filePromiseProvider.userInfo as? String,
              let node = session.tree.node(at: path) else {
            completionHandler(ArchiveError.ioFailure(L("That item is no longer in the archive.")))
            return
        }
        Task { @MainActor in
            guard let source = await self.materialize(node: node, quiet: true) else {
                completionHandler(ArchiveError.ioFailure(L("%@ could not be extracted.", node.name)))
                return
            }
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                try FileManager.default.copyItem(at: source, to: url)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        .main
    }
}

// MARK: - Quick Look

extension ArchiveBrowserViewController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        currentPreviewItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        currentPreviewItems.indices.contains(index)
            ? currentPreviewItems[index] as NSURL
            : nil
    }
}

