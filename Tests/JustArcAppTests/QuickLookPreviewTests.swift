import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import JustArcCore
@testable import JustArcPreview

/// What the Quick Look extension shows, driven without Quick Look: the extension
/// itself is this view controller plus the one method Quick Look calls.
@MainActor
final class QuickLookPreviewTests: XCTestCase {
    private let engine = SevenZipEngine()
    private var root: URL!

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("justarc-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ text: String, _ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A project folder with a few kinds of file in it.
    private func makeProject() throws -> URL {
        try write("# Project\n", "Project/README.md")
        try write(String(repeating: "let x = 1\n", count: 400), "Project/Sources/main.swift")
        try write("{}\n", "Project/Sources/config.json")
        try write(String(repeating: "pixels ", count: 3_000), "Project/Assets/logo.png")
        try write("notes\n", "Project/Docs/Guides/intro.txt")
        return root.appendingPathComponent("Project")
    }

    private func names(in controller: ArchivePreviewViewController) -> [String] {
        (0..<controller.outlineView.numberOfRows).compactMap {
            (controller.outlineView.item(atRow: $0) as? EntryTree.Node)?.name
        }
    }

    /// Draws the preview the way Quick Look would show it. Kept when
    /// JUSTARC_PREVIEW_SNAPSHOTS names a folder, so that it can be looked at.
    private func draw(_ controller: ArchivePreviewViewController, named name: String) throws -> NSBitmapImageRep {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 760, height: 520))
        controller.view.layoutSubtreeIfNeeded()
        let view = controller.view
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let folder = ProcessInfo.processInfo.environment["JUSTARC_PREVIEW_SNAPSHOTS"] {
            try bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
        return bitmap
    }

    func testAnArchiveIsShownAsItsContents() async throws {
        let archive = root.appendingPathComponent("Project.zip")
        try await engine.create(archive: archive, items: [try makeProject()],
                                options: CompressionOptions(formatKey: "zip"))

        let controller = ArchivePreviewViewController()
        await controller.prepare(for: archive)

        let preview = try XCTUnwrap(controller.preview)
        XCTAssertNil(preview.message)
        XCTAssertTrue(preview.summary.hasPrefix("ZIP"), preview.summary)
        XCTAssertTrue(preview.summary.contains("Files: 5"), preview.summary)
        XCTAssertTrue(preview.summary.contains("Folders: 5"), preview.summary)
        // The one folder at the top is opened onto what it holds, folders first.
        XCTAssertEqual(names(in: controller), ["Project", "Assets", "Docs", "Sources", "README.md"])

        let sources = try XCTUnwrap(controller.outlineView.item(atRow: 3))
        controller.outlineView.expandItem(sources)
        XCTAssertEqual(names(in: controller),
                       ["Project", "Assets", "Docs", "Sources", "config.json", "main.swift", "README.md"])
        _ = try draw(controller, named: "listing")
    }

    func testEncryptedNamesAreSaidToBeEncryptedNotAskedFor() async throws {
        let archive = root.appendingPathComponent("Secret.7z")
        try await engine.create(archive: archive, items: [try makeProject()],
                                options: CompressionOptions(formatKey: "7z", password: "sesame", encryptFileNames: true))

        let controller = ArchivePreviewViewController()
        await controller.prepare(for: archive)

        let preview = try XCTUnwrap(controller.preview)
        guard case .locked = preview.contents else { return XCTFail("\(preview.contents)") }
        XCTAssertTrue(preview.summary.contains("Encrypted"), preview.summary)
        XCTAssertEqual(controller.outlineView.numberOfRows, 0)
        XCTAssertNotNil(preview.message)
        _ = try draw(controller, named: "locked")
    }

    func testEncryptedContentsWithReadableNamesAreStillListed() async throws {
        let archive = root.appendingPathComponent("Half.zip")
        try await engine.create(archive: archive, items: [try makeProject()],
                                options: CompressionOptions(formatKey: "zip", password: "sesame"))
        let preview = await ArchivePreview.load(archive)
        guard case .listing(let listing) = preview.contents else { return XCTFail("\(preview.contents)") }
        XCTAssertEqual(listing.fileCount, 5)
        XCTAssertTrue(preview.summary.contains("Encrypted"), preview.summary)
    }

    func testACompressedTarIsListedUnlessItIsTooLargeToUnwrap() async throws {
        let archive = root.appendingPathComponent("Project.tar.gz")
        try await engine.create(archive: archive, items: [try makeProject()],
                                options: CompressionOptions(formatKey: "tgz"))
        let unwrapped = FileManager.default.temporaryDirectory.appendingPathComponent("JustArc-Unwrapped")
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: unwrapped.path)) ?? [])

        let listed = await ArchivePreview.load(archive)
        guard case .listing(let listing) = listed.contents else { return XCTFail("\(listed.contents)") }
        XCTAssertEqual(listing.fileCount, 5)
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: unwrapped.path)) ?? [])
        XCTAssertEqual(after, before, "the unwrapped tar was left behind after a glance")

        let refused = await ArchivePreview.load(archive, unwrapLimit: 16)
        guard case .tooLargeToList = refused.contents else { return XCTFail("\(refused.contents)") }
        XCTAssertNotNil(refused.message)
    }

    func testAFileThatIsNotAnArchiveSaysSoInsteadOfFailing() async throws {
        let impostor = try write("this is not a zip file at all\n", "broken.zip")
        let controller = ArchivePreviewViewController()
        await controller.prepare(for: impostor)

        let preview = try XCTUnwrap(controller.preview)
        guard case .unreadable = preview.contents else { return XCTFail("\(preview.contents)") }
        XCTAssertEqual(preview.message?.isEmpty, false)
        _ = try draw(controller, named: "unreadable")
    }

    func testAnEmptyArchiveSaysItIsEmpty() async throws {
        let archive = root.appendingPathComponent("empty.zip")
        // The end-of-central-directory record alone is a valid zip with nothing in it.
        try Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)).write(to: archive)
        let preview = await ArchivePreview.load(archive)
        guard case .listing(let listing) = preview.contents else { return XCTFail("\(preview.contents)") }
        XCTAssertTrue(listing.entries.isEmpty)
        XCTAssertNotNil(preview.message)
    }

    // MARK: - The extension's own description

    private func extensionFile(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/JustArcQuickLook").appendingPathComponent(relative)
    }

    private func supportedTypes() throws -> [String] {
        let data = try Data(contentsOf: extensionFile("Resources/Info.plist"))
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let declaration = try XCTUnwrap(plist["NSExtension"] as? [String: Any])
        XCTAssertEqual(declaration["NSExtensionPointIdentifier"] as? String, "com.apple.quicklook.preview")
        // The class is found by the name it is given for Objective-C.
        let principal = try XCTUnwrap(declaration["NSExtensionPrincipalClass"] as? String)
        let source = try String(contentsOf: extensionFile("PreviewViewController.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("@objc(\(principal))"), "Info.plist names a class the extension does not have")
        let attributes = try XCTUnwrap(declaration["NSExtensionAttributes"] as? [String: Any])
        return try XCTUnwrap(attributes["QLSupportedContentTypes"] as? [String])
    }

    func testTheExtensionClaimsArchivesAndNotDiskImages() throws {
        let claimed = try supportedTypes()
        XCTAssertEqual(Set(claimed).count, claimed.count)
        for diskImage in ["public.disk-image", "com.apple.disk-image-udif", "public.archive", "public.data"] {
            XCTAssertFalse(claimed.contains(diskImage), "\(diskImage) would take previews away from things that are not archives")
        }
        // Every kind the app offers itself for, as far as this Mac knows the type.
        for kind in AssociableFileType.all where kind.extensions != ["dmg"] {
            for ext in kind.extensions {
                guard let type = UTType(filenameExtension: ext), !type.identifier.hasPrefix("dyn.") else { continue }
                XCTAssertTrue(claimed.contains(type.identifier), ".\(ext) is \(type.identifier), which the extension does not claim")
            }
        }
    }
}
