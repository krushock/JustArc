import AppKit
import JustArcCore
import UniformTypeIdentifiers

/// The picture the Finder shows in place of an archive's icon: a page headed with
/// the kind of archive it is, and under that what is in it.
///
/// Small, it shows the icons of the first few things inside, because names that
/// size cannot be read. Large, it shows them as a list with their names.
public struct ArchiveThumbnail: Sendable {
    public struct Item: Sendable, Equatable {
        public let name: String
        public let isDirectory: Bool
    }

    /// The kind of archive, short enough for the band at the top: "ZIP", "TGZ".
    public let badge: String
    /// What is at the top of the archive, folders first.
    public let items: [Item]

    /// The largest compressed tar that is unwrapped to draw its thumbnail. The
    /// Finder asks for one for every archive in a folder as it is scrolled past.
    public static let unwrapLimit: UInt64 = 16 << 20

    /// Below this many points along its longer side a page is too small to say
    /// anything, and the archive's ordinary icon reads better. The extension's
    /// Info.plist says the same, but Quick Look asks for smaller ones regardless.
    public static let minimumDimension: CGFloat = 48

    /// Nil when there is nothing to show, and the archive keeps its ordinary icon:
    /// it is empty, its names are encrypted, or it could not be read.
    public init?(_ preview: ArchivePreview) {
        guard case .listing(let listing) = preview.contents, !listing.entries.isEmpty else { return nil }
        var top = EntryTree(entries: listing.entries).root.children
        // An archive of one folder shows what is in the folder, as the preview does.
        if top.count == 1, let only = top.first, only.isDirectory, !only.children.isEmpty {
            top = only.children
        }
        items = top.map { Item(name: $0.name, isDirectory: $0.isDirectory) }

        let format = FormatRegistry.format(for: preview.url)
        let compressedTars: Set<String> = ["tgz", "tbz2", "txz", "tzst"]
        if let format, compressedTars.contains(format.key) {
            badge = format.key.uppercased()
        } else {
            badge = String(preview.url.pathExtension.uppercased().prefix(5))
        }
    }

    public init(badge: String, items: [Item]) {
        self.badge = badge
        self.items = items
    }

    /// The size of the page: upright, as tall as there is room for.
    public static func pageSize(fitting maximum: CGSize, atLeast minimum: CGSize = .zero) -> CGSize {
        let aspect: CGFloat = 0.77
        var size = CGSize(width: min(maximum.width, maximum.height * aspect), height: maximum.height)
        if size.width < maximum.height * aspect { size.height = size.width / aspect }
        // Quick Look does not take a picture smaller than it asked for.
        if size.width < minimum.width || size.height < minimum.height { return maximum }
        return CGSize(width: size.width.rounded(.down), height: size.height.rounded(.down))
    }

    // MARK: - Drawing

    /// Draws into the current graphics context, whose origin is at the bottom left.
    public func draw(in bounds: CGRect) {
        let width = bounds.width
        let page = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = max(width * 0.07, 2)
        let outline = NSBezierPath(roundedRect: page, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        NSColor.white.setFill()
        page.fill()

        // The band across the top, saying what kind of archive this is.
        let bandHeight = (bounds.height * 0.19).rounded()
        let band = CGRect(x: bounds.minX, y: bounds.maxY - bandHeight, width: width, height: bandHeight)
        NSColor(srgbRed: 0.33, green: 0.40, blue: 0.52, alpha: 1).setFill()
        band.fill()
        let badgeFont = NSFont.systemFont(ofSize: bandHeight * 0.58, weight: .bold)
        let badgeText = NSAttributedString(string: badge, attributes: [
            .font: badgeFont, .foregroundColor: NSColor.white, .kern: bandHeight * 0.04,
        ])
        let badgeSize = badgeText.size()
        if badgeSize.width <= width * 0.9 {
            badgeText.draw(at: CGPoint(x: band.midX - badgeSize.width / 2, y: band.midY - badgeSize.height / 2))
        }

        let margin = max(width * 0.08, 3)
        let content = CGRect(x: bounds.minX + margin, y: bounds.minY + margin,
                             width: width - 2 * margin, height: bounds.height - bandHeight - 2 * margin)
        if width < 110 {
            drawIcons(in: content)
        } else {
            drawList(in: content)
        }
        NSGraphicsContext.restoreGraphicsState()

        NSColor(white: 0, alpha: 0.22).setStroke()
        outline.lineWidth = 1
        outline.stroke()
    }

    /// The first four things inside, as icons, two by two.
    private func drawIcons(in content: CGRect) {
        let columns = 2
        let gap = max(content.width * 0.08, 2)
        let side = min((content.width - gap) / 2, (content.height - gap) / 2)
        let left = content.midX - (side * 2 + gap) / 2
        let top = content.maxY - (content.height - (side * 2 + gap)) / 2
        for (index, item) in items.prefix(4).enumerated() {
            let column = CGFloat(index % columns), row = CGFloat(index / columns)
            let frame = CGRect(x: left + column * (side + gap), y: top - (row + 1) * side - row * gap,
                               width: side, height: side)
            Self.icon(for: item).draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    /// As many of the things inside as there are lines for, each with its name.
    private func drawList(in content: CGRect) {
        let rowHeight = min(max(content.width / 10, 11), 30)
        let rows = max(Int(content.height / rowHeight), 1)
        let font = NSFont.systemFont(ofSize: rowHeight * 0.6)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let ink = NSColor(white: 0.15, alpha: 1)

        // When they do not all fit, the last line says how many more there are.
        let shown = items.count > rows ? rows - 1 : items.count
        for (index, item) in items.prefix(shown).enumerated() {
            let row = CGRect(x: content.minX, y: content.maxY - CGFloat(index + 1) * rowHeight,
                             width: content.width, height: rowHeight)
            let iconSide = rowHeight * 0.82
            Self.icon(for: item).draw(in: CGRect(x: row.minX, y: row.midY - iconSide / 2,
                                                 width: iconSide, height: iconSide),
                                      from: .zero, operation: .sourceOver, fraction: 1)
            let text = NSAttributedString(string: item.name, attributes: [
                .font: font, .foregroundColor: ink, .paragraphStyle: paragraph,
            ])
            let textHeight = text.size().height
            text.draw(in: CGRect(x: row.minX + iconSide + rowHeight * 0.3, y: row.midY - textHeight / 2,
                                 width: row.width - iconSide - rowHeight * 0.3, height: textHeight))
        }
        if items.count > shown {
            let more = NSAttributedString(string: "+" + Formatting.count(items.count - shown), attributes: [
                .font: font, .foregroundColor: NSColor(white: 0.5, alpha: 1),
            ])
            let y = content.maxY - CGFloat(shown + 1) * rowHeight
            more.draw(at: CGPoint(x: content.minX + rowHeight * 0.1, y: y + (rowHeight - more.size().height) / 2))
        }
    }

    private static func icon(for item: Item) -> NSImage {
        if item.isDirectory { return NSWorkspace.shared.icon(for: .folder) }
        let ext = (item.name as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) { return NSWorkspace.shared.icon(for: type) }
        return NSWorkspace.shared.icon(for: .data)
    }

    /// The thumbnail as a bitmap, for looking at outside Quick Look.
    public func bitmap(fitting maximum: CGSize, scale: CGFloat = 2) -> NSBitmapImageRep? {
        let size = Self.pageSize(fitting: maximum)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                            pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // The context counts in pixels; the drawing is in points.
        context.cgContext.scaleBy(x: scale, y: scale)
        draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = size
        return bitmap
    }
}
