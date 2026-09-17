import AppKit
import JustArcCore

/// WinRAR's optional left-hand folder tree. Shows directories only; selecting one
/// navigates the file list to it.
@MainActor
final class FolderTreeView: NSObject {
    let outlineView = NSOutlineView()
    weak var scrollView: NSScrollView?

    var onSelect: ((String) -> Void)?

    private var rootNode: EntryTree.Node?
    private var archiveName = ""
    private var suppressSelectionCallback = false

    override init() {
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        column.title = "Folders"
        column.width = 190
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = 20
        outlineView.style = .sourceList
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.autoresizesOutlineColumn = true
    }

    func reload(tree: EntryTree, archiveName: String) {
        self.rootNode = tree.root
        self.archiveName = archiveName
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: false)
        if let root = rootNode {
            outlineView.expandItem(RootMarker.shared)
            for child in root.children where child.isDirectory {
                _ = child
            }
        }
    }

    func select(path: String) {
        guard let rootNode else { return }
        suppressSelectionCallback = true
        defer { suppressSelectionCallback = false }

        if path.isEmpty {
            let row = outlineView.row(forItem: RootMarker.shared)
            if row >= 0 { outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            return
        }
        // Expand every ancestor so the target row exists before selecting it.
        var accumulated = ""
        var chain: [EntryTree.Node] = []
        for component in path.split(separator: "/") {
            accumulated = ArchivePath.join(accumulated, String(component))
            guard let node = findNode(from: rootNode, path: accumulated) else { break }
            chain.append(node)
        }
        outlineView.expandItem(RootMarker.shared)
        for node in chain.dropLast() { outlineView.expandItem(node) }
        guard let target = chain.last else { return }
        let row = outlineView.row(forItem: target)
        if row >= 0 { outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    }

    private func findNode(from root: EntryTree.Node, path: String) -> EntryTree.Node? {
        if root.path == path { return root }
        for child in root.children {
            if path == child.path { return child }
            if path.hasPrefix(child.path + "/"), let found = findNode(from: child, path: path) {
                return found
            }
        }
        return nil
    }

    private func folders(of node: EntryTree.Node) -> [EntryTree.Node] {
        node.children.filter(\.isDirectory)
    }
}

/// Stands in for the archive itself at the top of the tree.
final class RootMarker: NSObject {
    static let shared = RootMarker()
}

extension FolderTreeView: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let rootNode else { return 0 }
        if item == nil { return 1 }
        if item is RootMarker { return folders(of: rootNode).count }
        guard let node = item as? EntryTree.Node else { return 0 }
        return folders(of: node).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let rootNode else { return RootMarker.shared }
        if item == nil { return RootMarker.shared }
        if item is RootMarker { return folders(of: rootNode)[index] }
        guard let node = item as? EntryTree.Node else { return RootMarker.shared }
        return folders(of: node)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if item is RootMarker { return true }
        guard let node = item as? EntryTree.Node else { return false }
        return !folders(of: node).isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("folderCell")
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            let text = NSTextField(labelWithString: "")
            text.font = .systemFont(ofSize: 12)
            text.lineBreakMode = .byTruncatingMiddle
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.addSubview(text)
            cell.imageView = image
            cell.textField = text
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        if item is RootMarker {
            cell.textField?.stringValue = archiveName
            cell.imageView?.image = NSImage(systemSymbolName: "doc.zipper", accessibilityDescription: nil)
        } else if let node = item as? EntryTree.Node {
            cell.textField?.stringValue = node.name
            let folderIcon = NSWorkspace.shared.icon(for: .folder)
            folderIcon.size = NSSize(width: 16, height: 16)
            cell.imageView?.image = folderIcon
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallback else { return }
        let row = outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) else { return }
        if item is RootMarker {
            onSelect?("")
        } else if let node = item as? EntryTree.Node {
            onSelect?(node.path)
        }
    }
}
