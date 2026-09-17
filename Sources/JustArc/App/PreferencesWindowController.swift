import AppKit
import JustArcCore
import UniformTypeIdentifiers

/// One settings pane covering Quick Extract behaviour, archive defaults and RAR support.
@MainActor
final class PreferencesWindowController: NSWindowController {
    private let destinationPopUp = NSPopUpButton()
    private let smartFolderBox = NSButton(checkboxWithTitle: L("Create a folder when the archive has loose files"),
                                          target: nil, action: nil)
    private let revealBox = NSButton(checkboxWithTitle: L("Reveal the result in Finder"), target: nil, action: nil)
    private let trashBox = NSButton(checkboxWithTitle: L("Move the archive to the Trash afterwards"),
                                    target: nil, action: nil)
    private let quitBox = NSButton(checkboxWithTitle: L("Quit after extracting"), target: nil, action: nil)
    private let browseBox = NSButton(checkboxWithTitle: L("Open archives in a window instead of extracting"),
                                     target: nil, action: nil)
    private let metadataBox = NSButton(checkboxWithTitle: L("Skip .DS_Store and resource forks when compressing"),
                                       target: nil, action: nil)
    private let formatPopUp = NSPopUpButton()
    private let levelPopUp = NSPopUpButton()
    private let conflictPopUp = NSPopUpButton()
    private let folderConflictPopUp = NSPopUpButton()

    private let rarStatusLabel = NSTextField(labelWithString: "")
    private let rarProgress = NSProgressIndicator()
    private let rarDownloadButton = NSButton(title: L("Download RAR…"), target: nil, action: nil)
    private let rarChooseButton = NSButton(title: L("Choose…"), target: nil, action: nil)
    private let rarRemoveButton = NSButton(title: L("Remove"), target: nil, action: nil)
    private let rarNoteLabel = NSTextField(wrappingLabelWithString: "")

    private let levels: [(String, Int)] = [
        (L("Store"), 0), (L("Fastest"), 1), (L("Fast"), 3),
        (L("Normal"), 5), (L("Maximum"), 7), (L("Ultra"), 9),
    ]

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = L("JustArc Settings")
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
        for setting in Preferences.OverwriteModeSetting.allCases {
            conflictPopUp.addItem(withTitle: setting.title)
            conflictPopUp.lastItem?.representedObject = setting.rawValue
        }
        for setting in Preferences.FolderConflictSetting.allCases {
            folderConflictPopUp.addItem(withTitle: setting.title)
            folderConflictPopUp.lastItem?.representedObject = setting.rawValue
        }

        for box in [smartFolderBox, revealBox, trashBox, quitBox, browseBox, metadataBox] {
            box.target = self
            box.action = #selector(valueChanged)
        }
        for control in [destinationPopUp, formatPopUp, levelPopUp,
                        conflictPopUp, folderConflictPopUp] {
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
        rarNoteLabel.stringValue = L("Reading RAR always works. Writing needs RARLAB's own tool, which JustArc cannot include. The download comes from rarlab.com and is a trial version licensed by RARLAB, not by JustArc. It is installed in Application Support, not inside the app.")
        rarNoteLabel.preferredMaxLayoutWidth = 380

        let statusRow = NSStackView(views: [rarProgress, rarStatusLabel])
        statusRow.orientation = .horizontal
        statusRow.spacing = 6

        let rarButtons = NSStackView(views: [rarDownloadButton, rarChooseButton, rarRemoveButton])
        rarButtons.orientation = .horizontal
        rarButtons.spacing = 8

        let grid = NSGridView(views: [
            [heading(L("When you double-click an archive"))],
            [caption(L("Extract to:")), destinationPopUp],
            [NSView(), smartFolderBox],
            [NSView(), revealBox],
            [NSView(), trashBox],
            [NSView(), quitBox],
            [NSView(), browseBox],
            [caption(L("If a file exists:")), conflictPopUp],
            [caption(L("If a folder exists:")), folderConflictPopUp],
            [heading(L("New archives"))],
            [caption(L("Format:")), formatPopUp],
            [caption(L("Compression:")), levelPopUp],
            [NSView(), metadataBox],
            [heading(L("RAR support"))],
            [caption(L("Status:")), statusRow],
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

        let conflictIndex = conflictPopUp.itemArray.firstIndex {
            ($0.representedObject as? String) == Preferences.overwriteMode.rawValue
        } ?? 0
        conflictPopUp.selectItem(at: conflictIndex)

        let folderIndex = folderConflictPopUp.itemArray.firstIndex {
            ($0.representedObject as? String) == Preferences.folderConflictMode.rawValue
        } ?? 0
        folderConflictPopUp.selectItem(at: folderIndex)
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
        if let raw = conflictPopUp.selectedItem?.representedObject as? String,
           let setting = Preferences.OverwriteModeSetting(rawValue: raw) {
            Preferences.overwriteMode = setting
        }
        if let raw = folderConflictPopUp.selectedItem?.representedObject as? String,
           let setting = Preferences.FolderConflictSetting(rawValue: raw) {
            Preferences.folderConflictMode = setting
        }
    }

    // MARK: - RAR support

    private func refreshRarSection() {
        let installed = RarToolInstaller.isInstalled
        rarRemoveButton.isEnabled = RarToolInstaller.isManagedInstall
            || (UserDefaults.standard.string(forKey: "RARToolPath")?.isEmpty == false)
        rarDownloadButton.title = installed && RarToolInstaller.isManagedInstall
            ? L("Update RAR…") : L("Download RAR…")

        guard installed, let tool = EngineLocator.externalRAR else {
            rarStatusLabel.stringValue = L("Not installed — RAR archives are read-only.")
            rarStatusLabel.textColor = .secondaryLabelColor
            return
        }
        rarStatusLabel.stringValue = L("Checking…")
        rarStatusLabel.textColor = .secondaryLabelColor
        Task {
            let version = await RarToolInstaller.installedVersion()
            let location = RarToolInstaller.isManagedInstall ? L("installed by JustArc") : tool.path
            rarStatusLabel.stringValue = version.map { L("RAR %@ — %@", $0, location) }
                ?? L("Found at %@", tool.path)
            rarStatusLabel.textColor = .labelColor
        }
    }

    @objc private func downloadRar() {
        rarDownloadButton.isEnabled = false
        rarChooseButton.isEnabled = false
        rarProgress.startAnimation(nil)
        rarStatusLabel.stringValue = L("Downloading from rarlab.com…")
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
                            L("Downloading from rarlab.com… %@", Formatting.percent(fraction))
                    }
                }
                rarStatusLabel.stringValue = L("RAR %@ installed.", installation.version)
                rarStatusLabel.textColor = .labelColor
                refreshRarSection()
                showLicenceNotice(version: installation.version)
            } catch {
                rarStatusLabel.stringValue = L("Not installed — RAR archives are read-only.")
                rarStatusLabel.textColor = .secondaryLabelColor
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = L("JustArc could not install the RAR tools.")
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: L("OK"))
                if let window { await alert.beginSheetModal(for: window) }
            }
        }
    }

    private func showLicenceNotice(version: String) {
        let alert = NSAlert()
        alert.messageText = L("RAR %@ is ready.", version)
        alert.informativeText = L("You can now save RAR archives. These tools come from RARLAB and are a trial version under their own licence, which JustArc does not grant.")
        alert.addButton(withTitle: L("OK"))
        if RarToolInstaller.licenseURL != nil { alert.addButton(withTitle: L("Read Licence")) }
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
        panel.message = L("Choose the rar command line tool.")
        panel.prompt = L("Use")
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            let alert = NSAlert()
            alert.messageText = L("%@ is not an executable.", url.lastPathComponent)
            alert.addButton(withTitle: L("OK"))
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
