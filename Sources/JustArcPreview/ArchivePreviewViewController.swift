import AppKit
import JustArcCore
import UniformTypeIdentifiers

/// Shows an archive's contents as a list of folders that open, the way the Finder
/// shows a folder. This is the whole of the Quick Look preview; the extension adds
/// only the protocol Quick Look calls it through.
open class ArchivePreviewViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let scrollView = NSScrollView()
    public let outlineView = NSOutlineView()

    public private(set) var preview: ArchivePreview?
    private var tree = EntryTree(entries: [])
    private var iconCache: [String: NSImage] = [:]

    private enum Column {
        static let name = NSUserInterfaceItemIdentifier("name")
        static let modified = NSUserInterfaceItemIdentifier("modified")
        static let size = NSUserInterfaceItemIdentifier("size")
    }

    open override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 520))

        iconView.imageScaling = .scaleProportionallyUpOrDown
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        summaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        for label in [titleLabel, summaryLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        let titles = NSStackView(views: [titleLabel, summaryLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 3
        let header = NSStackView(views: [iconView, titles])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        header.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16)

        let divider = NSBox()
        divider.boxType = .separator

        addColumn(Column.name, title: L("Name"), width: 420, resizes: true)
        addColumn(Column.modified, title: L("Modified"), width: 150, resizes: false)
        addColumn(Column.size, title: L("Size"), width: 90, resizes: false).headerCell.alignment = .right
        outlineView.outlineTableColumn = outlineView.tableColumns.first
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.rowSizeStyle = .default
        outlineView.style = .fullWidth
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.allowsMultipleSelection = true
        outlineView.dataSource = self
        outlineView.delegate = self

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        messageLabel.alignment = .center
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        messageLabel.isHidden = true

        for view in [header, divider, scrollView, messageLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 48),
            iconView.heightAnchor.constraint(equalToConstant: 48),

            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            divider.topAnchor.constraint(equalTo: header.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            messageLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -64),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
        ])

        view = root
        preferredContentSize = root.frame.size
    }

    @discardableResult
    private func addColumn(_ identifier: NSUserInterfaceItemIdentifier, title: String,
                           width: CGFloat, resizes: Bool) -> NSTableColumn {
        let column = NSTableColumn(identifier: identifier)
        column.title = title
        column.width = width
        column.minWidth = resizes ? 160 : width
        column.resizingMask = resizes ? [.autoresizingMask, .userResizingMask] : .userResizingMask
        outlineView.addTableColumn(column)
        return column
    }

    // MARK: - Showing an archive

    /// Reads the archive and shows it. Never throws: what could not be read is said
    /// in the preview, under the archive's name, which is more use than the blank
    /// icon Quick Look falls back to.
    public func prepare(for url: URL) async {
        show(await ArchivePreview.load(url))
    }

    public func show(_ preview: ArchivePreview) {
        loadViewIfNeeded()
        self.preview = preview

        iconView.image = NSWorkspace.shared.icon(forFile: preview.url.path)
        titleLabel.stringValue = FileManager.default.displayName(atPath: preview.url.path)
        summaryLabel.stringValue = preview.summary
        summaryLabel.toolTip = preview.summary

        if case .listing(let listing) = preview.contents {
            tree = EntryTree(entries: listing.entries)
        } else {
            tree = EntryTree(entries: [])
        }
        outlineView.reloadData()
        // An archive of one folder is opened onto what is in it, since the folder
        // by itself says nothing the archive's name did not.
        if tree.root.children.count == 1, let only = tree.root.children.first, only.isDirectory {
            outlineView.expandItem(only)
        }

        let message = preview.message
        messageLabel.stringValue = message ?? ""
        messageLabel.isHidden = message == nil
        scrollView.isHidden = message != nil
    }

    // MARK: - NSOutlineViewDataSource

    private func node(_ item: Any?) -> EntryTree.Node {
        (item as? EntryTree.Node) ?? tree.root
    }

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        node(item).children.count
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        node(item).children[index]
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        let node = node(item)
        return node.isDirectory && !node.children.isEmpty
    }

    // MARK: - NSOutlineViewDelegate

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let identifier = tableColumn?.identifier else { return nil }
        let node = node(item)
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
            ?? makeCell(identifier)

        switch identifier {
        case Column.name:
            cell.textField?.stringValue = node.name
            cell.imageView?.image = icon(for: node)
        case Column.modified:
            cell.textField?.stringValue = Formatting.date(node.entry?.modified)
        default:
            // A folder's size is the sum of what is in it, as the Finder shows it.
            cell.textField?.stringValue = Formatting.bytes(node.totalSize)
        }
        return cell
    }

    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        text.lineBreakMode = identifier == Column.name ? .byTruncatingMiddle : .byTruncatingTail
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.addSubview(text)
        cell.textField = text

        guard identifier == Column.name else {
            text.textColor = .secondaryLabelColor
            text.alignment = identifier == Column.size ? .right : .left
            text.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.imageView = image
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func icon(for node: EntryTree.Node) -> NSImage {
        let key = node.isDirectory ? ":folder:" : (node.name as NSString).pathExtension.lowercased()
        if let cached = iconCache[key] { return cached }

        let image: NSImage
        if node.isDirectory {
            image = NSWorkspace.shared.icon(for: .folder)
        } else if let type = UTType(filenameExtension: key) {
            image = NSWorkspace.shared.icon(for: type)
        } else {
            image = NSWorkspace.shared.icon(for: .data)
        }
        image.size = NSSize(width: 16, height: 16)
        iconCache[key] = image
        return image
    }
}
