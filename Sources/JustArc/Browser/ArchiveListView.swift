import AppKit
import JustArcCore
import UniformTypeIdentifiers

/// Stands in for the ".." row WinRAR puts at the top of every subfolder.
final class ParentFolderMarker: NSObject {
    static let shared = ParentFolderMarker()
}

enum ArchiveColumn: String, CaseIterable {
    case name, size, packed, type, modified, crc

    var title: String {
        switch self {
        case .name: return L("Name")
        case .size: return L("Size")
        case .packed: return L("Packed")
        case .type: return L("Type")
        case .modified: return L("Modified")
        case .crc: return "CRC32"
        }
    }

    var width: CGFloat {
        switch self {
        case .name: return 280
        case .size: return 90
        case .packed: return 90
        case .type: return 130
        case .modified: return 140
        case .crc: return 80
        }
    }

    var isRightAligned: Bool {
        self == .size || self == .packed
    }
}

/// Outline view so folders can be expanded in place, the way Finder's list view works,
/// while double-clicking still navigates into them.
///
/// Routes the keys people expect from a file list: Return opens, Space previews,
/// Delete removes, and Command-Delete goes up a level.
final class ArchiveOutlineView: NSOutlineView {
    var onOpen: (() -> Void)?
    var onPreview: (() -> Void)?
    var onDelete: (() -> Void)?
    var onGoUp: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Return, Enter
            onOpen?()
        case 49: // Space
            onPreview?()
        case 51, 117: // Delete, forward delete
            onDelete?()
        case 126 where event.modifierFlags.contains(.command): // Command-Up
            onGoUp?()
        default:
            super.keyDown(with: event)
        }
    }

    /// Without this the outline view swallows clicks meant to change the selection
    /// in cells that contain controls.
    override func validateProposedFirstResponder(_ responder: NSResponder,
                                                 for event: NSEvent?) -> Bool {
        true
    }
}

/// Supplies the rows for the current folder and renders each cell.
final class ArchiveListDataSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private var tree = EntryTree(entries: [])
    private var currentPath = ""
    private var filterText = ""
    private(set) var rootItems: [Any] = []

    /// Sorting a node's children on every outline callback would be wasteful, so the
    /// result is kept until the next reload.
    private var sortedChildren: [ObjectIdentifier: [EntryTree.Node]] = [:]
    private var iconCache: [String: NSImage] = [:]

    var sortColumn: ArchiveColumn = .name
    var sortAscending = true

    var onSelectionChange: (() -> Void)?
    var onSortChange: ((ArchiveColumn, Bool) -> Void)?
    var onDropFiles: (([URL]) -> Void)?
    var promiseProvider: ((EntryTree.Node) -> NSFilePromiseProvider?)?

    /// True while a filter narrows the list, when a flat list of matches is clearer
    /// than a tree the user would have to expand to see anything.
    var isFiltering: Bool {
        !filterText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func reload(tree: EntryTree, path: String, filter: String) {
        self.tree = tree
        self.currentPath = path
        self.filterText = filter
        sortedChildren.removeAll()

        var nodes: [EntryTree.Node]
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            nodes = tree.children(at: path)
        } else if path.isEmpty {
            // An empty path means "search the whole archive", like WinRAR's Find.
            nodes = tree.root.descendantNodes().filter {
                $0.name.localizedCaseInsensitiveContains(trimmed)
            }
        } else {
            nodes = tree.children(at: path).filter {
                $0.name.localizedCaseInsensitiveContains(trimmed)
            }
        }

        nodes.sort(by: comparator)
        rootItems = nodes.map { $0 as Any }
        if !path.isEmpty { rootItems.insert(ParentFolderMarker.shared, at: 0) }
    }

    func node(for item: Any?) -> EntryTree.Node? {
        item as? EntryTree.Node
    }

    private func children(of node: EntryTree.Node) -> [EntryTree.Node] {
        if isFiltering { return [] }
        let key = ObjectIdentifier(node)
        if let cached = sortedChildren[key] { return cached }
        let sorted = node.children.sorted(by: comparator)
        sortedChildren[key] = sorted
        return sorted
    }

    private func comparator(_ lhs: EntryTree.Node, _ rhs: EntryTree.Node) -> Bool {
        // Folders always lead, exactly as WinRAR and Finder sort them.
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        let ascending = sortAscending
        func apply(_ result: Bool) -> Bool { ascending ? result : !result }

        switch sortColumn {
        case .name:
            return apply(lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending)
        case .size:
            return apply(lhs.totalSize < rhs.totalSize)
        case .packed:
            return apply(lhs.totalPacked < rhs.totalPacked)
        case .type:
            return apply(Self.typeDescription(for: lhs)
                .localizedStandardCompare(Self.typeDescription(for: rhs)) == .orderedAscending)
        case .modified:
            let left = lhs.entry?.modified ?? .distantPast
            let right = rhs.entry?.modified ?? .distantPast
            return apply(left < right)
        case .crc:
            return apply((lhs.entry?.crc ?? "").compare(rhs.entry?.crc ?? "") == .orderedAscending)
        }
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return rootItems.count }
        guard let node = node(for: item) else { return 0 }
        return children(of: node).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else { return rootItems[index] }
        guard let node = node(for: item) else { return ParentFolderMarker.shared }
        return children(of: node)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = node(for: item), node.isDirectory else { return false }
        return !children(of: node).isEmpty
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView,
                     viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        guard let identifier = tableColumn?.identifier.rawValue,
              let column = ArchiveColumn(rawValue: identifier) else { return nil }

        let cell = makeCell(outlineView: outlineView, column: column)
        configure(cell: cell, column: column, item: item)
        return cell
    }

    private func makeCell(outlineView: NSOutlineView, column: ArchiveColumn) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier("cell.\(column.rawValue)")
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
            return reused
        }

        let cell = NSTableCellView()
        cell.identifier = identifier

        let text = NSTextField(labelWithString: "")
        text.font = .systemFont(ofSize: 12)
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        text.alignment = column.isRightAligned ? .right : .left
        if column == .crc {
            text.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            text.textColor = .secondaryLabelColor
        }
        cell.addSubview(text)
        cell.textField = text

        if column == .name {
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
            ])
        } else {
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4).isActive = true
        }

        NSLayoutConstraint.activate([
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func configure(cell: NSTableCellView, column: ArchiveColumn, item: Any) {
        guard let node = node(for: item) else {
            cell.textField?.stringValue = column == .name ? ".." : ""
            cell.textField?.textColor = .secondaryLabelColor
            if column == .name {
                cell.imageView?.image = NSImage(systemSymbolName: "arrow.turn.left.up",
                                                accessibilityDescription: L("Enclosing folder"))
                cell.imageView?.contentTintColor = .secondaryLabelColor
            }
            return
        }

        cell.textField?.textColor = .labelColor
        switch column {
        case .name:
            // While filtering the whole archive, the bare name is ambiguous, so show
            // where the match actually lives.
            cell.textField?.stringValue = isFiltering && currentPath.isEmpty ? node.path : node.name
            cell.imageView?.contentTintColor = nil
            cell.imageView?.image = icon(for: node)
        case .size:
            cell.textField?.stringValue = Formatting.exactBytes(node.totalSize)
        case .packed:
            cell.textField?.stringValue = node.totalPacked > 0
                ? Formatting.exactBytes(node.totalPacked) : ""
        case .type:
            cell.textField?.stringValue = Self.typeDescription(for: node)
        case .modified:
            cell.textField?.stringValue = Formatting.date(node.entry?.modified)
        case .crc:
            cell.textField?.stringValue = node.entry?.crc ?? ""
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        onSelectionChange?()
    }

    func outlineView(_ outlineView: NSOutlineView,
                     sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = outlineView.sortDescriptors.first,
              let key = descriptor.key,
              let column = ArchiveColumn(rawValue: key) else { return }
        onSortChange?(column, descriptor.ascending)
    }

    // MARK: - Dragging

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = node(for: item) else { return nil }
        return promiseProvider?(node)
    }

    func outlineView(_ outlineView: NSOutlineView,
                     validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        // Only accept files coming from outside the archive window.
        guard (info.draggingSource as? NSOutlineView) !== outlineView else { return [] }
        outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .copy
    }

    func outlineView(_ outlineView: NSOutlineView,
                     acceptDrop info: NSDraggingInfo,
                     item: Any?,
                     childIndex index: Int) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                            options: options) as? [URL],
              !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }

    // MARK: - Presentation helpers

    static func typeDescription(for node: EntryTree.Node) -> String {
        if node.isDirectory { return L("Folder") }
        let ext = (node.name as NSString).pathExtension
        guard !ext.isEmpty else { return L("Document") }
        if let type = UTType(filenameExtension: ext), let description = type.localizedDescription {
            return description.prefix(1).uppercased() + description.dropFirst()
        }
        return L("%@ file", ext.uppercased())
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

extension EntryTree.Node {
    /// Flattened view used by the archive-wide filter.
    func descendantNodes() -> [EntryTree.Node] {
        children + children.flatMap { $0.descendantNodes() }
    }
}
