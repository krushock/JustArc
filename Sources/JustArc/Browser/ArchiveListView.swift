import AppKit
import UniformTypeIdentifiers
import JustArcCore

/// A row in the file list. WinRAR puts a ".." row at the top of every subfolder.
enum ArchiveRow {
    case parentFolder
    case node(EntryTree.Node)

    var node: EntryTree.Node? {
        if case .node(let node) = self { return node }
        return nil
    }

    var entry: ArchiveEntry? { node?.entry }
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

/// Table subclass that routes the keys WinRAR responds to: Return opens,
/// Space previews, Delete removes, Backspace goes up a level.
final class ArchiveTableView: NSTableView {
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
        case 51: // Delete
            if event.modifierFlags.contains(.command) { onGoUp?() } else { onDelete?() }
        case 117: // Forward delete
            onDelete?()
        default:
            super.keyDown(with: event)
        }
    }

    override func validateProposedFirstResponder(_ responder: NSResponder,
                                                 for event: NSEvent?) -> Bool {
        true
    }
}

/// Builds the rows for the current folder and renders each cell.
final class ArchiveListDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var rows: [ArchiveRow] = []
    private var iconCache: [String: NSImage] = [:]

    var sortColumn: ArchiveColumn = .name
    var sortAscending = true

    var onSelectionChange: (() -> Void)?
    var onSortChange: ((ArchiveColumn, Bool) -> Void)?
    var onDropFiles: (([URL]) -> Void)?
    var promiseProvider: ((EntryTree.Node) -> NSFilePromiseProvider?)?

    /// Recomputes the visible rows for a folder, applying the filter text.
    func reload(tree: EntryTree, path: String, filter: String) {
        var children = tree.children(at: path)

        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            if path.isEmpty {
                // An empty path means "search the whole archive", like WinRAR's Find.
                children = tree.root.descendantNodes().filter {
                    $0.name.localizedCaseInsensitiveContains(trimmed)
                }
            } else {
                children = children.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
            }
        }

        children.sort(by: comparator)
        rows = children.map { ArchiveRow.node($0) }
        if !path.isEmpty { rows.insert(.parentFolder, at: 0) }
    }

    private func comparator(_ lhs: EntryTree.Node, _ rhs: EntryTree.Node) -> Bool {
        // Folders always lead, exactly as WinRAR sorts them.
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

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier.rawValue,
              let column = ArchiveColumn(rawValue: identifier),
              rows.indices.contains(row) else { return nil }

        let cell = makeCell(tableView: tableView, column: column)
        configure(cell: cell, column: column, row: rows[row])
        return cell
    }

    private func makeCell(tableView: NSTableView, column: ArchiveColumn) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier("cell.\(column.rawValue)")
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
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

    private func configure(cell: NSTableCellView, column: ArchiveColumn, row: ArchiveRow) {
        switch row {
        case .parentFolder:
            cell.textField?.stringValue = column == .name ? ".." : ""
            cell.textField?.textColor = .secondaryLabelColor
            if column == .name {
                cell.imageView?.image = NSImage(systemSymbolName: "arrow.turn.left.up",
                                                accessibilityDescription: L("Enclosing folder"))
                cell.imageView?.contentTintColor = .secondaryLabelColor
            }

        case .node(let node):
            cell.textField?.textColor = .labelColor
            switch column {
            case .name:
                cell.textField?.stringValue = node.name
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

    // MARK: - Selection, sorting and dragging

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelectionChange?()
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key,
              let column = ArchiveColumn(rawValue: key) else { return }
        onSortChange?(column, descriptor.ascending)
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard rows.indices.contains(row), let node = rows[row].node else { return nil }
        return promiseProvider?(node)
    }

    func tableView(_ tableView: NSTableView,
                   validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource == nil || (info.draggingSource as? NSTableView) !== tableView else {
            return []
        }
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(_ tableView: NSTableView,
                   acceptDrop info: NSDraggingInfo,
                   row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                            options: options) as? [URL],
              !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }
}

extension EntryTree.Node {
    /// Flattened view used by the archive-wide filter.
    func descendantNodes() -> [EntryTree.Node] {
        children + children.flatMap { $0.descendantNodes() }
    }
}
