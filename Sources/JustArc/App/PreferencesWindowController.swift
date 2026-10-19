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

        var panes: [(NSViewController, String, String)] = [
            (GeneralSettingsViewController(), L("General"), "gearshape"),
            (ExtractionSettingsViewController(), L("Extracting"), "arrow.down.document"),
            (ArchiveSettingsViewController(), L("Archives"), "shippingbox"),
            (FileTypesSettingsViewController(), L("File Types"), "doc.badge.gearshape"),
        ]
        #if !APP_STORE
        if Distribution.writesRAR {
            panes.append((RarSettingsViewController(), L("RAR"), "arrow.down.circle"))
        }
        #endif
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

    /// The tab controller sizes the window to this, so each pane gets a window that
    /// fits it instead of inheriting the size of whichever pane was showing before.
    override func viewWillAppear() {
        super.viewWillAppear()
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }
}

// MARK: - General

@MainActor
final class GeneralSettingsViewController: SettingsPaneViewController {
    private let updatesBox = NSButton(checkboxWithTitle: L("Check for updates automatically"), target: nil, action: nil)

    override func loadView() {
        super.loadView()
        updatesBox.target = self
        updatesBox.action = #selector(valueChanged)
        let privacy = NSButton(title: L("Privacy…"), target: NSApp.delegate, action: #selector(AppDelegate.showPrivacy(_:)))
        privacy.bezelStyle = .rounded
        var rows: [[NSView]] = []
        // The App Store updates its own apps; that build has no updater to set.
        if Distribution.updatesItself {
            rows.append([caption(L("Updates:")), updatesBox])
            rows.append([NSGridCell.emptyContentView, note(L("Once a day JustArc asks justarc.app whether there is a newer version. The request carries the name and version of JustArc, and, as any request to a website does, your IP address. Nothing about your files is sent, and nothing else is collected."))])
            rows.append([NSGridCell.emptyContentView, privacy])
        } else {
            rows.append([caption(L("Privacy:")), privacy])
        }
        // The sandboxed edition writes only where it has been allowed to.
        if Distribution.isSandboxed {
            folderList.orientation = .vertical
            folderList.alignment = .leading
            folderList.spacing = 4
            let add = NSButton(title: L("Add Folder…"), target: self, action: #selector(addFolder))
            add.bezelStyle = .rounded
            rows.append([caption(L("Folders:")), folderList])
            rows.append([NSGridCell.emptyContentView, add])
            rows.append([NSGridCell.emptyContentView, note(L("JustArc may save in these folders and every folder inside them. It asks before saving anywhere else, and adds what you allow here."))])
        }
        install(NSGridView(views: rows))
    }

    private let folderList = NSStackView()

    private func showFolders() {
        folderList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let folders = FolderAccess.shared.grantedFolders
        if folders.isEmpty {
            let none = NSTextField(labelWithString: L("None yet"))
            none.textColor = .secondaryLabelColor
            folderList.addArrangedSubview(none)
        }
        for folder in folders {
            let name = NSTextField(labelWithString: folder.path)
            name.lineBreakMode = .byTruncatingMiddle
            name.toolTip = folder.path
            name.widthAnchor.constraint(lessThanOrEqualToConstant: 280).isActive = true
            let remove = NSButton(title: L("Remove"), target: self, action: #selector(removeFolder(_:)))
            remove.bezelStyle = .rounded
            remove.controlSize = .small
            remove.identifier = NSUserInterfaceItemIdentifier(folder.path)
            remove.setAccessibilityLabel(L("Remove %@", folder.lastPathComponent))
            let row = NSStackView(views: [name, remove])
            row.spacing = 8
            folderList.addArrangedSubview(row)
        }
    }

    @objc private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L("Allow")
        panel.message = L("Choose a folder JustArc may save in. Every folder inside it is included.")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        FolderAccess.shared.grant(folder)
        showFolders()
    }

    @objc private func removeFolder(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        FolderAccess.shared.revoke(URL(fileURLWithPath: path))
        showFolders()
    }

    override func viewWillAppear() {
        if Distribution.isSandboxed { showFolders() }
        let updates = UpdateController.shared
        updatesBox.isEnabled = updates?.isAvailable == true
        updatesBox.state = updates?.checksAutomatically == true ? .on : .off
        super.viewWillAppear()
    }

    @objc private func valueChanged() {
        UpdateController.shared?.checksAutomatically = updatesBox.state == .on
    }
}

// MARK: - Extracting

@MainActor
final class ExtractionSettingsViewController: SettingsPaneViewController {
    private let destinationPopUp = NSPopUpButton()
    private let smartFolderBox = NSButton(checkboxWithTitle: L("Create a folder when the archive has loose files"), target: nil, action: nil)
    private let revealBox = NSButton(checkboxWithTitle: L("Reveal the result in Finder"), target: nil, action: nil)
    private let trashBox = NSButton(checkboxWithTitle: L("Move the archive to the Trash after extracting"), target: nil, action: nil)
    private let quitBox = NSButton(checkboxWithTitle: L("Quit after extracting"), target: nil, action: nil)
    private let openActionPopUp = NSPopUpButton()
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

        for action in ArchiveOpenAction.allCases {
            openActionPopUp.addItem(withTitle: action.title)
            openActionPopUp.lastItem?.representedObject = action.rawValue
        }

        for control in [openActionPopUp, destinationPopUp, conflictPopUp, folderConflictPopUp] {
            control.target = self
            control.action = #selector(valueChanged(_:))
        }
        for box in [smartFolderBox, revealBox, trashBox, quitBox] {
            box.target = self
            box.action = #selector(valueChanged(_:))
        }

        install(NSGridView(views: [
            [caption(L("Double-clicking an archive:")), openActionPopUp],
            [NSGridCell.emptyContentView, note(L("Opening from the Dock, a Downloads stack included, follows this too. Hold Option while opening to do the other. Right-clicking an archive in the Finder and choosing Open Archive in JustArc always opens it in a window."))],
            [caption(L("Extract to:")), destinationPopUp],
            [NSGridCell.emptyContentView, smartFolderBox],
            [NSGridCell.emptyContentView, revealBox],
            [NSGridCell.emptyContentView, trashBox],
            [NSGridCell.emptyContentView, quitBox],
            [caption(L("If a file exists:")), conflictPopUp],
            [caption(L("If a folder exists:")), folderConflictPopUp],
        ]))
        loadValues()
    }

    /// The window is kept for the life of the app, and some of these settings are
    /// also changed elsewhere: "Always do this" in a conflict prompt, for one. Shown
    /// stale, the next click on any control here would write the old values back.
    override func viewWillAppear() {
        loadValues()
        super.viewWillAppear()
    }

    private func loadValues() {
        destinationPopUp.selectItem(at: ExtractDestination.allCases
            .firstIndex(of: Preferences.extractDestination) ?? 0)
        smartFolderBox.state = Preferences.smartFolder ? .on : .off
        revealBox.state = Preferences.revealInFinder ? .on : .off
        trashBox.state = Preferences.moveArchiveToTrash ? .on : .off
        quitBox.state = Preferences.quitAfterQuickExtract ? .on : .off
        openActionPopUp.selectItem(at: ArchiveOpenAction.allCases
            .firstIndex(of: Preferences.archiveOpenAction) ?? 0)
        conflictPopUp.selectItem(at: conflictPopUp.itemArray.firstIndex {
            ($0.representedObject as? String) == Preferences.overwriteMode.rawValue } ?? 0)
        folderConflictPopUp.selectItem(at: folderConflictPopUp.itemArray.firstIndex {
            ($0.representedObject as? String) == Preferences.folderConflictMode.rawValue } ?? 0)
    }

    /// Writes the one setting whose control was used. Writing them all would put
    /// back, from what this pane happens to be showing, a choice made elsewhere in
    /// the meantime: "Always do this" in a conflict prompt, for one.
    @objc private func valueChanged(_ sender: NSControl) {
        switch sender {
        case destinationPopUp:
            Preferences.extractDestination =
                ExtractDestination.allCases[max(destinationPopUp.indexOfSelectedItem, 0)]
        case smartFolderBox:
            Preferences.smartFolder = smartFolderBox.state == .on
        case revealBox:
            Preferences.revealInFinder = revealBox.state == .on
        case trashBox:
            Preferences.moveArchiveToTrash = trashBox.state == .on
        case quitBox:
            Preferences.quitAfterQuickExtract = quitBox.state == .on
        case openActionPopUp:
            if let raw = openActionPopUp.selectedItem?.representedObject as? String,
               let action = ArchiveOpenAction(rawValue: raw) {
                Preferences.archiveOpenAction = action
            }
        case conflictPopUp:
            if let raw = conflictPopUp.selectedItem?.representedObject as? String,
               let setting = Preferences.OverwriteModeSetting(rawValue: raw) {
                Preferences.overwriteMode = setting
            }
        case folderConflictPopUp:
            if let raw = folderConflictPopUp.selectedItem?.representedObject as? String,
               let setting = Preferences.FolderConflictSetting(rawValue: raw) {
                Preferences.folderConflictMode = setting
            }
        default:
            break
        }
        // And show what is now stored, including anything changed behind this pane.
        loadValues()
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

        loadValues()
    }

    private func loadValues() {
        formatPopUp.selectItem(at: formatPopUp.itemArray.firstIndex {
            ($0.representedObject as? String) == Preferences.defaultFormatKey } ?? 0)
        levelPopUp.selectItem(at: levels.firstIndex { $0.1 == Preferences.defaultLevel } ?? 3)
        metadataBox.state = Preferences.excludeMacMetadata ? .on : .off
    }

    override func viewWillAppear() {
        loadValues()
        super.viewWillAppear()
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

#if !APP_STORE

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
            [NSGridCell.emptyContentView, note(L("Reading RAR always works. Writing needs RARLAB's own tool, which JustArc cannot include. The download comes from rarlab.com and is a trial version licensed by RARLAB, not by JustArc. It is checked against a published checksum before it is installed, in Application Support, not inside the app."))],
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
        // RARLAB's terms are theirs, and are agreed to before anything is fetched,
        // not discovered once it is installed.
        let alert = NSAlert()
        alert.messageText = L("Download RAR from RARLAB?")
        alert.informativeText = L("RAR's tools are made by RARLAB and are trial software under RARLAB's own licence, which JustArc does not grant: RARLAB asks for a licence to be bought to keep using them. The licence comes with the download, and RARLAB's website has the details.")
        alert.addButton(withTitle: L("Download"))
        alert.addButton(withTitle: L("Cancel"))
        alert.addButton(withTitle: L("Visit RARLAB"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            break
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(RarToolInstaller.website)
            return
        default:
            return
        }
        downloadButton.isEnabled = false
        chooseButton.isEnabled = false
        spinner.startAnimation(nil)
        Task {
            await install()
            spinner.stopAnimation(nil)
            downloadButton.isEnabled = true
            chooseButton.isEnabled = true
        }
    }

    /// Downloads and installs, going round again without the check when the user
    /// says to install a release nothing can vouch for. One function from start to
    /// finish, so the spinner and the disabled buttons cover all of it.
    private func install() async {
        var allowUnverified = false
        while true {
            statusLabel.stringValue = L("Downloading from rarlab.com…")
            statusLabel.textColor = .secondaryLabelColor
            do {
                let installation = try await RarToolInstaller.install(allowUnverified: allowUnverified) { fraction in
                    Task { @MainActor in
                        guard let fraction else { return }
                        self.statusLabel.stringValue =
                            L("Downloading from rarlab.com… %@", Formatting.percent(fraction))
                    }
                }
                refresh()
                showLicenceNotice(version: installation.version)
                return
            } catch RarToolInstaller.InstallerError.unverified(let file) where !allowUnverified {
                refresh()
                // A release newer than any record of what it should contain. The
                // choice is the user's, and the safe answer is the default.
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = L("This download could not be checked.")
                alert.informativeText = L("%@ is newer than the releases JustArc can verify, and RARLAB publishes no checksums of its own. Installing it means trusting the connection to rarlab.com alone.", file)
                alert.addButton(withTitle: L("Cancel"))
                alert.addButton(withTitle: L("Install Anyway"))
                let answer: NSApplication.ModalResponse
                if let window = view.window {
                    answer = await alert.beginSheetModal(for: window)
                } else {
                    answer = alert.runModal()
                }
                guard answer == .alertSecondButtonReturn else { return }
                allowUnverified = true
            } catch {
                refresh()
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = L("JustArc could not install the RAR tools.")
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: L("OK"))
                if let window = view.window { await alert.beginSheetModal(for: window) }
                return
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
#endif
