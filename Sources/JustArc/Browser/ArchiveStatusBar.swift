import AppKit
import JustArcCore

/// WinRAR's two-pane footer: selection summary on the left, archive totals on the right.
final class ArchiveStatusBar: NSView {
    private let lockIcon = NSImageView()
    private let selectionLabel = NSTextField(labelWithString: "")
    private let totalsLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 24)
    }

    private func build() {
        for label in [selectionLabel, totalsLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
        }
        totalsLabel.alignment = .right

        lockIcon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Encrypted")
        lockIcon.contentTintColor = .secondaryLabelColor
        lockIcon.isHidden = true
        lockIcon.widthAnchor.constraint(equalToConstant: 12).isActive = true

        let stack = NSStackView(views: [lockIcon, selectionLabel, NSView(), totalsLabel])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 10, bottom: 2, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
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
            let bytes = selection.reduce(0) { $0 + $1.size }
            let noun = files.count == 1 ? "file" : "files"
            selectionLabel.stringValue =
                "Selected \(Formatting.count(files.count)) \(noun), \(Formatting.bytes(bytes))"
        }

        let noun = listing.fileCount == 1 ? "file" : "files"
        var totals = "Total \(Formatting.count(listing.fileCount)) \(noun), \(Formatting.bytes(listing.totalSize))"
        if listing.totalSize > 0, listing.totalPacked > 0 {
            totals += " — packed \(Formatting.ratio(size: listing.totalSize, packed: listing.totalPacked))"
        }
        totalsLabel.stringValue = totals
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}
