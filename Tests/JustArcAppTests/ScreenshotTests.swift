import AppKit
import XCTest
@testable import JustArc
@testable import JustArcCore
@testable import JustArcPreview

/// Draws the pictures in the README from the app's real windows, offscreen.
///
/// Runs only when asked, with the folder to write into:
///
///     JUSTARC_SCREENSHOTS=docs/screenshots swift test --filter ScreenshotTests
///
/// Each picture is drawn in the light appearance and the dark one.
@MainActor
final class ScreenshotTests: XCTestCase {
    private var root: URL!
    private var output: URL!

    override func setUp() async throws {
        guard let folder = ProcessInfo.processInfo.environment["JUSTARC_SCREENSHOTS"] else {
            throw XCTSkip("set JUSTARC_SCREENSHOTS to a folder to draw the README's pictures")
        }
        _ = NSApplication.shared
        Preferences.registerDefaults()
        output = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("justarc-shots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        NSApp.appearance = nil
    }

    // MARK: - Making something worth looking at

    /// A file of `bytes`, of which `random` is a fraction that will not compress, so
    /// that photos stay their size in the archive and documents shrink, as real ones do.
    private func file(_ relative: String, bytes: Int, random: Double = 1) throws {
        let url = root.appendingPathComponent("Holiday 2026").appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data(repeating: 0x20, count: bytes)
        let noisy = Int(Double(bytes) * random)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, noisy) }
        try data.write(to: url)
    }

    private func makeArchive() async throws -> URL {
        let photos = [("IMG_2041.jpg", 412_000), ("IMG_2042.jpg", 388_000), ("IMG_2057.jpg", 455_000),
                      ("IMG_2063.jpg", 401_000), ("IMG_2088.heic", 297_000), ("Panorama.jpg", 820_000)]
        for (name, size) in photos { try file("Photos/\(name)", bytes: size) }
        try file("Videos/Harbour at dusk.mov", bytes: 1_400_000)
        try file("Videos/Boat trip.mp4", bytes: 960_000)
        try file("Tickets/Ferry.pdf", bytes: 84_000, random: 0.6)
        try file("Tickets/Museum.pdf", bytes: 61_000, random: 0.55)
        try file("Itinerary.pdf", bytes: 152_000, random: 0.5)
        try file("Packing list.txt", bytes: 2_300, random: 0.1)
        try file("Budget.numbers", bytes: 210_000, random: 0.35)
        try file("Map.png", bytes: 340_000, random: 0.9)
        let archive = root.appendingPathComponent("Holiday 2026.zip")
        try await SevenZipEngine().create(archive: archive, items: [root.appendingPathComponent("Holiday 2026")],
                                          options: CompressionOptions(formatKey: "zip", level: 5))
        return archive
    }

    // MARK: - Drawing

    /// The whole window, title bar and toolbar included, with the rounded corners and
    /// the shadow a window has on screen.
    private func save(_ window: NSWindow, as name: String) throws {
        window.displayIfNeeded()
        let frame = try XCTUnwrap(window.contentView?.superview)
        frame.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: bitmap)

        let scale = CGFloat(bitmap.pixelsWide) / frame.bounds.width
        let margin = 36 * scale, radius = 16 * scale
        let width = CGFloat(bitmap.pixelsWide) + 2 * margin, height = CGFloat(bitmap.pixelsHigh) + 2 * margin
        let canvas = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height),
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
        let rect = NSRect(x: margin, y: margin, width: CGFloat(bitmap.pixelsWide), height: CGFloat(bitmap.pixelsHigh))
        let outline = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
        shadow.shadowBlurRadius = 22 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -8 * scale)
        shadow.set()
        NSColor.windowBackgroundColor.setFill()
        outline.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        bitmap.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 0.5, alpha: 0.35).setStroke()
        outline.lineWidth = scale
        outline.stroke()
        NSGraphicsContext.restoreGraphicsState()

        let data = try XCTUnwrap(canvas.representation(using: .png, properties: [:]))
        try data.write(to: output.appendingPathComponent(name + ".png"))
    }

    /// Shown as the window people look at, not one behind another app's.
    private func present(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func forEachAppearance(_ body: (String) async throws -> Void) async throws {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            try await body(suffix)
        }
    }

    private func settle() async throws {
        try await Task.sleep(nanoseconds: 400_000_000)
    }

    func testTheArchiveWindow() async throws {
        let archive = try await makeArchive()
        try await forEachAppearance { suffix in
            // Without the sidebar: its translucent material does not draw offscreen.
            let sidebar = Preferences.showSidebar
            Preferences.showSidebar = false
            defer { Preferences.showSidebar = sidebar }
            let controller = ArchiveWindowController(archive: archive)
            let window = try XCTUnwrap(controller.window)
            window.setContentSize(NSSize(width: 1060, height: 600))
            present(window)
            controller.loadArchive()
            let deadline = Date().addingTimeInterval(10)
            while controller.isBusy, Date() < deadline { try await settle() }
            try await settle()
            // The photos open, and one of them chosen.
            let list = try XCTUnwrap(Review2.allSubviews(of: ArchiveOutlineView.self, in: window.contentView!).first)
            for row in 0..<list.numberOfRows {
                if let node = list.item(atRow: row) as? EntryTree.Node, node.name == "Photos" {
                    list.expandItem(node)
                    list.selectRowIndexes(IndexSet(integer: row + 3), byExtendingSelection: false)
                    break
                }
            }
            window.makeFirstResponder(list)
            try await settle()
            try save(window, as: "window-\(suffix)")
            window.close()
        }
    }

    func testTheSettings() async throws {
        try await forEachAppearance { suffix in
            let controller = PreferencesWindowController()
            let window = try XCTUnwrap(controller.window)
            let tabs = try XCTUnwrap(window.contentViewController as? NSTabViewController)
            present(window)
            tabs.selectedTabViewItemIndex = 1
            try await settle()
            try save(window, as: "settings-\(suffix)")
            window.close()
        }
    }

    func testTheQuickLookPreview() async throws {
        let archive = try await makeArchive()
        try await forEachAppearance { suffix in
            let preview = ArchivePreviewViewController()
            await preview.prepare(for: archive)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 400),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Holiday 2026.zip"
            window.contentViewController = preview
            window.setContentSize(NSSize(width: 760, height: 400))
            present(window)
            try await settle()
            try save(window, as: "quicklook-\(suffix)")
            window.close()
        }
    }
}
