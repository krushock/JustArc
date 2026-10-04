import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import JustArc
@testable import JustArcCore

/// Drops files on the window the way AppKit does: find the view under the pointer,
/// walk up to the first one registered for files, and send it the drag messages.
@MainActor
final class DragAndDropTests: XCTestCase {
    private var root: URL!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("justarc-app-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("payload/docs"),
                                                withIntermediateDirectories: true)
        try "hello\n".write(to: root.appendingPathComponent("payload/readme.txt"),
                            atomically: true, encoding: .utf8)
        try "notes\n".write(to: root.appendingPathComponent("payload/docs/notes.txt"),
                            atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        for window in windows { window.close() }
        windows.removeAll()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Dropping in

    func testFilesDroppedOnTheListOfAnEmptyWindowAreStaged() async throws {
        let (browser, window) = makeBrowser(archive: nil)
        let table = try XCTUnwrap(firstSubview(of: NSOutlineView.self, in: browser.view))
        let point = table.convert(NSPoint(x: table.bounds.midX, y: table.bounds.midY), to: nil)

        XCTAssertTrue(drop([root.appendingPathComponent("payload")], in: window, at: point))
        try await waitFor { !browser.isBusy }
        XCTAssertEqual(browser.session.stagedRoots.map(\.lastPathComponent), ["payload"])
        XCTAssertTrue(browser.session.hasUnsavedChanges)
    }

    /// The message sits on top of the list, not inside it, and it is exactly where
    /// someone reading "Drop files here" lets go.
    func testFilesDroppedOnTheDropHereMessageAreStaged() async throws {
        let (browser, window) = makeBrowser(archive: nil)
        let label = try XCTUnwrap(allSubviews(of: NSTextField.self, in: browser.view)
            .first { $0.stringValue == L("Drop files here to start an archive") })
        XCTAssertFalse(label.isHidden)
        let point = label.convert(NSPoint(x: label.bounds.midX, y: label.bounds.midY), to: nil)

        XCTAssertTrue(drop([root.appendingPathComponent("payload/readme.txt")], in: window, at: point))
        try await waitFor { !browser.isBusy }
        XCTAssertEqual(browser.session.stagedRoots.map(\.lastPathComponent), ["readme.txt"])
    }

    func testFilesDroppedOnTheStatusBarAreStaged() async throws {
        let (browser, window) = makeBrowser(archive: nil)
        let bar = try XCTUnwrap(firstSubview(of: ArchiveStatusBar.self, in: browser.view))
        let point = bar.convert(NSPoint(x: bar.bounds.midX, y: bar.bounds.midY), to: nil)

        XCTAssertTrue(drop([root.appendingPathComponent("payload/readme.txt")], in: window, at: point))
        try await waitFor { !browser.isBusy }
        XCTAssertEqual(browser.session.stagedRoots.count, 1)
    }

    func testAnArchiveDroppedOnAnEmptyWindowIsOpenedNotAdded() async throws {
        let archive = try await makeZip()
        let (browser, window) = makeBrowser(archive: nil)
        var opened: [URL] = []
        browser.onOpenArchives = { opened = $0 }
        let table = try XCTUnwrap(firstSubview(of: NSOutlineView.self, in: browser.view))
        let point = table.convert(NSPoint(x: table.bounds.midX, y: table.bounds.midY), to: nil)

        XCTAssertTrue(drop([archive], in: window, at: point))
        await settle()
        XCTAssertEqual(opened, [archive])
        XCTAssertTrue(browser.session.stagedRoots.isEmpty, "the archive was added as a file instead")
    }

    func testAnArchiveDroppedOnAWindowWithFilesInItIsAddedLikeAnyFile() async throws {
        let archive = try await makeZip()
        let (browser, window) = makeBrowser(archive: nil)
        browser.session.stage(items: [root.appendingPathComponent("payload/readme.txt")])
        browser.reloadFromSession()
        var opened: [URL] = []
        browser.onOpenArchives = { opened = $0 }
        let table = try XCTUnwrap(firstSubview(of: NSOutlineView.self, in: browser.view))
        let point = table.convert(NSPoint(x: table.bounds.midX, y: table.bounds.maxY - 10), to: nil)

        XCTAssertTrue(drop([archive], in: window, at: point))
        await settle()
        try await waitFor { !browser.isBusy }
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(browser.session.stagedRoots.count, 2)
    }

    // MARK: - Dropping into a folder

    func testFilesDroppedWhileInsideAFolderGoIntoThatFolder() async throws {
        let archive = try await makeZip()
        let (browser, window) = makeBrowser(archive: archive)
        try await browser.session.load()
        browser.reloadFromSession()
        browser.navigate(to: "payload/docs")
        XCTAssertEqual(browser.currentFolderPath, "payload/docs")

        let extra = try makeExtra()
        let table = try XCTUnwrap(firstSubview(of: NSOutlineView.self, in: browser.view))
        // Below the last row, on the empty part of the list.
        let point = table.convert(NSPoint(x: table.bounds.midX, y: table.bounds.maxY - 10), to: nil)
        XCTAssertTrue(drop([extra], in: window, at: point))

        try await waitFor { browser.session.tree.node(at: "payload/docs/extra.txt") != nil }
        XCTAssertNil(browser.session.tree.node(at: "extra.txt"), "the file went to the root as well")
        XCTAssertEqual(browser.currentFolderPath, "payload/docs", "the list jumped out of the folder")

        let onDisk = try await SevenZipEngine().list(archive: archive, password: nil, encodingCodePage: nil)
        XCTAssertTrue(onDisk.entries.contains { $0.path == "payload/docs/extra.txt" })
    }

    func testFilesDroppedOnTheStatusBarWhileInsideAFolderGoIntoItToo() async throws {
        let archive = try await makeZip()
        let (browser, window) = makeBrowser(archive: archive)
        try await browser.session.load()
        browser.reloadFromSession()
        browser.navigate(to: "payload")

        let bar = try XCTUnwrap(firstSubview(of: ArchiveStatusBar.self, in: browser.view))
        let point = bar.convert(NSPoint(x: bar.bounds.midX, y: bar.bounds.midY), to: nil)
        XCTAssertTrue(drop([try makeExtra()], in: window, at: point))
        try await waitFor { browser.session.tree.node(at: "payload/extra.txt") != nil }
    }

    func testFilesDroppedOnAFolderRowGoIntoThatFolder() async throws {
        let archive = try await makeZip()
        let (browser, window) = makeBrowser(archive: archive)
        try await browser.session.load()
        browser.reloadFromSession()
        browser.navigate(to: "payload")

        // At "payload" the rows are "..", then the "docs" folder, then readme.txt.
        let table = try XCTUnwrap(firstSubview(of: NSOutlineView.self, in: browser.view))
        let row = try XCTUnwrap((0..<table.numberOfRows).first {
            (table.item(atRow: $0) as? EntryTree.Node)?.path == "payload/docs" })
        let rect = table.rect(ofRow: row)
        XCTAssertTrue(drop([try makeExtra()], in: window,
                           at: table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)))

        try await waitFor { browser.session.tree.node(at: "payload/docs/extra.txt") != nil }
        XCTAssertNil(browser.session.tree.node(at: "payload/extra.txt"))
        XCTAssertEqual(browser.currentFolderPath, "payload")
    }

    func testFilesDroppedOnAFileRowGoWhereTheListIs() async throws {
        let archive = try await makeZip()
        let (browser, window) = makeBrowser(archive: archive)
        try await browser.session.load()
        browser.reloadFromSession()
        browser.navigate(to: "payload")

        let table = try XCTUnwrap(firstSubview(of: NSOutlineView.self, in: browser.view))
        let row = try XCTUnwrap((0..<table.numberOfRows).first {
            (table.item(atRow: $0) as? EntryTree.Node)?.path == "payload/readme.txt" })
        let rect = table.rect(ofRow: row)
        XCTAssertTrue(drop([try makeExtra()], in: window,
                           at: table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)))
        try await waitFor { browser.session.tree.node(at: "payload/extra.txt") != nil }
    }

    func testANewArchiveTakesFilesIntoTheFolderBeingShown() async throws {
        let (browser, window) = makeBrowser(archive: nil)
        browser.session.stage(items: [root.appendingPathComponent("payload")])
        browser.reloadFromSession()
        browser.navigate(to: "payload/docs")

        let table = try XCTUnwrap(firstSubview(of: NSOutlineView.self, in: browser.view))
        let point = table.convert(NSPoint(x: table.bounds.midX, y: table.bounds.maxY - 10), to: nil)
        XCTAssertTrue(drop([try makeExtra()], in: window, at: point))
        try await waitFor { !browser.isBusy }

        XCTAssertNotNil(browser.session.tree.node(at: "payload/docs/extra.txt"))
        XCTAssertNil(browser.session.tree.node(at: "extra.txt"))
        XCTAssertEqual(browser.currentFolderPath, "payload/docs")
    }

    func testDeletingAFileFromANewArchiveTakesItOutOfTheList() throws {
        let (browser, _) = makeBrowser(archive: nil)
        browser.session.stage(items: [root.appendingPathComponent("payload")])
        browser.reloadFromSession()
        browser.navigate(to: "payload")

        let table = try XCTUnwrap(firstSubview(of: NSOutlineView.self, in: browser.view))
        let row = try XCTUnwrap((0..<table.numberOfRows).first {
            (table.item(atRow: $0) as? EntryTree.Node)?.path == "payload/readme.txt" })
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        // No confirmation is shown for a new archive: nothing on disk changes.
        browser.deleteSelected(nil)

        XCTAssertNil(browser.session.tree.node(at: "payload/readme.txt"))
        XCTAssertNotNil(browser.session.tree.node(at: "payload/docs/notes.txt"))
        XCTAssertFalse((0..<table.numberOfRows).contains {
            (table.item(atRow: $0) as? EntryTree.Node)?.path == "payload/readme.txt" })
    }

    func testAddFilesUsesTheFolderBeingShown() async throws {
        let archive = try await makeZip()
        let (browser, _) = makeBrowser(archive: archive)
        try await browser.session.load()
        browser.reloadFromSession()
        browser.navigate(to: "payload/docs")

        // What the Add Files panel calls once files are chosen.
        browser.add(items: [try makeExtra()])
        try await waitFor { browser.session.tree.node(at: "payload/docs/extra.txt") != nil }
    }

    func testAReadOnlyArchiveRefusesDrops() throws {
        // An ISO image can be read but not written, so there is nowhere for files to go.
        let iso = root.appendingPathComponent("disc.iso")
        try Data().write(to: iso)
        let (browser, window) = makeBrowser(archive: iso)
        XCTAssertFalse(browser.session.canModifyContents)

        let table = try XCTUnwrap(firstSubview(of: NSOutlineView.self, in: browser.view))
        let onList = table.convert(NSPoint(x: table.bounds.midX, y: table.bounds.midY), to: nil)
        XCTAssertFalse(drop([root.appendingPathComponent("payload")], in: window, at: onList))

        let bar = try XCTUnwrap(firstSubview(of: ArchiveStatusBar.self, in: browser.view))
        let onBar = bar.convert(NSPoint(x: bar.bounds.midX, y: bar.bounds.midY), to: nil)
        XCTAssertFalse(drop([root.appendingPathComponent("payload")], in: window, at: onBar))
    }

    func testAnArchiveDroppedOnTheSidebarIsOpened() async throws {
        let archive = try await makeZip()
        let sidebar = SidebarViewController()
        var opened: [URL] = []
        sidebar.onOpen = { opened.append($0) }
        let window = host(sidebar)
        let point = sidebar.view.convert(NSPoint(x: sidebar.view.bounds.midX, y: sidebar.view.bounds.midY), to: nil)

        XCTAssertTrue(drop([archive], in: window, at: point))
        await settle()
        XCTAssertEqual(opened, [archive])
        XCTAssertFalse(drop([root.appendingPathComponent("payload/readme.txt")], in: window, at: point),
                       "the sidebar opens archives; it is not somewhere to put files")
    }

    // MARK: - Dragging out

    func testAFileCanBeDraggedOutToTheFinder() async throws {
        let archive = try await makeZip()
        let (browser, _) = makeBrowser(archive: archive)
        try await browser.session.load()
        browser.reloadFromSession()

        let node = try XCTUnwrap(browser.session.tree.node(at: "payload/readme.txt"))
        let destination = root.appendingPathComponent("dragged-readme.txt")
        try await fulfil(try XCTUnwrap(browser.makePromise(for: node)), with: browser, at: destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "hello\n")
    }

    func testAFolderCanBeDraggedOutToTheFinder() async throws {
        let archive = try await makeZip()
        let (browser, _) = makeBrowser(archive: archive)
        try await browser.session.load()
        browser.reloadFromSession()

        let node = try XCTUnwrap(browser.session.tree.node(at: "payload"))
        let promise = try XCTUnwrap(browser.makePromise(for: node), "folders had no drag promise")
        XCTAssertEqual(promise.fileType, UTType.folder.identifier)
        XCTAssertEqual(browser.filePromiseProvider(promise, fileNameForType: promise.fileType), "payload")

        let destination = root.appendingPathComponent("dragged-out/payload")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try await fulfil(promise, with: browser, at: destination)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("docs/notes.txt"),
                                  encoding: .utf8), "notes\n")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("readme.txt"),
                                  encoding: .utf8), "hello\n")
    }

    func testEveryRowOffersADragPromise() async throws {
        let archive = try await makeZip()
        let (browser, _) = makeBrowser(archive: archive)
        try await browser.session.load()
        browser.reloadFromSession()

        let table = try XCTUnwrap(firstSubview(of: NSOutlineView.self, in: browser.view))
        let source = try XCTUnwrap(table.dataSource)
        XCTAssertGreaterThan(table.numberOfRows, 0)
        for row in 0..<table.numberOfRows {
            let item = try XCTUnwrap(table.item(atRow: row))
            XCTAssertNotNil(source.outlineView?(table, pasteboardWriterForItem: item), "row \(row)")
        }
    }

    // MARK: - Plumbing

    private func makeBrowser(archive: URL?) -> (ArchiveBrowserViewController, NSWindow) {
        let browser = ArchiveBrowserViewController(session: ArchiveSession(archiveURL: archive))
        return (browser, host(browser))
    }

    private func host(_ controller: NSViewController) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 800, height: 500))
        window.layoutIfNeeded()
        windows.append(window)
        return window
    }

    private func makeZip() async throws -> URL {
        let archive = root.appendingPathComponent("sample.zip")
        try await SevenZipEngine().create(archive: archive, items: [root.appendingPathComponent("payload")],
                                          options: CompressionOptions(formatKey: "zip"))
        return archive
    }

    private func makeExtra() throws -> URL {
        let extra = root.appendingPathComponent("extra.txt")
        try "added later\n".write(to: extra, atomically: true, encoding: .utf8)
        return extra
    }

    /// Adding to an archive on disk runs in the background and then reloads the list.
    private func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval = 10,
                         file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Lets work queued on the main queue run.
    private func settle() async {
        for _ in 0..<3 { await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } } }
    }

    private func fulfil(_ promise: NSFilePromiseProvider, with browser: ArchiveBrowserViewController,
                        at destination: URL) async throws {
        let error: Error? = await withCheckedContinuation { continuation in
            browser.filePromiseProvider(promise, writePromiseTo: destination) { continuation.resume(returning: $0) }
        }
        if let error { throw error }
    }

    /// Sends a drop of `urls` to whatever would receive it at `point`, in window
    /// coordinates. Returns whether the drop was taken.
    private func drop(_ urls: [URL], in window: NSWindow, at point: NSPoint) -> Bool {
        var view = window.contentView?.hitTest(point)
        while let candidate = view, !candidate.registeredDraggedTypes.contains(.fileURL) {
            view = candidate.superview
        }
        guard let target = view else { return false }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("justarc-tests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        defer { pasteboard.releaseGlobally() }
        let info = FakeDrag(pasteboard: pasteboard, location: point, window: window)

        guard !target.draggingEntered(info).isEmpty, !target.draggingUpdated(info).isEmpty else { return false }
        guard target.prepareForDragOperation(info) else { return false }
        let taken = target.performDragOperation(info)
        target.concludeDragOperation(info)
        return taken
    }

    private func firstSubview<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        allSubviews(of: type, in: view).first
    }

    private func allSubviews<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { subview in
            ((subview as? T).map { [$0] } ?? []) + allSubviews(of: type, in: subview)
        }
    }
}

/// The least a view needs to believe files are being dragged over it.
private final class FakeDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    let draggingDestinationWindow: NSWindow?

    init(pasteboard: NSPasteboard, location: NSPoint, window: NSWindow) {
        self.draggingPasteboard = pasteboard
        self.draggingLocation = location
        self.draggingDestinationWindow = window
    }

    var draggingSourceOperationMask: NSDragOperation { [.copy, .generic] }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [],
                                for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
