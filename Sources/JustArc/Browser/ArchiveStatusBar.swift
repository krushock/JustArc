import AppKit
import JustArcCore

/// The thin bar along the bottom of the window, the way Finder reports what is in
/// view. It is a vibrant material rather than a painted rectangle, so content
/// scrolling beneath it shows through the way the system intends.
final class ArchiveStatusBar: NSVisualEffectView {
    private let lockIcon = NSImageView()
    private let selectionLabel = NSTextField(labelWithString: "")
    private let totalsLabel = NSTextField(labelWithString: "")
    private let topSeparator = NSBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 28)
    }

    private func build() {
        material = .titlebar
        blendingMode = .withinWindow
        state = .followsWindowActiveState

        for label in [selectionLabel, totalsLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
        }
        totalsLabel.alignment = .right

        lockIcon.image = NSImage(systemSymbolName: "lock.fill",
                                 accessibilityDescription: L("Encrypted"))
        lockIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        lockIcon.contentTintColor = .secondaryLabelColor
        lockIcon.isHidden = true
        lockIcon.widthAnchor.constraint(equalToConstant: 12).isActive = true

        topSeparator.boxType = .separator
        topSeparator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topSeparator)

        let stack = NSStackView(views: [lockIcon, selectionLabel, NSView(), totalsLabel])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            topSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            topSeparator.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func update(selection: [ArchiveEntry], listing: ArchiveListing, isEncrypted: Bool) {
        lockIcon.isHidden = !isEncrypted

        if selection.isEmpty {
            selectionLabel.stringValue = ""
        } else {
            let files = selection.filter { !$0.isDirectory }
            let bytes = selection.reduce(UInt64(0)) { $0.addingSaturating($1.size) }
            selectionLabel.stringValue = files.count == 1
                ? L("Selected 1 file, %@", Formatting.bytes(bytes))
                : L("Selected %@ files, %@", Formatting.count(files.count), Formatting.bytes(bytes))
        }

        var totals = listing.fileCount == 1
            ? L("Total 1 file, %@", Formatting.bytes(listing.totalSize))
            : L("Total %@ files, %@", Formatting.count(listing.fileCount),
                Formatting.bytes(listing.totalSize))
        if listing.totalSize > 0, listing.totalPacked > 0 {
            totals += L(" — packed %@",
                        Formatting.ratio(size: listing.totalSize, packed: listing.totalPacked))
        }
        totalsLabel.stringValue = totals
    }
}
