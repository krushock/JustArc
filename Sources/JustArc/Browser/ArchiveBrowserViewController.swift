import AppKit
import QuickLookUI
import UniformTypeIdentifiers
import JustArcCore

/// The file list that fills the window beside the sidebar.
///
/// The window's chrome lives where the system expects it: commands in the toolbar,
/// the location in the window's subtitle, the folder tree in a sidebar split item.
/// This controller owns the list and the status bar, and nothing else.
@MainActor
final class ArchiveBrowserViewController: NSViewController, NSMenuItemValidation,
                                          NSToolbarItemValidation {
    let session: ArchiveSession
    /// Follows the session, so a disk image window drives hdiutil.
    var engine: ArchiveEngine { session.engine }

    private let statusBar = ArchiveStatusBar()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
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
    /// Where we are inside the archive, for the window subtitle.
    var onLocationChange: ((String) -> Void)?
    /// Which archive this window shows, so the sidebar can mark it.
    var onArchiveChange: ((URL?) -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onFocusFilter: (() -> Void)?

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
        view = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 620))
        buildTable()
        assemble()
        wireCallbacks()
        refreshChrome()
    }

    private func buildTable() {
        table.dataSource = listSource
        table.delegate = listSource
        // Inset is the list style the system apps use now: rounded selection that sits
        // in from the edges, and no zebra striping.
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.gridStyleMask = []
        table.selectionHighlightStyle = .regular
        table.allowsColumnSelection = false
        table.usesAutomaticRowHeights = false
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
        scrollView.drawsBackground = false
        // Lets the list scroll under the toolbar, which is what drives the scroll edge
        // effect the system draws above it.
        scrollView.automaticallyAdjustsContentInsets = true
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

    private func assemble() {
        // The scroll view runs the full height so the list slides under the toolbar,
        // which is what produces the scroll edge effect on macOS 26 and later.
        let stack = NSStackView(views: [scrollView, statusBar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        // Shown in place of an empty list, the way Mail says "No Message Selected".
        emptyLabel.font = .preferredFont(forTextStyle: .title3)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
        ])
    }

    private func updateEmptyState() {
        let isEmpty = table.numberOfRows == 0
        emptyLabel.isHidden = !isEmpty
        guard isEmpty else { return }
        if listSource.isFiltering {
            emptyLabel.stringValue = L("No Matches")
        } else if session.isUntitled {
            emptyLabel.stringValue = L("Drop files here to start an archive")
        } else {
            emptyLabel.stringValue = L("This archive is empty")
        }
    }

    private func wireCallbacks() {
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
                if let url = session.archiveURL { RecentsRecorder.note(url) }
                onArchiveChange?(session.archiveURL)
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
        updateEmptyState()
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
        onLocationChange?(currentPath)

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
        onFocusFilter?()
    }

    /// Called by the toolbar's search field.
    func setFilter(_ text: String) {
        guard filterText != text else { return }
        filterText = text
        reloadList()
    }

    @objc func toggleFolderTree(_ sender: Any?) {
        onToggleSidebar?()
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

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        canPerform(item.action)
    }

    /// One place deciding whether a command applies, so the toolbar and the menus
    /// never disagree about what is available.
    func canPerform(_ action: Selector?) -> Bool {
        switch action {
        case #selector(addFiles(_:)), #selector(deleteSelected(_:)), #selector(renameSelected(_:)):
            return session.canModifyContents
        case #selector(saveArchive(_:)), #selector(saveArchiveAs(_:)):
            return session.canSaveAs
        case #selector(testArchive(_:)), #selector(setPassword(_:)),
             #selector(extractSelected(_:)), #selector(extractAll(_:)):
            return !session.isUntitled
        case #selector(goBack(_:)):
            return historyIndex > 0
        case #selector(goForward(_:)):
            return historyIndex + 1 < history.count
        case #selector(goUp(_:)):
            return !currentPath.isEmpty
        case #selector(openSelectedFile(_:)), #selector(toggleQuickLook(_:)):
            return !selectedNodesForCommand().isEmpty
        default:
            return true
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(setTextEncoding(_:)) {
            let current = session.encodingCodePage ?? 0
            menuItem.state = menuItem.tag == current ? .on : .off
            return ArchiveTextEncoding.isOverridable(session.format) && !session.isUntitled
        }
        if menuItem.action == #selector(toggleFolderTree(_:)) {
            menuItem.title = Preferences.showSidebar ? L("Hide Sidebar") : L("Show Sidebar")
            return true
        }
        return canPerform(menuItem.action)
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

