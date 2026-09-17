import AppKit
import JustArcCore
import UniformTypeIdentifiers

/// One settings pane covering Quick Extract behaviour, archive defaults and RAR support.
@MainActor
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

    private let rarStatusLabel = NSTextField(labelWithString: "")
    private let rarProgress = NSProgressIndicator()
    private let rarDownloadButton = NSButton(title: "Download RAR…", target: nil, action: nil)
    private let rarChooseButton = NSButton(title: "Choose…", target: nil, action: nil)
    private let rarRemoveButton = NSButton(title: "Remove", target: nil, action: nil)
    private let rarNoteLabel = NSTextField(wrappingLabelWithString: "")

    private let levels: [(String, Int)] = [
        ("Store", 0), ("Fastest", 1), ("Fast", 3), ("Normal", 5), ("Maximum", 7), ("Ultra", 9),
    ]

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "JustArc Settings"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        build()
        loadValues()
        refreshRarSection()
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

        for box in [smartFolderBox, revealBox, trashBox, quitBox, browseBox, metadataBox] {
            box.target = self
            box.action = #selector(valueChanged)
        }
        for control in [destinationPopUp, formatPopUp, levelPopUp] {
            control.target = self
            control.action = #selector(valueChanged)
        }

        rarProgress.style = .spinning
        rarProgress.controlSize = .small
        rarProgress.isDisplayedWhenStopped = false
        rarProgress.widthAnchor.constraint(equalToConstant: 16).isActive = true

        rarDownloadButton.target = self
        rarDownloadButton.action = #selector(downloadRar)
        rarChooseButton.target = self
        rarChooseButton.action = #selector(chooseRar)
        rarRemoveButton.target = self
        rarRemoveButton.action = #selector(removeRar)
        for button in [rarDownloadButton, rarChooseButton, rarRemoveButton] {
            button.bezelStyle = .rounded
            button.controlSize = .regular
        }

        rarStatusLabel.font = .systemFont(ofSize: 12)
        rarNoteLabel.font = .systemFont(ofSize: 11)
        rarNoteLabel.textColor = .secondaryLabelColor
        rarNoteLabel.stringValue = """
        Reading RAR always works. Writing needs RARLAB's own tool, which JustArc cannot \
        include. The download comes from rarlab.com and is a trial version licensed by \
        RARLAB, not by JustArc. It is installed in Application Support, not inside the app.
        """
        rarNoteLabel.preferredMaxLayoutWidth = 380

        let statusRow = NSStackView(views: [rarProgress, rarStatusLabel])
        statusRow.orientation = .horizontal
        statusRow.spacing = 6

        let rarButtons = NSStackView(views: [rarDownloadButton, rarChooseButton, rarRemoveButton])
        rarButtons.orientation = .horizontal
        rarButtons.spacing = 8

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
            [heading("RAR support")],
            [caption("Status:"), statusRow],
            [NSView(), rarButtons],
            [NSView(), rarNoteLabel],
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

    // MARK: - RAR support

    private func refreshRarSection() {
        let installed = RarToolInstaller.isInstalled
        rarRemoveButton.isEnabled = RarToolInstaller.isManagedInstall
            || (UserDefaults.standard.string(forKey: "RARToolPath")?.isEmpty == false)
        rarDownloadButton.title = installed && RarToolInstaller.isManagedInstall
            ? "Update RAR…" : "Download RAR…"

        guard installed, let tool = EngineLocator.externalRAR else {
            rarStatusLabel.stringValue = "Not installed — RAR archives are read-only."
            rarStatusLabel.textColor = .secondaryLabelColor
            return
        }
        rarStatusLabel.stringValue = "Checking…"
        rarStatusLabel.textColor = .secondaryLabelColor
        Task {
            let version = await RarToolInstaller.installedVersion()
            let where_ = RarToolInstaller.isManagedInstall ? "installed by JustArc" : tool.path
            rarStatusLabel.stringValue = version.map { "RAR \($0) — \(where_)" } ?? "Found at \(tool.path)"
            rarStatusLabel.textColor = .labelColor
        }
    }

    @objc private func downloadRar() {
        rarDownloadButton.isEnabled = false
        rarChooseButton.isEnabled = false
        rarProgress.startAnimation(nil)
        rarStatusLabel.stringValue = "Downloading from rarlab.com…"
        rarStatusLabel.textColor = .secondaryLabelColor

        Task {
            defer {
                rarProgress.stopAnimation(nil)
                rarDownloadButton.isEnabled = true
                rarChooseButton.isEnabled = true
            }
            do {
                let installation = try await RarToolInstaller.install { fraction in
                    Task { @MainActor in
                        guard let fraction else { return }
                        self.rarStatusLabel.stringValue =
                            "Downloading from rarlab.com… \(Formatting.percent(fraction))"
                    }
                }
                rarStatusLabel.stringValue = "RAR \(installation.version) installed."
                rarStatusLabel.textColor = .labelColor
                refreshRarSection()
                showLicenceNotice(version: installation.version)
            } catch {
                rarStatusLabel.stringValue = "Not installed — RAR archives are read-only."
                rarStatusLabel.textColor = .secondaryLabelColor
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "JustArc could not install the RAR tools."
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                if let window { await alert.beginSheetModal(for: window) }
            }
        }
    }

    private func showLicenceNotice(version: String) {
        let alert = NSAlert()
        alert.messageText = "RAR \(version) is ready."
        alert.informativeText = """
        You can now save RAR archives. These tools come from RARLAB and are a trial \
        version under their own licence, which JustArc does not grant.
        """
        alert.addButton(withTitle: "OK")
        if RarToolInstaller.licenseURL != nil { alert.addButton(withTitle: "Read Licence") }
        let response = alert.runModal()
        if response == .alertSecondButtonReturn, let licence = RarToolInstaller.licenseURL {
            NSWorkspace.shared.open(licence)
        }
    }

    @objc private func chooseRar() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the rar command line tool."
        panel.prompt = "Use"
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            let alert = NSAlert()
            alert.messageText = "\(url.lastPathComponent) is not an executable."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        UserDefaults.standard.set(url.path, forKey: "RARToolPath")
        refreshRarSection()
    }

    @objc private func removeRar() {
        UserDefaults.standard.removeObject(forKey: "RARToolPath")
        try? RarToolInstaller.removeManagedInstall()
        refreshRarSection()
    }
}
