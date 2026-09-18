import AppKit
import JustArcCore

/// The sidebar: recently used archives, laid out like the source lists in Disk
/// Utility and Mail, with a section heading over the items.
///
/// It used to repeat the folder tree, which the file list already shows. A second
/// copy of the same tree only competed for width, so the sidebar now holds something
/// the list cannot: a way to get to other archives.
///
/// Created through `NSSplitViewItem(sidebarWithViewController:)`, which is what gives
/// it the system sidebar material.
@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let outline = NSOutlineView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: L("No Recent Archives"))
    /// Held as the same `NSURL` instances throughout, because an outline view tracks
    /// its items by object, and bridging a `URL` afresh on every call would hand it
    /// a different object each time and quietly break selection.
    private var recents: [NSURL] = []
    private var changeObserver: NSObjectProtocol?

    /// The section heading is an object of its own so the outline can tell it apart.
    private final class Section: NSObject {
        let title: String
        init(title: String) { self.title = title }
    }
    private let recentSection = Section(title: L("Recent"))

    /// The archive shown in this window, highlighted as "you are here".
    var currentArchive: URL? {
        didSet { selectCurrent() }
    }

    var onOpen: ((URL) -> Void)?

    override func loadView() {
        view = NSView()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("recent"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.backgroundColor = .clear
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)

        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        emptyLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 12),
        ])

        changeObserver = NotificationCenter.default.addObserver(
            forName: RecentArchives.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        reload()
    }

    deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
    }

    func reload() {
        recents = RecentArchives.shared.urls.map { $0 as NSURL }
        outline.reloadData()
        outline.expandItem(recentSection)
        emptyLabel.isHidden = !recents.isEmpty
        selectCurrent()
    }

    private func selectCurrent() {
        guard isViewLoaded else { return }
        guard let currentArchive,
              let match = recents.first(where: {
                  ($0 as URL).standardizedFileURL == currentArchive.standardizedFileURL }) else {
            outline.deselectAll(nil)
            return
        }
        let row = outline.row(forItem: match)
        if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    }

    @objc private func rowClicked() {
        let row = outline.clickedRow
        guard row >= 0, let url = (outline.item(atRow: row) as? NSURL) as URL? else { return }
        onOpen?(url)
        // This window keeps showing its own archive, so put the marker back.
        selectCurrent()
    }

    // MARK: - Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return recents.isEmpty ? 0 : 1 }
        return item is Section ? recents.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return recentSection }
        return recents[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is Section
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is Section
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        !(item is Section)
    }

    // MARK: - Cells

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        if let section = item as? Section {
            let identifier = NSUserInterfaceItemIdentifier("sidebarHeader")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
                ?? makeCell(identifier: identifier, withImage: false)
            cell.textField?.stringValue = section.title
            return cell
        }

        guard let url = (item as? NSURL) as URL? else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("sidebarRecent")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
            ?? makeCell(identifier: identifier, withImage: true)
        cell.textField?.stringValue = FormatRegistry.baseName(for: url)
        cell.toolTip = url.path
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 18, height: 18)
        cell.imageView?.image = icon
        return cell
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier, withImage: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text

        if withImage {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 18),
                image.heightAnchor.constraint(equalToConstant: 18),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            ])
        } else {
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
        }
        NSLayoutConstraint.activate([
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
