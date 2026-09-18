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

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                          .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        window.minSize = NSSize(width: 680, height: 380)
        window.isReleasedWhenClosed = false
        // Unified puts the title beside the toolbar items rather than on its own row,
        // which is the shape every stock app uses now.
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        super.init(window: window)

        buildSplitView()
        window.contentViewController = splitController
        // Assigning a content view controller sizes the window to that controller's
        // view, which is narrower than the toolbar needs, so the size is set again.
        window.setContentSize(NSSize(width: 1060, height: 640))
        window.toolbar = ArchiveToolbar.makeToolbar(delegate: self)
        window.delegate = self
        window.setFrameAutosaveName("JustArcArchiveWindow.v2")

        wireCallbacks(window: window)
        window.title = session.displayName
        window.representedURL = archive
        if archive == nil { window.center() } else { cascadeIfNeeded(window) }
        scheduleSnapshotIfRequested()
    }

    /// Debugging aid: with JUSTARC_SNAPSHOT set to a path, the first window renders
    /// itself, title bar and toolbar included, to a PNG and the app quits. The
    /// appearance can then be checked from a terminal without screen recording access.
    private func scheduleSnapshotIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["JUSTARC_SNAPSHOT"],
              !path.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let window = self?.window,
                  let frameView = window.contentView?.superview else { return }
            frameView.layoutSubtreeIfNeeded()
            guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
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
        sidebarItem.isCollapsed = !Preferences.showSidebar

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
        browser.onArchiveChange = { [weak self] url in
            self?.sidebar.currentArchive = url
        }
        browser.onToggleSidebar = { [weak self] in
            guard let self else { return }
            sidebarItem.animator().isCollapsed.toggle()
            Preferences.showSidebar = !sidebarItem.isCollapsed
        }
        browser.onFocusFilter = { [weak self] in
            self?.searchItem?.beginSearchInteraction()
        }
        sidebar.currentArchive = session.archiveURL
        sidebar.onOpen = { url in
            (NSApp.delegate as? AppDelegate)?.openInBrowser(url)
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

    /// An untitled window nobody has touched. Opening an archive takes its place
    /// instead of leaving an empty window behind, the way TextEdit treats a blank page.
    var isPristine: Bool {
        session.isUntitled && !session.hasUnsavedChanges
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
        if let group = ArchiveToolbar.makeGroup(for: identifier, handler: browser) { return group }
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
