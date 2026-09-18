// Draws JustArc's app icon and writes AppIcon.icns.
//
//   swift Scripts/make-icon.swift Sources/JustArc/Resources
//
// The tile is a squircle rather than a rounded rectangle, because that is the
// silhouette macOS icons actually use; circular corners read as subtly wrong beside
// the stock icons in the Dock.
import AppKit
import Foundation

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1
                          ? CommandLine.arguments[1] : ".")

/// Superellipse: |x|^n + |y|^n = 1, with n near 5 giving Apple's corner curvature.
func squircle(in rect: CGRect, exponent: CGFloat = 5.0) -> CGPath {
    let path = CGMutablePath()
    let halfWidth = rect.width / 2
    let halfHeight = rect.height / 2
    let centerX = rect.midX
    let centerY = rect.midY
    let steps = 720

    for step in 0...steps {
        let angle = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let cosine = cos(angle)
        let sine = sin(angle)
        let x = centerX + halfWidth * CGFloat(copysign(pow(abs(cosine), 2 / exponent), cosine))
        let y = centerY + halfHeight * CGFloat(copysign(pow(abs(sine), 2 / exponent), sine))
        if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let context = NSGraphicsContext.current?.cgContext else { return image }
    context.setShouldAntialias(true)

    // The tile sits inside the canvas with the standard macOS margin.
    let inset = size * 0.0859
    let tile = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = squircle(in: tile)

    // Body: a deep blue that reads as a system utility rather than a document.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let colors = [
        NSColor(srgbRed: 0.24, green: 0.53, blue: 0.96, alpha: 1).cgColor,
        NSColor(srgbRed: 0.15, green: 0.31, blue: 0.80, alpha: 1).cgColor,
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colors, locations: [0, 1]) {
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: tile.midX, y: tile.maxY),
                                   end: CGPoint(x: tile.midX, y: tile.minY),
                                   options: [])
    }

    // A soft highlight across the top, which is what keeps the tile from looking flat.
    let highlight = CGRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2)
    if let gloss = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [NSColor(white: 1, alpha: 0.26).cgColor,
                                       NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                              locations: [0, 1]) {
        context.drawLinearGradient(gloss,
                                   start: CGPoint(x: highlight.midX, y: highlight.maxY),
                                   end: CGPoint(x: highlight.midX, y: highlight.minY),
                                   options: [])
    }
    context.restoreGState()

    // Hairline edge, so the tile keeps its shape against a light background.
    context.saveGState()
    context.addPath(shape)
    context.setStrokeColor(NSColor(white: 0, alpha: 0.12).cgColor)
    context.setLineWidth(max(size * 0.004, 0.5))
    context.strokePath()
    context.restoreGState()

    // Glyph: the system archive box, which is the shape people already associate
    // with this kind of app.
    let glyphSize = tile.width * 0.5
    let configuration = NSImage.SymbolConfiguration(pointSize: glyphSize, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "archivebox.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) {
        let drawn = symbol.size
        let frame = CGRect(x: tile.midX - drawn.width / 2,
                           y: tile.midY - drawn.height / 2,
                           width: drawn.width, height: drawn.height)

        // Tinting has to happen inside the symbol's own image, otherwise the fill
        // paints the whole rectangle and the glyph lands on a white block.
        let white = NSImage(size: drawn)
        white.lockFocus()
        symbol.draw(in: CGRect(origin: .zero, size: drawn),
                    from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.white.set()
        CGRect(origin: .zero, size: drawn).fill(using: .sourceAtop)
        white.unlockFocus()

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -size * 0.008),
                          blur: size * 0.02,
                          color: NSColor(white: 0, alpha: 0.28).cgColor)
        white.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
        context.restoreGState()
    }
    return image
}

// MARK: - Writing

let iconset = outputDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, pixels) in sizes {
    let image = drawIcon(size: pixels)
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("failed to render \(name)\n".utf8))
        exit(1)
    }
    try png.write(to: iconset.appendingPathComponent("\(name).png"))
}

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path,
                     "-o", outputDirectory.appendingPathComponent("AppIcon.icns").path]
try convert.run()
convert.waitUntilExit()
guard convert.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
try? FileManager.default.removeItem(at: iconset)
print("wrote \(outputDirectory.appendingPathComponent("AppIcon.icns").path)")
