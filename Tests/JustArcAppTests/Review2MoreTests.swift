import AppKit
import QuickLookUI
import UniformTypeIdentifiers
import XCTest
@testable import JustArc
@testable import JustArcCore

@MainActor
final class Review2MoreTests: XCTestCase {
    private var root: URL!
    private var windows: [NSWindow] = []
    private var driver: ModalDriver!

    override func setUp() async throws {
        _ = NSApplication.shared
        ModalWatchdog.arm()
        root = try Review2.makeRoot()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("payload/pkg"),
                                                withIntermediateDirectories: true)
        try "data\n".write(to: root.appendingPathComponent("payload/pkg/module.py"), atomically: true, encoding: .utf8)
        try "".write(to: root.appendingPathComponent("payload/pkg/__init__.py"), atomically: true, encoding: .utf8)
        try "".write(to: root.appendingPathComponent("payload/.gitkeep"), atomically: true, encoding: .utf8)
        try "notes\n".write(to: root.appendingPathComponent("payload/notes.txt"), atomically: true, encoding: .utf8)
        driver = ModalDriver()
        driver.start()
    }

    override func tearDown() async throws {
        driver.stop()
        for window in windows { window.close() }
        windows.removeAll()
        try? FileManager.default.removeItem(at: root)
    }

    private func makeBig(_ megabytes: Int) throws -> URL {
        let big = root.appendingPathComponent("payload/big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        var chunk = Data(count: 8 << 20)
        for round in 0..<(megabytes / 8) {
            chunk.withUnsafeMutableBytes { buffer in
                var state = UInt64(round) &* 6364136223846793005 &+ 1442695040888963407
                for index in stride(from: 0, to: buffer.count, by: 8) {
                    state = state &* 6364136223846793005 &+ 1442695040888963407
                    buffer.storeBytes(of: state, toByteOffset: index, as: UInt64.self)
                }
            }
            try handle.write(contentsOf: chunk)
        }
        try handle.close()
        return big
    }

    private func open(_ archive: URL) async throws -> ArchiveBrowserViewController {
        let browser = ArchiveBrowserViewController(session: ArchiveSession(archiveURL: archive))
        windows.append(Review2.host(browser))
        browser.loadArchive()
        try await Review2.waitFor("first load") { browser.hasLoadedOnce }
        return browser
    }

    // MARK: - E2b: an ordinary encrypted zip that holds an empty file

    func testExtractingAnEncryptedZipWithAnEmptyFileInItDuplicatesTheEmptyFile() async throws {
        let archive = root.appendingPathComponent("project.zip")
        let engine = SevenZipEngine()
        try await engine.create(archive: archive, items: [root.appendingPathComponent("payload")],
                                options: CompressionOptions(formatKey: "zip", password: "right"))
        let listing = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
        print("E2b entries:", listing.entries.map { "\($0.path) enc=\($0.isEncrypted) size=\($0.size)" })

        let destination = root.appendingPathComponent("out")
        func job(_ password: String?) -> ExtractionJob {
            ExtractionJob(archive: archive, destination: destination, password: password,
                          allEntries: listing.entries, selectedEntries: nil, roots: ["payload"],
                          folderConflicts: [], folderResolution: .merge, fileOverwrite: .renameNew)
        }
        // The browser's first pass: a zip lists without its password, so none is set.
        do {
            _ = try await ExtractionRunner.run(job(nil), engine: engine)
            XCTFail("expected a password problem")
        } catch let error as ArchiveError {
            XCTAssertTrue(error.isPasswordProblem, "\(error)")
        }
        // The prompt is answered correctly the first time, and the closure runs again.
        _ = try await ExtractionRunner.run(job("right"), engine: engine)
        var names: [String] = []
        let walker = FileManager.default.enumerator(atPath: destination.path)
        while let name = walker?.nextObject() as? String { names.append(name) }
        print("E2b extracted:", names.sorted())
        XCTAssertFalse(names.contains { $0.contains(" 2") }, "files appear twice: \(names.sorted())")
    }

    // MARK: - G: a reload while a file is being dragged out

    func testReloadingWhileAFileIsBeingDraggedOutBreaksTheDrag() async throws {
        let big = try makeBig(480)
        let archive = root.appendingPathComponent("big.zip")
        try await SevenZipEngine().create(archive: archive, items: [big, root.appendingPathComponent("payload/notes.txt")],
                                          options: CompressionOptions(formatKey: "zip", level: 5))
        let browser = try await open(archive)
        let node = try XCTUnwrap(browser.session.tree.node(at: "big.bin"))
        let promise = try XCTUnwrap(browser.makePromise(for: node))
        let destination = root.appendingPathComponent("dragged-big.bin")
        var finished = false
        var failure: Error?
        browser.filePromiseProvider(promise, writePromiseTo: destination) { error in
            failure = error
            finished = true
        }
        try await Task.sleep(nanoseconds: 25_000_000)
        XCTAssertFalse(finished)
        // Nothing stops View ▸ Reload, or a drop of another file, which ends in the same reload.
        let offered = browser.canPerform(#selector(ArchiveBrowserViewController.reloadArchive(_:)))
            && browser.canAcceptDrop(of: [root.appendingPathComponent("payload/notes.txt")])
        print("G reload and drops offered during the drag-out:", offered)
        let generation = browser.listingGeneration
        browser.reloadArchive(nil)
        try await Review2.waitFor("reload") { browser.listingGeneration > generation }
        try await Review2.waitFor("fulfilment", timeout: 60) { finished }
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue
        print("G drag-out error:", failure?.localizedDescription ?? "none", "| bytes delivered:", size ?? -1,
              "of", 480 << 20)
        XCTAssertNil(failure, "the reload removed the folder the dragged file was being extracted into")
        XCTAssertEqual(size, 480 << 20)
    }

    // MARK: - X: what a closed window leaves behind

    func testAClosedWindowIsReleasedAlongWithItsScratchFolder() async throws {
        let archive = root.appendingPathComponent("plain.zip")
        try await SevenZipEngine().create(archive: archive, items: [root.appendingPathComponent("payload")],
                                          options: CompressionOptions(formatKey: "zip"))
        var controller: ArchiveWindowController? = ArchiveWindowController(archive: archive)
        var window: NSWindow? = controller?.window
        var browser: ArchiveBrowserViewController? = (window?.contentViewController as? NSSplitViewController)?
            .splitViewItems.compactMap { $0.viewController as? ArchiveBrowserViewController }.first
        weak var weakController = controller
        weak var weakBrowser = browser
        weak var weakWindow = window
        controller?.loadArchive()
        try await Review2.waitFor("load") { weakBrowser?.hasLoadedOnce == true }

        // Use the things that hold closures and tasks: Quick Look, open, drag out, a rewrite.
        let scratch = browser!.scratchDirectory
        let node = try XCTUnwrap(browser!.session.tree.node(at: "payload/notes.txt"))
        _ = await browser!.materialize(node: node, quiet: true)
        let edited = await browser!.materialize(node: node, forEditing: true)
        browser!.editedFiles.track(localURL: try XCTUnwrap(edited), entryPath: node.path)
        let folder = try XCTUnwrap(browser!.session.tree.node(at: "payload/pkg"))
        let promise = try XCTUnwrap(browser!.makePromise(for: folder))
        let out = root.appendingPathComponent("pkg-out")
        let dragError: Error? = await withCheckedContinuation { continuation in
            browser!.filePromiseProvider(promise, writePromiseTo: out) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(dragError)
        let table = try XCTUnwrap(Review2.allSubviews(of: NSOutlineView.self, in: browser!.view).first)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        browser!.loadPreviewItems(showing: try XCTUnwrap(QLPreviewPanel.shared()), thenOpen: false)
        let extra = root.appendingPathComponent("extra.txt")
        try "x\n".write(to: extra, atomically: true, encoding: .utf8)
        browser!.add(items: [extra])
        try await Review2.waitFor("add") { weakBrowser?.session.tree.node(at: "extra.txt") != nil }
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.path))

        XCTAssertTrue(controller!.windowShouldClose(window!))
        window?.close()
        controller = nil
        browser = nil
        window = nil
        for _ in 0..<40 where weakBrowser != nil || FileManager.default.fileExists(atPath: scratch.path) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        print("X after closing: controller released =", weakController == nil, "browser released =", weakBrowser == nil,
              "window released =", weakWindow == nil, "scratch removed =", !FileManager.default.fileExists(atPath: scratch.path))
        XCTAssertNil(weakController)
        XCTAssertNil(weakBrowser, "the browser, and the decrypted files in its scratch folder, outlive the window")
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
    }

    // MARK: - R: what the Finder is told JustArc opens, against what it treats as an archive

    func testEveryExtensionDeclaredToTheFinderIsRoutedAsAnArchive() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/JustArc/Resources/Info.plist")
        let info = try XCTUnwrap(NSDictionary(contentsOf: plist) as? [String: Any])
        let types = try XCTUnwrap(info["CFBundleDocumentTypes"] as? [[String: Any]])
        let declared = types.flatMap { $0["CFBundleTypeExtensions"] as? [String] ?? [] }
        XCTAssertGreaterThan(declared.count, 20)
        // application(_:open:) sends whatever FormatRegistry.isArchive refuses to
        // "others", which become the contents of a new archive.
        let misrouted = declared.filter { !FormatRegistry.isArchive(URL(fileURLWithPath: "/tmp/sample.\($0)")) }
        print("R declared in Info.plist but not an archive to the app:", misrouted)
        // What Save As with a split size leaves the window on, and puts in Open Recent.
        let firstVolume = URL(fileURLWithPath: "/tmp/Backup.7z.001")
        print("R Backup.7z.001 is an archive:", FormatRegistry.isArchive(firstVolume),
              "| format:", FormatRegistry.format(for: firstVolume)?.key ?? "nil",
              "| default Save As stem:", FormatRegistry.baseName(for: firstVolume))
        XCTAssertEqual(misrouted, [])
    }
}
