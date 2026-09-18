import AppKit
import JustArcCore

/// One window per archive, plus the untitled window shown on a bare launch.
///
/// The window is a plain `NSSplitViewController` under a unified `NSToolbar`, which is
/// how Mail and Finder are built. Everything the system knows how to draw is left to
/// the system: the sidebar's material, the toolbar's glass and capsules, the scroll
/// edge effect and the title bar's separator.
@MainActor
final class ArchiveWindowController: NSWindowController, NSWindowDelegate,
                                     NSToolbarDelegate, NSSearchFieldDelegate {
    let session: ArchiveSession
    private let browser: ArchiveBrowserViewController
    private let sidebar = SidebarViewController()
    private let splitController = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem!
    private weak var searchItem: NSSearchToolbarItem?

    var onClose: (() -> Void)?

    init(archive: URL?) {
        let session = ArchiveSession(archiveURL: archive)
        self.session = session
        self.browser = ArchiveBrowserViewController(session: session)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                          .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        window.minSize = NSSize(width: 680, height: 380)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("JustArcArchiveWindow")
        // Unified puts the title beside the toolbar items rather than on its own row,
        // which is the shape every stock app uses now.
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        super.init(window: window)

        buildSplitView()
        window.contentViewController = splitController
        window.toolbar = ArchiveToolbar.makeToolbar(delegate: self)
        window.delegate = self

        wireCallbacks(window: window)
        window.title = session.displayName
        window.representedURL = archive
        if archive == nil { window.center() } else { cascadeIfNeeded(window) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func buildSplitView() {
        // A sidebar split item is what grants the source list its vibrant material;
        // building the same thing by hand would only approximate it.
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 340
        sidebarItem.canCollapse = true
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.titlebarSeparatorStyle = .none
        sidebarItem.isCollapsed = !Preferences.showFolderTree

        let contentItem = NSSplitViewItem(viewController: browser)
        contentItem.minimumThickness = 460
        contentItem.titlebarSeparatorStyle = .automatic

        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(contentItem)
    }

    private func wireCallbacks(window: NSWindow) {
        browser.onTitleChange = { [weak window] title, url in
            window?.title = title
            window?.representedURL = url
        }
        // The location inside the archive belongs in the subtitle, where a stock app
        // puts it, rather than in a home-made address bar.
        browser.onLocationChange = { [weak window] path in
            window?.subtitle = path.isEmpty ? "" : path.replacingOccurrences(of: "/", with: " › ")
        }
        browser.onTreeChange = { [weak self] tree, name, path in
            self?.sidebar.reload(tree: tree, archiveName: name)
            self?.sidebar.select(path: path)
        }
        browser.onToggleSidebar = { [weak self] in
            guard let self else { return }
            sidebarItem.animator().isCollapsed.toggle()
            Preferences.showFolderTree = !sidebarItem.isCollapsed
        }
        browser.onFocusFilter = { [weak self] in
            self?.searchItem?.beginSearchInteraction()
        }
        sidebar.onSelect = { [weak self] path in
            self?.browser.navigate(to: path)
        }
    }

    private func cascadeIfNeeded(_ window: NSWindow) {
        let others = NSApp.windows.filter { $0 !== window && $0.isVisible }
        if let last = others.last {
            window.setFrameOrigin(last.cascadeTopLeft(from: last.frame.origin))
        } else {
            window.center()
        }
    }

    func loadArchive() { browser.loadArchive() }
    func reloadFromSession() { browser.reloadFromSession() }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ArchiveToolbar.defaultIdentifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ArchiveToolbar.allowedIdentifiers
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == ArchiveToolbar.ID.search {
            let item = ArchiveToolbar.makeSearchItem(delegate: self)
            searchItem = item
            return item
        }
        if let group = ArchiveToolbar.makeGroup(for: identifier) { return group }
        // Standard identifiers such as toggleSidebar and the tracking separator are
        // supplied by AppKit when the delegate returns nothing.
        return ArchiveToolbar.makeItem(for: identifier)
    }

    // MARK: - Search field

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField else { return }
        browser.setFilter(field.stringValue)
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        browser.setFilter("")
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard session.hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = L("Save changes to %@?", session.displayName)
        alert.informativeText = L("The files you added have not been written to an archive yet.")
        alert.addButton(withTitle: L("Save…"))
        alert.addButton(withTitle: L("Discard"))
        alert.addButton(withTitle: L("Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            browser.saveArchiveAs(nil)
            return !session.hasUnsavedChanges
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Detaches the disk image, if this window had one mounted.
        session.close()
        onClose?()
    }
}
