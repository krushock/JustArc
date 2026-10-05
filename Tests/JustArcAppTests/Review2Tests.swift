import AppKit
import QuickLookUI
import UniformTypeIdentifiers
import XCTest
@testable import JustArc
@testable import JustArcCore

/// Second-pass review experiments that need no modal dialog answered.
@MainActor
final class Review2Tests: XCTestCase {
    private var root: URL!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        _ = NSApplication.shared
        ModalWatchdog.arm()
        root = try Review2.makeRoot()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("payload"),
                                                withIntermediateDirectories: true)
        try "plain\n".write(to: root.appendingPathComponent("payload/plain.txt"), atomically: true, encoding: .utf8)
        try "secret\n".write(to: root.appendingPathComponent("payload/secret.txt"), atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        for window in windows { window.close() }
        windows.removeAll()
        try? FileManager.default.removeItem(at: root)
    }

    private func open(_ archive: URL, password: String? = nil) async throws -> ArchiveBrowserViewController {
        let session = ArchiveSession(archiveURL: archive)
        session.password = password
        let browser = ArchiveBrowserViewController(session: session)
        windows.append(Review2.host(browser))
        browser.loadArchive()
        try await Review2.waitFor("first load") { browser.hasLoadedOnce }
        return browser
    }

    // MARK: - E0: what a modal dialog inside a Task does to the main queue

    func testANestedRunLoopInsideAMainQueueBlockDoesNotServiceTheMainQueue() async throws {
        var ranInsideNested = false
        var ranAtAll = false
        let done = expectation(description: "outer block finished")
        DispatchQueue.main.async {
            DispatchQueue.main.async { ranAtAll = true }
            Task { @MainActor in ranAtAll = true }
            // What NSAlert.runModal does, for a third of a second.
            RunLoop.current.run(mode: .modalPanel, before: Date().addingTimeInterval(0.3))
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.3))
            ranInsideNested = ranAtAll
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
        try await Review2.waitFor("inner blocks") { ranAtAll }
        XCTAssertFalse(ranInsideNested,
                       "main-queue work DID run inside a run loop nested in a main-queue block")
    }

    // MARK: - E1: an entry whose path climbs out of the scratch folder

    func testAnEntryNamedWithDotDotIsServedFromOutsideTheScratchFolder() async throws {
        // A file of the user's own, outside anything JustArc extracted.
        let outside = root.appendingPathComponent("outside-the-archive.txt")
        try "NOT IN THE ARCHIVE\n".write(to: outside, atomically: true, encoding: .utf8)

        // scratch is <tmp>/JustArc/<uuid>/view-N, so the climb is fixed whatever the uuid;
        // from "/" the rest is an absolute path the archive's author chooses.
        let climb = String(repeating: "../", count: 40)
        let evilName = climb + String(outside.path.dropFirst())
        let archive = root.appendingPathComponent("evil.zip")
        let script = """
        import zipfile, sys
        z = zipfile.ZipFile(sys.argv[1], 'w')
        z.writestr('readme.txt', 'hello')
        z.writestr(sys.argv[2], 'what the archive really holds')
        z.close()
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", script, archive.path, evilName]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let browser = try await open(archive)
        let listed = browser.session.listing.entries.map(\.path)
        print("E1 listed entries:", listed.map { $0.count > 60 ? "…" + $0.suffix(60) : $0 })
        let evil = try XCTUnwrap(browser.session.listing.entries.first { $0.path.hasSuffix("outside-the-archive.txt") },
                                 "the engine did not list the climbing entry at all")
        let node = try XCTUnwrap(browser.session.tree.node(at: evil.path))
        XCTAssertNotNil(node.entry)

        // Before anything else was looked at, the viewing folder does not exist yet.
        let first = await browser.materialize(node: node, quiet: true)
        print("E1 before any other preview:", first?.path ?? "nil")

        // Quick Look on an ordinary file creates view-N.
        let readme = try XCTUnwrap(browser.session.tree.node(at: "readme.txt"))
        let ordinary = await browser.materialize(node: readme, quiet: true)
        XCTAssertNotNil(ordinary)

        let served = await browser.materialize(node: node, quiet: true)
        print("E1 after an ordinary preview:", served?.standardizedFileURL.path ?? "nil")
        if let served {
            let scratch = browser.scratchDirectory.standardizedFileURL.path
            let resolved = served.resolvingSymlinksInPath().path
            print("E1 resolved:", resolved, "scratch:", scratch)
            XCTAssertTrue(resolved.hasPrefix(browser.scratchDirectory.resolvingSymlinksInPath().path),
                          "materialize handed back a file outside the scratch folder: \(resolved)")
            print("E1 contents served:", (try? String(contentsOf: served, encoding: .utf8)) ?? "?")
        }

        // Dragging the row out copies whatever materialize returned.
        let promise = try XCTUnwrap(browser.makePromise(for: node))
        let destination = root.appendingPathComponent("dragged-out.txt")
        let error: Error? = await withCheckedContinuation { continuation in
            browser.filePromiseProvider(promise, writePromiseTo: destination) { continuation.resume(returning: $0) }
        }
        print("E1 drag-out error:", error?.localizedDescription ?? "none",
              "copied:", (try? String(contentsOf: destination, encoding: .utf8)) ?? "nothing")
        XCTAssertNotEqual(try? String(contentsOf: destination, encoding: .utf8), "NOT IN THE ARCHIVE\n",
                          "dragging the entry out copied a file that was never in the archive")
    }

    // MARK: - E2: what the password retry does to files already extracted

    func testRetryingAfterAPasswordFailureDuplicatesWhatWasAlreadyExtracted() async throws {
        // One file added without a password, one with: what JustArc itself produces
        // when a file is dropped on an encrypted zip before its password was asked for.
        let archive = root.appendingPathComponent("mixed.zip")
        let engine = SevenZipEngine()
        try await engine.create(archive: archive, items: [root.appendingPathComponent("payload/plain.txt")],
                                options: CompressionOptions(formatKey: "zip"))
        try await engine.add(items: [root.appendingPathComponent("payload/secret.txt")], to: archive, into: "",
                             options: CompressionOptions(formatKey: "zip", password: "right"),
                             cancellation: nil, progress: nil)
        let listing = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
        print("E2 entries:", listing.entries.map { "\($0.path) encrypted=\($0.isEncrypted)" })

        let destination = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        func job(_ password: String?) -> ExtractionJob {
            // Exactly what extract(entries:revealing:label:) and Quick Extract build:
            // no conflicts were found up front, so files default to Keep Both.
            ExtractionJob(archive: archive, destination: destination, password: password,
                          allEntries: listing.entries, selectedEntries: nil,
                          roots: ["plain.txt", "secret.txt"], folderConflicts: [],
                          folderResolution: .merge, fileOverwrite: .renameNew)
        }
        // First pass of withPasswordRetry: no password yet.
        do {
            _ = try await ExtractionRunner.run(job(nil), engine: engine)
            XCTFail("expected a password problem")
        } catch let error as ArchiveError {
            XCTAssertTrue(error.isPasswordProblem, "\(error)")
        }
        print("E2 after the failed pass:", try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted())
        // The prompt is answered and the same closure runs again.
        _ = try await ExtractionRunner.run(job("right"), engine: engine)
        let names = try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted()
        print("E2 after the retry:", names)
        XCTAssertEqual(names, ["plain.txt", "secret.txt"], "the retry extracted a second copy beside the first")
    }

    // MARK: - E3: adding to an encrypted zip

    /// Types the archive's password at the prompt that adding to it now puts up.
    private func answerPasswordPrompts(with password: String) -> ModalDriver {
        let driver = ModalDriver()
        driver.onModal = { driver, window, _ in
            driver.type(password, in: window)
            driver.press("Continue", in: window)
        }
        driver.start()
        return driver
    }

    private func makeEncryptedZip() async throws -> URL {
        let archive = root.appendingPathComponent("locked.zip")
        try await SevenZipEngine().create(archive: archive, items: [root.appendingPathComponent("payload/secret.txt")],
                                          options: CompressionOptions(formatKey: "zip", password: "right"))
        return archive
    }

    func testAFileAddedToAnEncryptedZipIsEncryptedOnceThePasswordIsGiven() async throws {
        let archive = try await makeEncryptedZip()
        let browser = try await open(archive)
        XCTAssertTrue(browser.session.listing.containsEncryptedEntries)
        XCTAssertNil(browser.session.password)

        let extra = root.appendingPathComponent("tax-return.txt")
        try "private\n".write(to: extra, atomically: true, encoding: .utf8)
        // Nothing is written to an encrypted archive until its password is known:
        // the prompt comes first, and the right answer is given here.
        let driver = answerPasswordPrompts(with: "right")
        defer { driver.stop() }
        browser.add(items: [extra])
        try await Review2.waitFor("add") { browser.session.tree.node(at: "tax-return.txt") != nil }

        let onDisk = try await SevenZipEngine().list(archive: archive, password: nil, encodingCodePage: nil)
        let added = try XCTUnwrap(onDisk.entries.first { $0.path == "tax-return.txt" })
        print("E3a entries:", onDisk.entries.map { "\($0.path) encrypted=\($0.isEncrypted)" })
        XCTAssertTrue(added.isEncrypted, "a file added to an encrypted archive was stored in the clear, without a word")
    }

    func testTheSameForASevenZipArchiveWithoutHiddenNames() async throws {
        let archive = root.appendingPathComponent("locked.7z")
        try await SevenZipEngine().create(archive: archive, items: [root.appendingPathComponent("payload/secret.txt")],
                                          options: CompressionOptions(formatKey: "7z", password: "right"))
        let browser = try await open(archive)
        XCTAssertTrue(browser.session.listing.containsEncryptedEntries)
        let extra = root.appendingPathComponent("tax-return.txt")
        try "private\n".write(to: extra, atomically: true, encoding: .utf8)
        // Nothing is written to an encrypted archive until its password is known:
        // the prompt comes first, and the right answer is given here.
        let driver = answerPasswordPrompts(with: "right")
        defer { driver.stop() }
        browser.add(items: [extra])
        try await Review2.waitFor("add") { browser.session.tree.node(at: "tax-return.txt") != nil }
        let onDisk = try await SevenZipEngine().list(archive: archive, password: nil, encodingCodePage: nil)
        print("E3a-7z entries:", onDisk.entries.map { "\($0.path) encrypted=\($0.isEncrypted)" })
        XCTAssertEqual(onDisk.entries.first { $0.path == "tax-return.txt" }?.isEncrypted, true)
    }

    func testAMistypedPasswordIsNotUsedForWhatIsAddedNext() async throws {
        let archive = try await makeEncryptedZip()
        let browser = try await open(archive)
        // What withPasswordRetry leaves behind when the retry prompt is cancelled.
        browser.session.password = "tpyo"

        let extra = root.appendingPathComponent("tax-return.txt")
        try "private\n".write(to: extra, atomically: true, encoding: .utf8)
        // Nothing is written to an encrypted archive until its password is known:
        // the prompt comes first, and the right answer is given here.
        let driver = answerPasswordPrompts(with: "right")
        defer { driver.stop() }
        browser.add(items: [extra])
        try await Review2.waitFor("add") { browser.session.tree.node(at: "tax-return.txt") != nil }

        let engine = SevenZipEngine()
        let onDisk = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
        let added = try XCTUnwrap(onDisk.entries.first { $0.path == "tax-return.txt" })
        print("E3b entries:", onDisk.entries.map { "\($0.path) encrypted=\($0.isEncrypted)" })
        let out = root.appendingPathComponent("check")
        var opensWithRight = true
        do {
            try await engine.extract(archive: archive, entries: [added], to: out, password: "right",
                                     overwrite: .overwrite, flattenPaths: false, cancellation: nil, progress: nil)
        } catch { opensWithRight = false; print("E3b with the archive's real password:", error) }
        var opensWithTypo = true
        do {
            try await engine.extract(archive: archive, entries: [added], to: out, password: "tpyo",
                                     overwrite: .overwrite, flattenPaths: false, cancellation: nil, progress: nil)
        } catch { opensWithTypo = false }
        print("E3b opens with right:", opensWithRight, "opens with typo:", opensWithTypo)
        XCTAssertTrue(opensWithRight, "the added file cannot be opened with the archive's password")
    }

    // MARK: - E5: dragging out is not "busy"

    func testAWindowCanBeClosedWhileAFileIsStillBeingDraggedOut() async throws {
        // Big enough that extraction takes a moment.
        let big = root.appendingPathComponent("payload/big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        var chunk = Data(count: 8 << 20)
        for round in 0..<40 {
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
        let archive = root.appendingPathComponent("big.zip")
        try await SevenZipEngine().create(archive: archive, items: [big],
                                          options: CompressionOptions(formatKey: "zip", level: 5))

        let controller = ArchiveWindowController(archive: archive)
        let window = try XCTUnwrap(controller.window)
        windows.append(window)
        let split = try XCTUnwrap(window.contentViewController as? NSSplitViewController)
        let browser = try XCTUnwrap(split.splitViewItems.compactMap {
            $0.viewController as? ArchiveBrowserViewController }.first)
        controller.loadArchive()
        try await Review2.waitFor("load") { browser.hasLoadedOnce }

        let node = try XCTUnwrap(browser.session.tree.node(at: "big.bin"))
        let promise = try XCTUnwrap(browser.makePromise(for: node))
        let destination = root.appendingPathComponent("dragged-big.bin")
        var finished = false
        var failure: Error?
        browser.filePromiseProvider(promise, writePromiseTo: destination) { error in
            failure = error
            finished = true
        }
        // Let the fulfilment get going.
        try await Task.sleep(nanoseconds: 25_000_000)
        print("E5 25 ms into the drag-out: finished=\(finished) isBusy=\(controller.isBusy)")
        XCTAssertFalse(finished, "the extraction finished too fast for this experiment to mean anything")
        let mayClose = controller.windowShouldClose(window)
        print("E5 windowShouldClose while the promise is being fulfilled:", mayClose)
        XCTAssertFalse(mayClose, "the window agrees to close while a drag-out is still being written")
        try await Review2.waitFor("fulfilment", timeout: 60) { finished }
        print("E5 fulfilment error:", failure?.localizedDescription ?? "none")
    }

    // MARK: - E7: Settings writes every control back

    func testAChoiceMadeElsewhereIsUndoneByTheNextClickInSettings() throws {
        let defaults = UserDefaults.standard
        let saved = (defaults.object(forKey: Preferences.Key.overwriteMode),
                     defaults.object(forKey: Preferences.Key.revealInFinder),
                     defaults.object(forKey: Preferences.Key.extractDestination),
                     defaults.object(forKey: Preferences.Key.smartFolder),
                     defaults.object(forKey: Preferences.Key.moveArchiveToTrash),
                     defaults.object(forKey: Preferences.Key.quitAfterQuickExtract),
                     defaults.object(forKey: Preferences.Key.archiveOpenAction),
                     defaults.object(forKey: Preferences.Key.folderConflictMode))
        defer {
            defaults.set(saved.0, forKey: Preferences.Key.overwriteMode)
            defaults.set(saved.1, forKey: Preferences.Key.revealInFinder)
            defaults.set(saved.2, forKey: Preferences.Key.extractDestination)
            defaults.set(saved.3, forKey: Preferences.Key.smartFolder)
            defaults.set(saved.4, forKey: Preferences.Key.moveArchiveToTrash)
            defaults.set(saved.5, forKey: Preferences.Key.quitAfterQuickExtract)
            defaults.set(saved.6, forKey: Preferences.Key.archiveOpenAction)
            defaults.set(saved.7, forKey: Preferences.Key.folderConflictMode)
        }
        Preferences.overwriteMode = .ask

        // The Settings window is open on Extracting.
        let pane = ExtractionSettingsViewController()
        let window = Review2.host(pane)
        windows.append(window)
        pane.viewWillAppear()

        // Meanwhile a conflict prompt's "Always do this" is ticked with Replace.
        Preferences.overwriteMode = .overwrite

        // Back in Settings, any other control is clicked.
        let reveal = try XCTUnwrap(Review2.allSubviews(of: NSButton.self, in: pane.view)
            .first { $0.title == L("Reveal the result in Finder") })
        reveal.performClick(nil)

        XCTAssertEqual(Preferences.overwriteMode, .overwrite,
                       "ticking an unrelated box wrote the stale 'If a file exists' choice back")
    }

    // MARK: - E11: the name Save As ends up writing

    func testSaveAsKeepsANameWholeAndGivesItTheChosenExtension() throws {
        let zip = try XCTUnwrap(FormatRegistry.format(forKey: "zip"))
        let sevenZip = try XCTUnwrap(FormatRegistry.format(forKey: "7z"))
        // A dot in the name is not an extension.
        for typed in ["Backup 2024.10.05", "Project v1.5", "report.final", "Mr. Smith"] {
            XCTAssertEqual(FormatRegistry.saveName(typed: typed, format: zip), typed + ".zip")
        }
        // The right extension is left alone, another archive extension is replaced.
        XCTAssertEqual(FormatRegistry.saveName(typed: "Photos.zip", format: zip), "Photos.zip")
        XCTAssertEqual(FormatRegistry.saveName(typed: "Photos.zip", format: sevenZip), "Photos.7z")
        XCTAssertEqual(FormatRegistry.saveName(typed: "site.tar.gz", format: zip), "site.zip")
        XCTAssertEqual(FormatRegistry.saveName(typed: "Backup.7z.001", format: sevenZip), "Backup.7z")
        XCTAssertEqual(FormatRegistry.saveName(typed: "", format: zip), "Archive.zip")
    }
}
