import AppKit
import JustArcCore

/// The address row: an "up one level" button and a pull-down showing the current
/// location inside the archive, plus the filter field on the right.
final class ArchivePathBar: NSView {
    private let upButton = NSButton()
    private let pathButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let filterField = NSSearchField()

    var onGoUp: (() -> Void)?
    var onNavigate: ((String) -> Void)?
    var onFilterChanged: ((String) -> Void)?

    private var ancestorPaths: [String] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 32)
    }

    private func build() {
        upButton.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Enclosing folder")
        upButton.bezelStyle = .texturedRounded
        upButton.target = self
        upButton.action = #selector(goUp)
        upButton.toolTip = "Go to the enclosing folder"
        upButton.widthAnchor.constraint(equalToConstant: 30).isActive = true

        pathButton.target = self
        pathButton.action = #selector(pathSelected)
        pathButton.bezelStyle = .texturedRounded

        filterField.placeholderString = "Filter"
        filterField.target = self
        filterField.action = #selector(filterChanged)
        filterField.sendsWholeSearchString = false
        filterField.sendsSearchStringImmediately = true
        filterField.widthAnchor.constraint(equalToConstant: 180).isActive = true

        let stack = NSStackView(views: [upButton, pathButton, NSView(), filterField])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Rebuilds the pull-down so every ancestor of the current folder is reachable.
    func update(archiveName: String, currentPath: String, icon: NSImage?) {
        upButton.isEnabled = !currentPath.isEmpty

        var titles: [String] = [archiveName]
        ancestorPaths = [""]
        var accumulated = ""
        for component in currentPath.split(separator: "/") {
            accumulated = ArchivePath.join(accumulated, String(component))
            titles.append(String(component))
            ancestorPaths.append(accumulated)
        }

        pathButton.removeAllItems()
        // A pull-down button shows item 0 as its label, so the deepest component leads.
        let display = titles.reversed().enumerated()
        for (offset, title) in display {
            pathButton.addItem(withTitle: title)
            if let item = pathButton.lastItem {
                item.indentationLevel = offset == 0 ? 0 : 1
                if offset == 0 { item.image = icon }
            }
        }
        pathButton.itemArray.first?.title = titles.joined(separator: " ▸ ")
    }

    @objc private func goUp() { onGoUp?() }

    @objc private func pathSelected() {
        let index = pathButton.indexOfSelectedItem
        // Item 0 is the label; the rest run from deepest to shallowest.
        guard index > 0 else { return }
        let reversedIndex = ancestorPaths.count - index
        guard ancestorPaths.indices.contains(reversedIndex) else { return }
        onNavigate?(ancestorPaths[reversedIndex])
    }

    @objc private func filterChanged() {
        onFilterChanged?(filterField.stringValue)
    }

    func focusFilter() {
        window?.makeFirstResponder(filterField)
    }
}
