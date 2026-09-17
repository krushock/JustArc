import AppKit
import JustArcCore

/// One window per archive, plus the untitled window shown on a bare launch.
final class ArchiveWindowController: NSWindowController, NSWindowDelegate {
    let session: ArchiveSession
    private let browser: ArchiveBrowserViewController

    var onClose: (() -> Void)?

    init(archive: URL?) {
        let session = ArchiveSession(archiveURL: archive)
        self.session = session
        self.browser = ArchiveBrowserViewController(session: session)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.minSize = NSSize(width: 620, height: 340)
        window.contentViewController = browser
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("JustArcArchiveWindow")
        super.init(window: window)

        window.delegate = self
        browser.onTitleChange = { [weak window] title, url in
            window?.title = title
            window?.representedURL = url
        }
        window.title = session.displayName
        window.representedURL = archive
        if archive == nil { window.center() }
        else { cascadeIfNeeded(window) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func cascadeIfNeeded(_ window: NSWindow) {
        let others = NSApp.windows.filter { $0 !== window && $0.isVisible }
        if let last = others.last {
            window.setFrameOrigin(last.cascadeTopLeft(from: last.frame.origin))
        } else {
            window.center()
        }
    }

    func loadArchive() {
        browser.loadArchive()
    }

    func reloadFromSession() {
        browser.reloadFromSession()
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard session.hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(session.displayName)?"
        alert.informativeText = "The files you added have not been written to an archive yet."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
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
