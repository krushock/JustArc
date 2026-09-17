import AppKit
import JustArcCore

/// The extra controls attached to the Save panel: format, compression level,
/// password and header encryption, mirroring WinRAR's archive parameters dialog.
final class SaveOptionsAccessory: NSView {
    private let formatPopUp = NSPopUpButton()
    private let levelPopUp = NSPopUpButton()
    private let passwordField = NSSecureTextField()
    private let encryptNamesBox = NSButton(checkboxWithTitle: "Encrypt file names", target: nil, action: nil)
    private let excludeMetadataBox = NSButton(checkboxWithTitle: "Skip .DS_Store and resource forks",
                                              target: nil, action: nil)

    private let levels: [(String, Int)] = [
        ("Store (no compression)", 0),
        ("Fastest", 1),
        ("Fast", 3),
        ("Normal", 5),
        ("Maximum", 7),
        ("Ultra", 9),
    ]

    var onFormatChange: ((ArchiveFormat) -> Void)?

    var selectedFormat: ArchiveFormat {
        let index = max(formatPopUp.indexOfSelectedItem, 0)
        let available = Self.availableFormats
        return available.indices.contains(index) ? available[index] : available[0]
    }

    /// RAR only appears when the user has RARLAB's tool installed.
    static var availableFormats: [ArchiveFormat] {
        FormatRegistry.writable.filter { format in
            switch format.engine {
            case .externalRAR: return EngineLocator.externalRAR != nil
            case .diskImage, .sevenZip: return true
            }
        }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 150))
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build() {
        for format in Self.availableFormats {
            formatPopUp.addItem(withTitle: "\(format.displayName)  (.\(format.extensions[0]))")
        }
        let defaultIndex = Self.availableFormats.firstIndex { $0.key == Preferences.defaultFormatKey } ?? 0
        formatPopUp.selectItem(at: defaultIndex)
        formatPopUp.target = self
        formatPopUp.action = #selector(formatChanged)

        for (title, _) in levels { levelPopUp.addItem(withTitle: title) }
        let defaultLevel = levels.firstIndex { $0.1 == Preferences.defaultLevel } ?? 3
        levelPopUp.selectItem(at: defaultLevel)

        passwordField.placeholderString = "Optional password"
        excludeMetadataBox.state = Preferences.excludeMacMetadata ? .on : .off

        let grid = NSGridView(views: [
            [label("Format:"), formatPopUp],
            [label("Compression:"), levelPopUp],
            [label("Password:"), passwordField],
            [NSView(), encryptNamesBox],
            [NSView(), excludeMetadataBox],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)

        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        updateEnabledState()
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        return field
    }

    @objc private func formatChanged() {
        updateEnabledState()
        onFormatChange?(selectedFormat)
    }

    private func updateEnabledState() {
        let format = selectedFormat
        levelPopUp.isEnabled = format.supportsCompressionLevel
        passwordField.isEnabled = format.supportsPassword
        encryptNamesBox.isEnabled = format.supportsEncryptedHeaders
        if !format.supportsPassword { passwordField.stringValue = "" }
        if !format.supportsEncryptedHeaders { encryptNamesBox.state = .off }
    }

    func options() -> CompressionOptions {
        let level = levels[max(levelPopUp.indexOfSelectedItem, 0)].1
        let password = passwordField.stringValue.isEmpty ? nil : passwordField.stringValue
        return CompressionOptions(formatKey: selectedFormat.key,
                                  level: level,
                                  password: password,
                                  encryptFileNames: encryptNamesBox.state == .on,
                                  excludeMacMetadata: excludeMetadataBox.state == .on)
    }
}
