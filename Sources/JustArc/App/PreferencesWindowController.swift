import AppKit
import JustArcCore
import UniformTypeIdentifiers

/// A single settings pane covering the Quick Extract behaviour and archive defaults.
final class PreferencesWindowController: NSWindowController {
    private let destinationPopUp = NSPopUpButton()
    private let smartFolderBox = NSButton(checkboxWithTitle: "Create a folder when the archive has loose files",
                                          target: nil, action: nil)
    private let revealBox = NSButton(checkboxWithTitle: "Reveal the result in Finder", target: nil, action: nil)
    private let trashBox = NSButton(checkboxWithTitle: "Move the archive to the Trash afterwards",
                                    target: nil, action: nil)
    private let quitBox = NSButton(checkboxWithTitle: "Quit after extracting", target: nil, action: nil)
    private let browseBox = NSButton(checkboxWithTitle: "Open archives in a window instead of extracting",
                                     target: nil, action: nil)
    private let metadataBox = NSButton(checkboxWithTitle: "Skip .DS_Store and resource forks when compressing",
                                       target: nil, action: nil)
    private let formatPopUp = NSPopUpButton()
    private let levelPopUp = NSPopUpButton()

    private let levels: [(String, Int)] = [
        ("Store", 0), ("Fastest", 1), ("Fast", 3), ("Normal", 5), ("Maximum", 7), ("Ultra", 9),
    ]

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "JustArc Settings"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        build()
        loadValues()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build() {
        guard let content = window?.contentView else { return }

        for destination in ExtractDestination.allCases {
            destinationPopUp.addItem(withTitle: destination.title)
        }

        for format in FormatRegistry.writable where format.engine == .sevenZip {
            formatPopUp.addItem(withTitle: "\(format.displayName)  (.\(format.extensions[0]))")
            formatPopUp.lastItem?.representedObject = format.key
        }
        for (title, _) in levels { levelPopUp.addItem(withTitle: title) }

        let checkboxes = [smartFolderBox, revealBox, trashBox, quitBox, browseBox, metadataBox]
        for box in checkboxes {
            box.target = self
            box.action = #selector(valueChanged)
        }
        destinationPopUp.target = self
        destinationPopUp.action = #selector(valueChanged)
        formatPopUp.target = self
        formatPopUp.action = #selector(valueChanged)
        levelPopUp.target = self
        levelPopUp.action = #selector(valueChanged)

        let grid = NSGridView(views: [
            [heading("When you double-click an archive")],
            [caption("Extract to:"), destinationPopUp],
            [NSView(), smartFolderBox],
            [NSView(), revealBox],
            [NSView(), trashBox],
            [NSView(), quitBox],
            [NSView(), browseBox],
            [heading("New archives")],
            [caption("Format:"), formatPopUp],
            [caption("Compression:"), levelPopUp],
            [NSView(), metadataBox],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)

        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
        ])
    }

    private func heading(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12, weight: .semibold)
        return field
    }

    private func caption(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        return field
    }

    private func loadValues() {
        destinationPopUp.selectItem(at: ExtractDestination.allCases.firstIndex(of: Preferences.extractDestination) ?? 0)
        smartFolderBox.state = Preferences.smartFolder ? .on : .off
        revealBox.state = Preferences.revealInFinder ? .on : .off
        trashBox.state = Preferences.moveArchiveToTrash ? .on : .off
        quitBox.state = Preferences.quitAfterQuickExtract ? .on : .off
        browseBox.state = Preferences.browseInsteadOfExtracting ? .on : .off
        metadataBox.state = Preferences.excludeMacMetadata ? .on : .off

        let formatIndex = formatPopUp.itemArray.firstIndex {
            ($0.representedObject as? String) == Preferences.defaultFormatKey
        } ?? 0
        formatPopUp.selectItem(at: formatIndex)
        levelPopUp.selectItem(at: levels.firstIndex { $0.1 == Preferences.defaultLevel } ?? 3)
    }

    @objc private func valueChanged() {
        let index = max(destinationPopUp.indexOfSelectedItem, 0)
        Preferences.extractDestination = ExtractDestination.allCases[index]
        Preferences.smartFolder = smartFolderBox.state == .on
        Preferences.revealInFinder = revealBox.state == .on
        Preferences.moveArchiveToTrash = trashBox.state == .on
        Preferences.quitAfterQuickExtract = quitBox.state == .on
        Preferences.browseInsteadOfExtracting = browseBox.state == .on
        Preferences.excludeMacMetadata = metadataBox.state == .on
        if let key = formatPopUp.selectedItem?.representedObject as? String {
            Preferences.defaultFormatKey = key
        }
        Preferences.defaultLevel = levels[max(levelPopUp.indexOfSelectedItem, 0)].1
    }
}
