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
                                          NSToolbarItemValidation, CommandAvailability {
    let session: ArchiveSession
    /// Follows the session, so a disk image window drives hdiutil.
    var engine: ArchiveEngine { session.engine }

    private let statusBar = ArchiveStatusBar()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let table = ArchiveOutlineView()
    private let listSource = ArchiveListDataSource()

    private var currentPath = ""
    /// The folder inside the archive that the list is showing, "" at the top.
    var currentFolderPath: String { currentPath }
    private var history: [String] = [""]
    private var historyIndex = 0
    private var filterText = ""
    private var previewItems: [URL] = []

    /// How many operations are running. While one is, nothing else that reads or
    /// changes the archive may start: two rewrites at once each begin from the old
    /// file, and the one that finishes last silently undoes the other.
    private var runningOperations = 0
    var isBusy: Bool { runningOperations > 0 }
    /// Called before the task that does the work is started, not from inside it. A
    /// task does not run at once, and in between a question that had been waiting
    /// its turn could be asked and answered, and start a second rewrite of the
    /// archive alongside this one.
    func beginOperation() { runningOperations += 1 }

    func endOperation() {
        runningOperations = max(runningOperations - 1, 0)
        // A reload asked for in the meantime was put off; this is the time for it.
        if runningOperations == 0, reloadIsPending {
            reloadIsPending = false
            loadArchive()
        }
    }
    /// A reload replaces the listing and sweeps away what was extracted for viewing,
    /// which work in progress may be reading or writing. It waits for that work.
    private var reloadIsPending = false

    /// Set when the window has gone. A read of the archive still in flight has to
    /// give back what it took, such as a disk image it attached, when it lands.
    private var windowIsClosed = false
    var onSettledAfterClose: (() -> Void)?
    func windowDidClose() { windowIsClosed = true }

    /// True from the first successful read of the archive. A failure before that
    /// leaves nothing to show; a failure after it leaves the window as it was.
    private(set) var hasLoadedOnce = false
    private var isLoading = false
    /// Counts reloads, so a file extracted for viewing is not served again after
    /// the archive has changed underneath it.
    private(set) var listingGeneration = 0
    /// A password to put in the keychain once it has been seen to work.
    var passwordToRemember: String?
    /// The password that is known to open this archive, because something encrypted
    /// has been decoded with it. Until there is one, nothing is written to an
    /// encrypted archive: a file added with no password, or the wrong one, would go
    /// in unprotected or under a password nobody knows.
    private(set) var provenPassword: String?
    func notePasswordProven() {
        provenPassword = session.password
        rememberPasswordIfProven()
    }
    /// Set when the password prompt is dismissed, so that work covering several
    /// files asks once and not once per file.
    var passwordPromptWasCancelled = false
    var isLoadingArchive: Bool { isLoading }

    /// The archive on disk is no longer what was read: after a save, for one.
    func archiveDidChangeOnDisk() {
        hasLoadedOnce = true
        listingGeneration += 1
        discardViewingCopies(before: listingGeneration)
    }
    /// Set while the "edited outside JustArc" question is on screen.
    var isOfferingUpdate = false
    private var previewRequest = 0
    private var promiseChain: Task<Void, Never>?

    /// Watches files opened out of the archive so edits can be written back.
    let editedFiles = EditedFileWatcher()
    var currentPreviewItems: [URL] { previewItems }

    /// Per-window scratch space for files opened or previewed out of the archive.
    /// Created eagerly so `deinit`, which is not main-actor isolated, can clean it up.
    nonisolated let scratchDirectory: URL = ScratchSpace.makeWindowFolder()

    var onTitleChange: ((String, URL?) -> Void)?
    /// Where we are inside the archive, for the window subtitle.
    var onLocationChange: ((String) -> Void)?
    /// Which archive this window shows, so the sidebar can mark it.
    var onArchiveChange: ((URL?) -> Void)?
    var onToggleSidebar: (() -> Void)?
    /// The archive could not be read at all, so this window has nothing to show.
    var onLoadFailed: (() -> Void)?
    /// Archives dropped on an empty window, which are opened rather than added.
    var onOpenArchives: (([URL]) -> Void)?
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
        // The list takes drops itself; this catches the ones that land beside it, on
        // the empty-window message or the status bar.
        let dropView = FileDropView(frame: NSRect(x: 0, y: 0, width: 760, height: 620))
        dropView.canAccept = { [weak self] urls in self?.canAcceptDrop(of: urls) ?? false }
        dropView.onDrop = { [weak self] urls in self?.handleDrop(of: urls, into: nil) ?? false }
        view = dropView
        buildTable()
        assemble()
        wireCallbacks()
        // An untitled window never loads an archive, so without this it never draws its
        // list either, and the empty-window message stayed hidden.
        reloadList()
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
        if isLoading && !hasLoadedOnce {
            emptyLabel.stringValue = L("Reading the archive…")
        } else if listSource.isFiltering {
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
        // The selection rectangle skips the ".." row, which is not a file.
        table.isRowSelectable = { [weak self] row in
            guard let self else { return false }
            return listSource.node(for: table.item(atRow: row)) != nil
        }

        listSource.onSelectionChange = { [weak self] in
            self?.refreshStatusBar()
            self?.refreshQuickLookIfShowing()
        }
        listSource.onSortChange = { [weak self] column, ascending in
            self?.listSource.sortColumn = column
            self?.listSource.sortAscending = ascending
            self?.reloadList()
        }
        listSource.onDropFiles = { [weak self] urls, folder in
            self?.handleDrop(of: urls, into: folder) ?? false
        }
        listSource.canDropFiles = { [weak self] urls in self?.canAcceptDrop(of: urls) ?? false }
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
        // A second read started while one is running would race it for the listing.
        guard !isLoading else { return }
        guard !isBusy else {
            reloadIsPending = true
            return
        }
        Task { await performLoad() }
    }

    private func performLoad() async {
        guard let url = session.archiveURL else { return }
        isLoading = true
        updateEmptyState()
        defer {
            isLoading = false
            updateEmptyState()
            if windowIsClosed {
                // The window closed while this was being read; its own release ran
                // before there was anything to release.
                let session = self.session
                DispatchQueue.global(qos: .utility).async { session.close() }
                onSettledAfterClose?()
                onSettledAfterClose = nil
            }
        }

        var attempt = 0
        var triedKeychain = false
        var usingKeychainPassword = false
        while true {
            do {
                try await loadWithDownloadPanel()
                hasLoadedOnce = true
                listingGeneration += 1
                discardViewingCopies(before: listingGeneration)
                // Reading a listing only proves a password when the names themselves
                // are encrypted; otherwise it is proven by the first file that decodes.
                if session.listing.info.hasEncryptedHeader { notePasswordProven() }
                RecentsRecorder.note(url)
                onArchiveChange?(session.archiveURL)
                reloadList()
                refreshChrome()
                return
            } catch let error as ArchiveError where error.isPasswordProblem {
                // A remembered password is tried once before anyone is asked, and
                // forgotten if it no longer opens the archive at this path.
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
                // "That did not work" is the truth whenever a password was tried,
                // whether typed at this prompt or set beforehand.
                guard let response = PasswordPrompt.ask(archiveName: url.lastPathComponent,
                                                        window: view.window,
                                                        retry: attempt > 0 || session.password != nil) else {
                    // Back to the last password known to be right, not to whichever
                    // one was just refused.
                    session.password = provenPassword
                    passwordToRemember = nil
                    if !hasLoadedOnce { onLoadFailed?() }
                    return
                }
                session.password = response.password
                passwordToRemember = response.rememberInKeychain ? response.password : nil
                attempt += 1
            } catch let error as ArchiveError where error == .cancelled {
                if !hasLoadedOnce { onLoadFailed?() }
                return
            } catch {
                present(error)
                if !hasLoadedOnce { onLoadFailed?() }
                return
            }
        }
    }

    /// Saves the password the user asked to have remembered, now that it has worked.
    func rememberPasswordIfProven() {
        guard let password = passwordToRemember, password == provenPassword,
              let url = session.archiveURL else { return }
        KeychainStore.save(password: password, for: url)
        passwordToRemember = nil
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
        do {
            try await session.load(cancellation: cancellation)
        } catch {
            if cancellation.isCancelled { throw ArchiveError.cancelled }
            throw error
        }
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
        Diagnostics.log("list: \(public: session.visibleEntries.count) entries, \(public: table.numberOfRows) rows at \"\(currentPath)\"")
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

    /// The rows a command applies to. A right-click on a row outside the selection
    /// means that row alone, as it does in the Finder; `clickedRow` is only set while
    /// the contextual menu it opened is being used.
    private var commandRows: IndexSet {
        let selected = table.selectedRowIndexes
        let clicked = table.clickedRow
        if clicked >= 0, !selected.contains(clicked) { return IndexSet(integer: clicked) }
        return selected
    }

    func selectedNodesForCommand() -> [EntryTree.Node] {
        commandRows.compactMap { listSource.node(for: table.item(atRow: $0)) }
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
        // While an operation is running the list can still be looked through, but
        // nothing that reads from or writes to the archive may start.
        if isBusy || isLoading {
            switch action {
            case #selector(goBack(_:)), #selector(goForward(_:)), #selector(goUp(_:)),
                 #selector(toggleFolderTree(_:)), #selector(focusFilterField(_:)),
                 #selector(invertSelection(_:)), #selector(revealArchiveInFinder(_:)),
                 #selector(showArchiveInfo(_:)):
                break
            default:
                return false
            }
        }
        switch action {
        case #selector(addFiles(_:)):
            return session.canModifyContents
        case #selector(deleteSelected(_:)):
            // With the filter field being typed in, Command-Delete belongs to the
            // text, and a disabled menu item lets the key through to it.
            if view.window?.firstResponder is NSText { return false }
            return session.canModifyContents && !selectedNodesForCommand().isEmpty
        case #selector(renameSelected(_:)):
            // Files in a new archive still carry the names they have on disk; there is
            // nothing to rename until the archive has been saved.
            return session.canModifyContents && !session.isUntitled && selectedNodesForCommand().count == 1
        case #selector(saveArchive(_:)):
            // Saving in place only means something when there is something unsaved.
            return session.hasUnsavedChanges
        case #selector(saveArchiveAs(_:)):
            return !session.visibleEntries.isEmpty
        case #selector(testArchive(_:)), #selector(setPassword(_:)), #selector(showArchiveInfo(_:)),
             #selector(extractSelected(_:)), #selector(extractAll(_:)):
            return !session.isUntitled
        case #selector(goBack(_:)):
            return historyIndex > 0
        case #selector(goForward(_:)):
            return historyIndex + 1 < history.count
        case #selector(goUp(_:)):
            return !currentPath.isEmpty
        case #selector(openSelectedFile(_:)):
            return !selectedNodesForCommand().isEmpty
        case #selector(toggleQuickLook(_:)):
            // Quick Look previews files; with only folders selected it has nothing to show.
            return selectedNodesForCommand().contains { !$0.isDirectory }
        default:
            return true
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(setTextEncoding(_:)) {
            let current = session.encodingCodePage ?? 0
            menuItem.state = menuItem.tag == current ? .on : .off
            return ArchiveTextEncoding.isOverridable(session.format) && !session.isUntitled
                && !isBusy && !isLoading
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

    // MARK: - Dropping files in

    /// An untitled window nobody has put anything in yet.
    private var isBlank: Bool {
        session.isUntitled && !session.hasUnsavedChanges
    }

    /// Archives dropped on a blank window are meant to be opened, as dropping them on
    /// the Dock icon would. Dropped anywhere else they are files like any other, and
    /// go into the archive.
    private func isRequestToOpen(_ urls: [URL]) -> Bool {
        isBlank && urls.allSatisfy { url in
            // A folder that happens to be called "backup.zip" is still a folder.
            FormatRegistry.isArchive(url) && !url.hasDirectoryPath
                && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
        }
    }

    func canAcceptDrop(of urls: [URL]) -> Bool {
        guard !urls.isEmpty, !isBusy, !isLoading else { return false }
        return isRequestToOpen(urls) || session.canModifyContents
    }

    /// - Parameter folder: the folder row the files were dropped on, or nil when they
    ///   were dropped on the list as a whole and go where the list is.
    @discardableResult
    func handleDrop(of urls: [URL], into folder: String?) -> Bool {
        guard canAcceptDrop(of: urls) else { return false }
        if isRequestToOpen(urls), let onOpenArchives {
            // After the drop has finished, since opening replaces this very window.
            DispatchQueue.main.async { onOpenArchives(urls) }
            return true
        }
        add(items: urls, into: folder)
        return true
    }

    // MARK: - Helpers shared with the command extension

    func navigateToNode(_ node: EntryTree.Node) {
        navigate(to: node.path)
    }

    /// Root of this window's scratch space, where opened and previewed files land.
    func scratchRoot() -> URL { scratchDirectory }

    /// Where files opened for editing live. They stay put while the archive changes
    /// around them, because another app may have them open.
    func editingRoot() -> URL { scratchDirectory.appendingPathComponent("open") }

    /// Where files extracted only to be looked at live: Quick Look, dragging out,
    /// opening from an archive that cannot be changed. One folder per reload, so a
    /// copy made before the archive changed is never mistaken for what is in it now.
    func viewingRoot() -> URL { scratchDirectory.appendingPathComponent("view-\(listingGeneration)") }

    private func discardViewingCopies(before generation: Int) {
        let root = scratchDirectory
        DispatchQueue.global(qos: .utility).async {
            let stale = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            for name in stale where name.hasPrefix("view-") && name != "view-\(generation)" {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
            }
        }
    }

    /// Runs promise fulfilments one after another. The Finder asks for every dragged
    /// item at once, and for a solid archive each request decodes from the start.
    func enqueuePromise(_ work: @escaping @MainActor () async -> Void) {
        // Counted as work in hand from the moment it is asked for: a reload would
        // sweep away the folder being extracted into, and a closed window or a quit
        // would leave the Finder with half a file.
        beginOperation()
        let previous = promiseChain
        promiseChain = Task { @MainActor in
            await previous?.value
            await work()
            self.endOperation()
        }
    }

    // MARK: - Quick Look contents

    /// Fills the Quick Look panel from the selection.
    func loadPreviewItems(showing panel: QLPreviewPanel, thenOpen: Bool) {
        let nodes = selectedNodesForCommand().filter { !$0.isDirectory }
        guard !nodes.isEmpty else { return }
        previewRequest += 1
        let request = previewRequest
        Task {
            var urls: [URL] = []
            passwordPromptWasCancelled = false
            for node in nodes.prefix(20) {
                if let url = await materialize(node: node, quiet: true) { urls.append(url) }
                // The selection moved on while this was extracting.
                guard request == previewRequest else { return }
                // One refusal answers for the rest; asking again per file would not.
                if passwordPromptWasCancelled { break }
            }
            guard !urls.isEmpty else { return }
            setPreviewItems(urls)
            if thenOpen { panel.makeKeyAndOrderFront(nil) }
            panel.reloadData()
        }
    }

    /// Keeps an open Quick Look panel on whatever is selected, as the Finder's does.
    private func refreshQuickLookIfShowing() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(),
              panel.isVisible, (panel.dataSource as AnyObject?) === self, !isBusy else { return }
        loadPreviewItems(showing: panel, thenOpen: false)
    }

    func setPreviewItems(_ urls: [URL]) {
        previewItems = urls
    }

    /// Supplies a promise so entries, folders included, can be dragged straight
    /// into the Finder.
    func makePromise(for node: EntryTree.Node) -> NSFilePromiseProvider? {
        let type: UTType
        if node.isDirectory {
            type = .folder
        } else {
            guard node.entry != nil else { return nil }
            type = UTType(filenameExtension: (node.name as NSString).pathExtension) ?? .data
        }
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
            self.enqueuePromise {
                let produced = node.isDirectory
                    ? await self.materializeFolder(node: node)
                    : await self.materialize(node: node, quiet: true, mayAsk: false)
                guard let source = produced else {
                    completionHandler(ArchiveError.ioFailure(L("%@ could not be extracted.", node.name)))
                    return
                }
                // Off the main thread: to another volume this can take a while.
                let failure: Error? = await Task.detached(priority: .userInitiated) {
                    do {
                        if FileManager.default.fileExists(atPath: url.path) {
                            try FileManager.default.removeItem(at: url)
                        }
                        try FileManager.default.copyItem(at: source, to: url)
                        return nil
                    } catch {
                        return error
                    }
                }.value
                completionHandler(failure)
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

