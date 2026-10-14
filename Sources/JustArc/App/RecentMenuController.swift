import AppKit
import JustArcCore

/// Records an archive as recently used, in both places that care.
@MainActor
enum RecentsRecorder {
    static func note(_ url: URL) {
        RecentArchives.shared.note(url)
        // In the App Store edition, kept so that Open Recent can open it again later.
        FolderAccess.shared.remember(file: url)
        // This is what puts the archive in the system's Recent Items as well.
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }
}

/// Backs File ▸ Open Recent and the recent items on the Dock icon's menu.
/// The menu is rebuilt each time it opens, so it never shows an archive that moved.
@MainActor
final class RecentMenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu(title: L("Open Recent"))
    var open: ((URL) -> Void)?

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = RecentArchives.shared.urls
        if urls.isEmpty {
            let empty = NSMenuItem(title: L("No Recent Archives"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for item in items(for: urls, iconSize: 16) { menu.addItem(item) }
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: L("Clear Menu"), action: #selector(clearRecents(_:)),
                               keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !urls.isEmpty
        menu.addItem(clear)
    }

    /// The Dock menu lists the same archives, without icons, the way stock apps do.
    func dockMenu() -> NSMenu? {
        let urls = RecentArchives.shared.urls
        guard !urls.isEmpty else { return nil }
        let dock = NSMenu()
        for item in items(for: urls, iconSize: nil) { dock.addItem(item) }
        return dock
    }

    /// Two archives with the same name are told apart by their folder, as Finder does.
    private func items(for urls: [URL], iconSize: CGFloat?) -> [NSMenuItem] {
        let names = urls.map(\.lastPathComponent)
        return urls.map { url in
            let name = url.lastPathComponent
            let title = names.filter { $0 == name }.count > 1
                ? "\(name) — \(url.deletingLastPathComponent().lastPathComponent)"
                : name
            let item = NSMenuItem(title: title, action: #selector(openItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.deletingLastPathComponent().path
            if let iconSize {
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: iconSize, height: iconSize)
                item.image = icon
            }
            return item
        }
    }

    @objc private func openItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            RecentArchives.shared.remove(url)
            NSSound.beep()
            return
        }
        FolderAccess.shared.reopen(url)
        open?(url)
    }

    @objc func clearRecents(_ sender: Any?) {
        RecentArchives.shared.clear()
        NSDocumentController.shared.clearRecentDocuments(nil)
    }
}
