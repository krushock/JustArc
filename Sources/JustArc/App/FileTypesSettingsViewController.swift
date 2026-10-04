import AppKit
import UniformTypeIdentifiers
import JustArcCore

/// Settings ▸ File Types: which app the Finder opens each kind of archive with.
@MainActor
final class FileTypesSettingsViewController: SettingsPaneViewController,
                                            NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let scrollView = NSScrollView()
    private let useForAllButton = NSButton(title: L("Use JustArc for All Archives"), target: nil, action: nil)
    private var rows: [FileAssociations.Row] = []
    private var activationObserver: NSObjectProtocol?

    private enum Column {
        static let kind = NSUserInterfaceItemIdentifier("kind")
        static let app = NSUserInterfaceItemIdentifier("app")
    }

    override func loadView() {
        super.loadView()
        rows = FileAssociations.rows()

        let intro = note(L("Choose the app that opens each kind of archive when you double-click it in the Finder."))
        intro.preferredMaxLayoutWidth = 500

        let kindColumn = NSTableColumn(identifier: Column.kind)
        kindColumn.title = L("Kind")
        kindColumn.width = 250
        let appColumn = NSTableColumn(identifier: Column.app)
        appColumn.title = L("Opens With")
        appColumn.width = 220
        table.addTableColumn(kindColumn)
        table.addTableColumn(appColumn)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 30
        table.style = .inset
        table.selectionHighlightStyle = .none
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        useForAllButton.bezelStyle = .rounded
        useForAllButton.target = self
        useForAllButton.action = #selector(useJustArcForAll)
        useForAllButton.isEnabled = FileAssociations.justArc != nil

        let footnote = note(FileAssociations.justArc == nil
            ? L("JustArc is running outside an app bundle, so it cannot be chosen here.")
            : L("macOS asks you to confirm each change. Disk images and ISO files keep the app they have now."))
        footnote.preferredMaxLayoutWidth = 280

        let footer = NSStackView(views: [useForAllButton, footnote])
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.alignment = .centerY

        let stack = NSStackView(views: [intro, scrollView, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -22),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 500),
            scrollView.heightAnchor.constraint(equalToConstant: 330),
        ])

        // The default can be changed in the Finder while this window is open.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.table.reloadData() }
            }
    }

    deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        table.reloadData()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = rows[row]
        if tableColumn?.identifier == Column.kind {
            let cell = tableView.makeView(withIdentifier: Column.kind, owner: nil) as? KindCell ?? KindCell()
            cell.identifier = Column.kind
            cell.configure(title: entry.kind.title, detail: entry.kind.extensionList,
                           icon: NSWorkspace.shared.icon(for: entry.type))
            return cell
        }

        // Rebuilt rather than reused: the list of apps differs from one type to the next.
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.controlSize = .regular
        popUp.tag = row
        popUp.target = self
        popUp.action = #selector(appChosen(_:))
        fill(popUp, for: entry.type)
        return popUp
    }

    private func fill(_ popUp: NSPopUpButton, for type: UTType) {
        popUp.removeAllItems()
        let current = FileAssociations.defaultApp(for: type)
        let apps = FileAssociations.candidates(for: type)

        if current == nil {
            popUp.addItem(withTitle: L("No app"))
            popUp.lastItem?.isEnabled = false
        }
        for app in apps {
            popUp.addItem(withTitle: FileAssociations.displayName(of: app))
            popUp.lastItem?.image = FileAssociations.icon(of: app)
            popUp.lastItem?.representedObject = app
            // Two copies of an app read the same; the path tells them apart.
            popUp.lastItem?.toolTip = app.path
        }
        popUp.menu?.addItem(.separator())
        popUp.addItem(withTitle: L("Other…"))

        if let current, let index = apps.firstIndex(of: current) {
            popUp.selectItem(at: index)
        } else {
            popUp.selectItem(at: 0)
        }
    }

    // MARK: - Actions

    @objc private func appChosen(_ sender: NSPopUpButton) {
        let row = sender.tag
        guard rows.indices.contains(row) else { return }
        let type = rows[row].type

        var chosen = sender.selectedItem?.representedObject as? URL
        if chosen == nil {
            chosen = chooseOtherApp()
            guard chosen != nil else {
                fill(sender, for: type)
                return
            }
        }
        guard let app = chosen, app != FileAssociations.defaultApp(for: type) else { return }
        apply([(type, app)])
    }

    private func chooseOtherApp() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L("Choose")
        panel.message = L("Choose the app to open these archives with.")
        return panel.runModal() == .OK ? panel.url?.standardizedFileURL : nil
    }

    @objc private func useJustArcForAll() {
        guard let justArc = FileAssociations.justArc else { return }
        apply(rows.filter(\.kind.isIncludedInAll).map { ($0.type, justArc) })
    }

    private func apply(_ changes: [(UTType, URL)]) {
        useForAllButton.isEnabled = false
        Task {
            var failures: [String] = []
            for (type, app) in changes where FileAssociations.defaultApp(for: type) != app {
                do {
                    try await FileAssociations.setDefault(app, for: type)
                    Diagnostics.log("file types: \(type.identifier) now opens with \(app.lastPathComponent)")
                } catch where FileAssociations.isUserCancellation(error) {
                    // macOS asked and the answer was no. Asking about the rest of
                    // the list would only repeat the question.
                    break
                } catch {
                    failures.append("\(type.localizedDescription ?? type.identifier): \(error.localizedDescription)")
                }
            }
            useForAllButton.isEnabled = FileAssociations.justArc != nil
            table.reloadData()
            guard !failures.isEmpty else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L("macOS did not change the default app.")
            alert.informativeText = failures.joined(separator: "\n")
            alert.addButton(withTitle: L("OK"))
            if let window = view.window { await alert.beginSheetModal(for: window) }
        }
    }
}

/// Icon, name and the extensions the row covers.
private final class KindCell: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [icon, title, detail])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func configure(title: String, detail: String, icon: NSImage) {
        self.title.stringValue = title
        self.detail.stringValue = detail
        self.icon.image = icon
    }
}
