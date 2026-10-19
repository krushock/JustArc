// Draws the icon archives have in the Finder when JustArc opens them, and writes
// ArchiveDocument.icns: a page, as macOS draws documents, with JustArc's icon on it.
//
//   swift Scripts/make-document-icon.swift Sources/JustArc/Resources
//
// It is drawn from AppIcon.icns in the same folder, so run make-icon.swift first
// when the app icon changes.
import AppKit
import Foundation

let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
guard let appIcon = NSImage(contentsOf: folder.appendingPathComponent("AppIcon.icns")) else {
    FileHandle.standardError.write(Data("AppIcon.icns not found in \(folder.path)\n".utf8))
    exit(1)
}

func drawDocument(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // The page, in the proportions of macOS's own document icons, with its top
    // right corner folded over.
    let page = CGRect(x: size * 0.15, y: size * 0.05, width: size * 0.70, height: size * 0.90)
    let fold = page.width * 0.28
    let radius = size * 0.025
    let outline = NSBezierPath()
    outline.move(to: CGPoint(x: page.minX + radius, y: page.minY))
    outline.line(to: CGPoint(x: page.maxX - radius, y: page.minY))
    outline.appendArc(withCenter: CGPoint(x: page.maxX - radius, y: page.minY + radius),
                      radius: radius, startAngle: 270, endAngle: 0)
    outline.line(to: CGPoint(x: page.maxX, y: page.maxY - fold))
    outline.line(to: CGPoint(x: page.maxX - fold, y: page.maxY))
    outline.line(to: CGPoint(x: page.minX + radius, y: page.maxY))
    outline.appendArc(withCenter: CGPoint(x: page.minX + radius, y: page.maxY - radius),
                      radius: radius, startAngle: 90, endAngle: 180)
    outline.line(to: CGPoint(x: page.minX, y: page.minY + radius))
    outline.appendArc(withCenter: CGPoint(x: page.minX + radius, y: page.minY + radius),
                      radius: radius, startAngle: 180, endAngle: 270)
    outline.close()

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
    shadow.shadowBlurRadius = size * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.008)
    shadow.set()
    NSColor.white.setFill()
    outline.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSColor(white: 0, alpha: 0.12).setStroke()
    outline.lineWidth = max(size / 512, 0.5)
    outline.stroke()

    // The folded corner.
    let corner = NSBezierPath()
    corner.move(to: CGPoint(x: page.maxX - fold, y: page.maxY))
    corner.line(to: CGPoint(x: page.maxX - fold, y: page.maxY - fold + radius))
    corner.appendArc(withCenter: CGPoint(x: page.maxX - fold + radius, y: page.maxY - fold + radius),
                     radius: radius, startAngle: 180, endAngle: 270)
    corner.line(to: CGPoint(x: page.maxX, y: page.maxY - fold))
    corner.close()
    NSColor(white: 0.88, alpha: 1).setFill()
    corner.fill()
    NSColor(white: 0, alpha: 0.12).setStroke()
    corner.lineWidth = outline.lineWidth
    corner.stroke()

    // JustArc's icon, in the middle of the page.
    let side = page.width * 0.66
    let iconRect = CGRect(x: page.midX - side / 2, y: page.minY + page.height * 0.45 - side / 2,
                          width: side, height: side)
    appIcon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
    return rep
}

let iconset = folder.appendingPathComponent("ArchiveDocument.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let data = drawDocument(size: CGFloat(points * scale)).representation(using: .png, properties: [:])!
        try data.write(to: iconset.appendingPathComponent(name))
    }
}
let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path, "-o", folder.appendingPathComponent("ArchiveDocument.icns").path]
try convert.run()
convert.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard convert.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("wrote \(folder.appendingPathComponent("ArchiveDocument.icns").path)")
