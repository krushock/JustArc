import AppKit
import JustArcCore

/// The extra controls attached to the Save panel: format, compression level,
/// password and header encryption, mirroring WinRAR's archive parameters dialog.
final class SaveOptionsAccessory: NSView {
    private let formatPopUp = NSPopUpButton()
    private let levelPopUp = NSPopUpButton()
    private let passwordField = NSSecureTextField()
    private let encryptNamesBox = NSButton(checkboxWithTitle: L("Encrypt file names"), target: nil, action: nil)
    private let excludeMetadataBox = NSButton(checkboxWithTitle: L("Skip .DS_Store and resource forks"),
                                              target: nil, action: nil)
    private let volumeCombo = NSComboBox()

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
        super.init(frame: NSRect(x: 0, y: 0, width: 440, height: 180))
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

        passwordField.placeholderString = L("Optional password")
        excludeMetadataBox.state = Preferences.excludeMacMetadata ? .on : .off

        // Editable so a size the presets do not cover can simply be typed.
        for preset in VolumeSize.presets { volumeCombo.addItem(withObjectValue: preset.title) }
        volumeCombo.selectItem(at: 0)
        volumeCombo.completes = true
        volumeCombo.placeholderString = L("Do not split")
        volumeCombo.toolTip = L("Split the archive into volumes of this size, for example 100m or 1.5g.")

        let grid = NSGridView(views: [
            [label(L("Format:")), formatPopUp],
            [label(L("Compression:")), levelPopUp],
            [label(L("Password:")), passwordField],
            [NSView(), encryptNamesBox],
            [label(L("Split into:")), volumeCombo],
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
        volumeCombo.isEnabled = format.supportsSplitVolumes
        if !format.supportsPassword { passwordField.stringValue = "" }
        if !format.supportsEncryptedHeaders { encryptNamesBox.state = .off }
        if !format.supportsSplitVolumes { volumeCombo.stringValue = "" }
    }

    func options() -> CompressionOptions {
        let level = levels[max(levelPopUp.indexOfSelectedItem, 0)].1
        let password = passwordField.stringValue.isEmpty ? nil : passwordField.stringValue
        let format = selectedFormat
        let volume = format.supportsSplitVolumes
            ? VolumeSize.normalize(volumeCombo.stringValue)
            : nil
        return CompressionOptions(formatKey: format.key,
                                  level: level,
                                  password: password,
                                  encryptFileNames: encryptNamesBox.state == .on,
                                  volumeSize: volume,
                                  excludeMacMetadata: excludeMetadataBox.state == .on)
    }

    /// True when the text in the split field is neither empty nor a size we understand,
    /// so the Save panel can warn instead of silently ignoring it.
    var hasUnparseableVolumeSize: Bool {
        let text = volumeCombo.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, selectedFormat.supportsSplitVolumes else { return false }
        if text.caseInsensitiveCompare(VolumeSize.presets[0].title) == .orderedSame { return false }
        return VolumeSize.normalize(text) == nil
    }
}
