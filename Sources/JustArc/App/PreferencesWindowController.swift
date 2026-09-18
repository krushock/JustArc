import AppKit
import JustArcCore
import UniformTypeIdentifiers

/// The Settings window.
///
/// An `NSTabViewController` in toolbar style with `NSWindow.ToolbarStyle.preference`
/// is the stock shape for a utility's settings: centred tab icons, and the window
/// resizing itself to whichever pane is showing.
@MainActor
final class PreferencesWindowController: NSWindowController {
    init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar

        let panes: [(NSViewController, String, String)] = [
            (ExtractionSettingsViewController(), L("Extracting"), "arrow.down.document"),
            (ArchiveSettingsViewController(), L("Archives"), "shippingbox"),
            (RarSettingsViewController(), L("RAR"), "doc.badge.gearshape"),
        ]
        for (controller, title, symbol) in panes {
            controller.title = title
            let item = NSTabViewItem(viewController: controller)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.title = L("JustArc Settings")
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }
}

/// Shared furniture so every pane lines up the same way.
@MainActor
class SettingsPaneViewController: NSViewController {
    func caption(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        field.textColor = .labelColor
        return field
    }

    func note(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = 360
        return field
    }

    /// Lays a grid out with the standard settings margins.
    func install(_ grid: NSGridView) {
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -22),
        ])
    }

    override func loadView() {
        view = NSView()
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: 460).isActive = true
    }
}

// MARK: - Extracting

@MainActor
final class ExtractionSettingsViewController: SettingsPaneViewController {
    private let destinationPopUp = NSPopUpButton()
    private let smartFolderBox = NSButton(checkboxWithTitle: L("Create a folder when the archive has loose files"), target: nil, action: nil)
    private let revealBox = NSButton(checkboxWithTitle: L("Reveal the result in Finder"), target: nil, action: nil)
    private let trashBox = NSButton(checkboxWithTitle: L("Move the archive to the Trash afterwards"), target: nil, action: nil)
    private let quitBox = NSButton(checkboxWithTitle: L("Quit after extracting"), target: nil, action: nil)
    private let browseBox = NSButton(checkboxWithTitle: L("Open archives in a window instead of extracting"), target: nil, action: nil)
    private let conflictPopUp = NSPopUpButton()
    private let folderConflictPopUp = NSPopUpButton()

    override func loadView() {
        super.loadView()

        for destination in ExtractDestination.allCases {
            destinationPopUp.addItem(withTitle: destination.title)
        }
        for setting in Preferences.OverwriteModeSetting.allCases {
            conflictPopUp.addItem(withTitle: setting.title)
            conflictPopUp.lastItem?.representedObject = setting.rawValue
        }
        for setting in Preferences.FolderConflictSetting.allCases {
            folderConflictPopUp.addItem(withTitle: setting.title)
            folderConflictPopUp.lastItem?.representedObject = setting.rawValue
        }

        for control in [destinationPopUp, conflictPopUp, folderConflictPopUp] {
            control.target = self
            control.action = #selector(valueChanged)
        }
        for box in [smartFolderBox, revealBox, trashBox, quitBox, browseBox] {
            box.target = self
            box.action = #selector(valueChanged)
        }

        install(NSGridView(views: [
            [caption(L("Extract to:")), destinationPopUp],
            [NSGridCell.emptyContentView, smartFolderBox],
            [NSGridCell.emptyContentView, revealBox],
            [NSGridCell.emptyContentView, trashBox],
            [NSGridCell.emptyContentView, quitBox],
            [NSGridCell.emptyContentView, browseBox],
            [caption(L("If a file exists:")), conflictPopUp],
            [caption(L("If a folder exists:")), folderConflictPopUp],
        ]))
        loadValues()
    }

    private func loadValues() {
        destinationPopUp.selectItem(at: ExtractDestination.allCases
            .firstIndex(of: Preferences.extractDestination) ?? 0)
        smartFolderBox.state = Preferences.smartFolder ? .on : .off
        revealBox.state = Preferences.revealInFinder ? .on : .off
        trashBox.state = Preferences.moveArchiveToTrash ? .on : .off
        quitBox.state = Preferences.quitAfterQuickExtract ? .on : .off
        browseBox.state = Preferences.browseInsteadOfExtracting ? .on : .off
        conflictPopUp.selectItem(at: conflictPopUp.itemArray.firstIndex {
            ($0.representedObject as? String) == Preferences.overwriteMode.rawValue } ?? 0)
        folderConflictPopUp.selectItem(at: folderConflictPopUp.itemArray.firstIndex {
            ($0.representedObject as? String) == Preferences.folderConflictMode.rawValue } ?? 0)
    }

    @objc private func valueChanged() {
        Preferences.extractDestination =
            ExtractDestination.allCases[max(destinationPopUp.indexOfSelectedItem, 0)]
        Preferences.smartFolder = smartFolderBox.state == .on
        Preferences.revealInFinder = revealBox.state == .on
        Preferences.moveArchiveToTrash = trashBox.state == .on
        Preferences.quitAfterQuickExtract = quitBox.state == .on
        Preferences.browseInsteadOfExtracting = browseBox.state == .on
        if let raw = conflictPopUp.selectedItem?.representedObject as? String,
           let setting = Preferences.OverwriteModeSetting(rawValue: raw) {
            Preferences.overwriteMode = setting
        }
        if let raw = folderConflictPopUp.selectedItem?.representedObject as? String,
           let setting = Preferences.FolderConflictSetting(rawValue: raw) {
            Preferences.folderConflictMode = setting
        }
    }
}

// MARK: - Archives

@MainActor
final class ArchiveSettingsViewController: SettingsPaneViewController {
    private let formatPopUp = NSPopUpButton()
    private let levelPopUp = NSPopUpButton()
    private let metadataBox = NSButton(checkboxWithTitle: L("Skip .DS_Store and resource forks when compressing"), target: nil, action: nil)

    private let levels: [(String, Int)] = [
        (L("Store"), 0), (L("Fastest"), 1), (L("Fast"), 3),
        (L("Normal"), 5), (L("Maximum"), 7), (L("Ultra"), 9),
    ]

    override func loadView() {
        super.loadView()

        for format in FormatRegistry.writable where format.engine == .sevenZip {
            formatPopUp.addItem(withTitle: "\(format.displayName)  (.\(format.extensions[0]))")
            formatPopUp.lastItem?.representedObject = format.key
        }
        for (title, _) in levels { levelPopUp.addItem(withTitle: title) }

        for control in [formatPopUp, levelPopUp] {
            control.target = self
            control.action = #selector(valueChanged)
        }
        metadataBox.target = self
        metadataBox.action = #selector(valueChanged)

        install(NSGridView(views: [
            [caption(L("Format:")), formatPopUp],
            [caption(L("Compression:")), levelPopUp],
            [NSGridCell.emptyContentView, metadataBox],
        ]))

        formatPopUp.selectItem(at: formatPopUp.itemArray.firstIndex {
            ($0.representedObject as? String) == Preferences.defaultFormatKey } ?? 0)
        levelPopUp.selectItem(at: levels.firstIndex { $0.1 == Preferences.defaultLevel } ?? 3)
        metadataBox.state = Preferences.excludeMacMetadata ? .on : .off
    }

    @objc private func valueChanged() {
        if let key = formatPopUp.selectedItem?.representedObject as? String {
            Preferences.defaultFormatKey = key
        }
        Preferences.defaultLevel = levels[max(levelPopUp.indexOfSelectedItem, 0)].1
        Preferences.excludeMacMetadata = metadataBox.state == .on
    }
}

// MARK: - RAR

@MainActor
final class RarSettingsViewController: SettingsPaneViewController {
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let downloadButton = NSButton(title: L("Download RAR…"), target: nil, action: nil)
    private let chooseButton = NSButton(title: L("Choose…"), target: nil, action: nil)
    private let removeButton = NSButton(title: L("Remove"), target: nil, action: nil)

    override func loadView() {
        super.loadView()

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.widthAnchor.constraint(equalToConstant: 16).isActive = true

        downloadButton.target = self
        downloadButton.action = #selector(download)
        chooseButton.target = self
        chooseButton.action = #selector(choose)
        removeButton.target = self
        removeButton.action = #selector(remove)
        for button in [downloadButton, chooseButton, removeButton] {
            button.bezelStyle = .rounded
        }

        statusLabel.font = .systemFont(ofSize: NSFont.systemFontSize)

        let statusRow = NSStackView(views: [spinner, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.spacing = 6

        let buttons = NSStackView(views: [downloadButton, chooseButton, removeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        install(NSGridView(views: [
            [caption(L("Status:")), statusRow],
            [NSGridCell.emptyContentView, buttons],
            [NSGridCell.emptyContentView, note(L("Reading RAR always works. Writing needs RARLAB's own tool, which JustArc cannot include. The download comes from rarlab.com and is a trial version licensed by RARLAB, not by JustArc. It is installed in Application Support, not inside the app."))],
        ]))
        refresh()
    }

    private func refresh() {
        let installed = RarToolInstaller.isInstalled
        removeButton.isEnabled = RarToolInstaller.isManagedInstall
            || (UserDefaults.standard.string(forKey: "RARToolPath")?.isEmpty == false)
        downloadButton.title = installed && RarToolInstaller.isManagedInstall
            ? L("Update RAR…") : L("Download RAR…")

        guard installed, let tool = EngineLocator.externalRAR else {
            statusLabel.stringValue = L("Not installed — RAR archives are read-only.")
            statusLabel.textColor = .secondaryLabelColor
            return
        }
        statusLabel.stringValue = L("Checking…")
        statusLabel.textColor = .secondaryLabelColor
        Task {
            let version = await RarToolInstaller.installedVersion()
            let location = RarToolInstaller.isManagedInstall ? L("installed by JustArc") : tool.path
            statusLabel.stringValue = version.map { L("RAR %@ — %@", $0, location) }
                ?? L("Found at %@", tool.path)
            statusLabel.textColor = .labelColor
        }
    }

    @objc private func download() {
        downloadButton.isEnabled = false
        chooseButton.isEnabled = false
        spinner.startAnimation(nil)
        statusLabel.stringValue = L("Downloading from rarlab.com…")
        statusLabel.textColor = .secondaryLabelColor

        Task {
            defer {
                spinner.stopAnimation(nil)
                downloadButton.isEnabled = true
                chooseButton.isEnabled = true
            }
            do {
                let installation = try await RarToolInstaller.install { fraction in
                    Task { @MainActor in
                        guard let fraction else { return }
                        self.statusLabel.stringValue =
                            L("Downloading from rarlab.com… %@", Formatting.percent(fraction))
                    }
                }
                refresh()
                showLicenceNotice(version: installation.version)
            } catch {
                refresh()
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = L("JustArc could not install the RAR tools.")
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: L("OK"))
                if let window = view.window { await alert.beginSheetModal(for: window) }
            }
        }
    }

    private func showLicenceNotice(version: String) {
        let alert = NSAlert()
        alert.messageText = L("RAR %@ is ready.", version)
        alert.informativeText = L("You can now save RAR archives. These tools come from RARLAB and are a trial version under their own licence, which JustArc does not grant.")
        alert.addButton(withTitle: L("OK"))
        if RarToolInstaller.licenseURL != nil { alert.addButton(withTitle: L("Read Licence")) }
        if alert.runModal() == .alertSecondButtonReturn, let licence = RarToolInstaller.licenseURL {
            NSWorkspace.shared.open(licence)
        }
    }

    @objc private func choose() {
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
        refresh()
    }

    @objc private func remove() {
        UserDefaults.standard.removeObject(forKey: "RARToolPath")
        try? RarToolInstaller.removeManagedInstall()
        refresh()
    }
}
