import AppKit
import XCTest
@testable import JustArc
@testable import JustArcCore

@MainActor
final class BrowserBehaviourTests: XCTestCase {
    private var root: URL!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("justarc-browser-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("payload"),
                                                withIntermediateDirectories: true)
        try "first\n".write(to: root.appendingPathComponent("payload/notes.txt"), atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        for window in windows { window.close() }
        windows.removeAll()
        try? FileManager.default.removeItem(at: root)
    }

    private func openBrowser() async throws -> (ArchiveBrowserViewController, URL) {
        let archive = root.appendingPathComponent("sample.zip")
        try await SevenZipEngine().create(archive: archive, items: [root.appendingPathComponent("payload")],
                                          options: CompressionOptions(formatKey: "zip"))
        let browser = ArchiveBrowserViewController(session: ArchiveSession(archiveURL: archive))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = browser
        windows.append(window)
        browser.loadArchive()
        try await waitFor { browser.hasLoadedOnce }
        return (browser, archive)
    }

    private func waitFor(_ condition: @escaping () -> Bool, file: StaticString = #filePath,
                         line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting", file: file, line: line) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Two rewrites at once each start from the old file; the later one undoes the other.
    func testNothingElseStartsWhileAnOperationRuns() async throws {
        let (browser, _) = try await openBrowser()
        XCTAssertTrue(browser.canPerform(#selector(ArchiveBrowserViewController.addFiles(_:))))
        XCTAssertTrue(browser.canAcceptDrop(of: [root.appendingPathComponent("payload/notes.txt")]))

        browser.beginOperation()
        for action in [#selector(ArchiveBrowserViewController.addFiles(_:)),
                       #selector(ArchiveBrowserViewController.extractAll(_:)),
                       #selector(ArchiveBrowserViewController.testArchive(_:)),
                       #selector(ArchiveBrowserViewController.saveArchiveAs(_:)),
                       #selector(ArchiveBrowserViewController.reloadArchive(_:))] {
            XCTAssertFalse(browser.canPerform(action), "\(action) is offered during another operation")
        }
        XCTAssertFalse(browser.canAcceptDrop(of: [root.appendingPathComponent("payload/notes.txt")]))
        XCTAssertTrue(browser.canPerform(#selector(ArchiveBrowserViewController.showArchiveInfo(_:))))

        browser.endOperation()
        XCTAssertTrue(browser.canPerform(#selector(ArchiveBrowserViewController.addFiles(_:))))
    }

    /// A file extracted to be looked at used to be served from its first extraction
    /// for as long as the window lived, whatever happened to the archive since.
    func testAPreviewedFileIsExtractedAgainAfterTheArchiveChanges() async throws {
        let (browser, archive) = try await openBrowser()
        let node = try XCTUnwrap(browser.session.tree.node(at: "payload/notes.txt"))
        let before = await browser.materialize(node: node, quiet: true)
        XCTAssertEqual(try String(contentsOf: try XCTUnwrap(before), encoding: .utf8), "first\n")

        // The archive gets a newer notes.txt, as dragging one in would give it.
        let newer = root.appendingPathComponent("newer/notes.txt")
        try FileManager.default.createDirectory(at: newer.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "second\n".write(to: newer, atomically: true, encoding: .utf8)
        try await SevenZipEngine().add(items: [newer], to: archive, into: "payload",
                                       options: CompressionOptions(formatKey: "zip"), cancellation: nil, progress: nil)
        let generation = browser.listingGeneration
        browser.loadArchive()
        try await waitFor { browser.listingGeneration > generation }

        let fresh = try XCTUnwrap(browser.session.tree.node(at: "payload/notes.txt"))
        let after = await browser.materialize(node: fresh, quiet: true)
        XCTAssertEqual(try String(contentsOf: try XCTUnwrap(after), encoding: .utf8), "second\n",
                       "the copy made before the archive changed was served again")
    }

    /// A copy another app may have open is left alone while the archive changes.
    func testAFileOpenForEditingKeepsItsCopy() async throws {
        let (browser, _) = try await openBrowser()
        let node = try XCTUnwrap(browser.session.tree.node(at: "payload/notes.txt"))
        let opened = await browser.materialize(node: node, forEditing: true)
        let first = try XCTUnwrap(opened)
        browser.editedFiles.track(localURL: first, entryPath: node.path)
        try "edited by hand\n".write(to: first, atomically: true, encoding: .utf8)

        let reopened = await browser.materialize(node: node, forEditing: true)
        let again = try XCTUnwrap(reopened)
        XCTAssertEqual(again, first)
        XCTAssertEqual(try String(contentsOf: again, encoding: .utf8), "edited by hand\n")

        // Looking at the entry, by contrast, shows what the archive holds.
        let looked = await browser.materialize(node: node, quiet: true)
        let viewed = try XCTUnwrap(looked)
        XCTAssertNotEqual(viewed, first)
        XCTAssertEqual(try String(contentsOf: viewed, encoding: .utf8), "first\n")
    }

    func testRenamingOrDeletingAFolderStopsTrackingWhatWasOpenedFromIt() {
        let watcher = EditedFileWatcher()
        let file = root.appendingPathComponent("payload/notes.txt")
        watcher.track(localURL: file, entryPath: "docs/a/notes.txt")
        watcher.track(localURL: file, entryPath: "docs-other/notes.txt")
        watcher.stopTracking(under: "docs")
        XCTAssertNil(watcher.localURL(for: "docs/a/notes.txt"))
        XCTAssertNotNil(watcher.localURL(for: "docs-other/notes.txt"), "a folder that merely starts the same")
    }

    func testTheEditMenuCarriesTheClipboardCommands() {
        let menu = MainMenuBuilder.build(recentMenu: NSMenu())
        let actions = menu.items.flatMap { $0.submenu?.items ?? [] }.compactMap(\.action)
        for wanted in [#selector(NSText.cut(_:)), #selector(NSText.copy(_:)), #selector(NSText.paste(_:)),
                       Selector(("undo:"))] {
            XCTAssertTrue(actions.contains(wanted), "\(wanted) is missing, so its shortcut does nothing")
        }
    }

    /// A translation that takes its arguments in another order has to say so with
    /// positional specifiers; otherwise an integer is read as an object and the app
    /// crashes the moment the string is shown.
    func testEveryTranslationTakesTheArgumentsItsKeyDoes() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/JustArc/Resources")
        let table = try XCTUnwrap(NSDictionary(contentsOf: resources.appendingPathComponent("ru.lproj/Localizable.strings"))
            as? [String: String])
        XCTAssertGreaterThan(table.count, 300)

        let specifier = try NSRegularExpression(pattern: #"%(?:(\d+)\$)?[-+ 0#]*\d*(?:\.\d+)?l{0,2}([dDuUxXfFeEgGcCsS@])|%%"#)
        func types(_ text: String) -> [String]? {
            var plain: [String] = []
            var positional: [Int: String] = [:]
            let whole = NSRange(text.startIndex..., in: text)
            for match in specifier.matches(in: text, range: whole) {
                guard match.range(at: 2).location != NSNotFound else { continue }  // "%%"
                let kind = (text as NSString).substring(with: match.range(at: 2)).lowercased()
                if match.range(at: 1).location != NSNotFound {
                    positional[Int((text as NSString).substring(with: match.range(at: 1)))!] = kind
                } else {
                    plain.append(kind)
                }
            }
            if !positional.isEmpty && !plain.isEmpty { return nil }
            if positional.isEmpty { return plain }
            guard positional.keys.sorted() == Array(1...positional.count) else { return nil }
            return positional.keys.sorted().map { positional[$0]! }
        }
        for (key, value) in table {
            XCTAssertEqual(types(value), types(key), "“\(key)” → “\(value)”")
        }
    }
}
