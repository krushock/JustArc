import AppKit
import QuickLookUI
import UniformTypeIdentifiers
import XCTest
@testable import JustArc
@testable import JustArcCore

/// Second-pass review experiments that run through modal dialogs, answered by
/// `ModalDriver`. Nothing here ticks "Remember", so the keychain is never written.
@MainActor
final class Review2ModalTests: XCTestCase {
    private var root: URL!
    private var windows: [NSWindow] = []
    private var driver: ModalDriver!

    override func setUp() async throws {
        _ = NSApplication.shared
        ModalWatchdog.arm()
        root = try Review2.makeRoot()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("payload"),
                                                withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt"] {
            try "contents of \(name)\n".write(to: root.appendingPathComponent("payload/\(name)"),
                                              atomically: true, encoding: .utf8)
        }
        driver = ModalDriver()
        driver.start()
    }

    override func tearDown() async throws {
        driver.stop()
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

    private func payload(_ names: [String]) -> [URL] {
        names.map { root.appendingPathComponent("payload/\($0)") }
    }

    private func table(of browser: ArchiveBrowserViewController) throws -> NSOutlineView {
        try XCTUnwrap(Review2.allSubviews(of: NSOutlineView.self, in: browser.view).first)
    }

    private func select(_ paths: [String], in browser: ArchiveBrowserViewController) throws {
        let table = try table(of: browser)
        let rows = (0..<table.numberOfRows).filter { row in
            guard let node = table.item(atRow: row) as? EntryTree.Node else { return false }
            return paths.contains(node.path)
        }
        XCTAssertEqual(rows.count, paths.count, "rows not found")
        table.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
    }

    // MARK: - E4: cancelling the retry prompt

    func testCancellingTheRetryPromptLeavesTheWrongPasswordInTheSession() async throws {
        let archive = root.appendingPathComponent("locked.zip")
        try await SevenZipEngine().create(archive: archive, items: payload(["a.txt"]),
                                          options: CompressionOptions(formatKey: "zip", password: "right"))
        let browser = try await open(archive)
        XCTAssertNil(browser.session.password)

        var prompts: [String] = []
        driver.onModal = { driver, window, seen in
            prompts.append(seen.texts.first ?? "?")
            if seen.texts.contains(L("Enter the archive password")) {
                driver.type("tpyo", in: window)
                driver.press(L("Continue"), in: window)
            } else {
                // "That password did not work." The user gives up to go and look it up.
                driver.press(L("Cancel"), in: window)
            }
        }
        let node = try XCTUnwrap(browser.session.tree.node(at: "a.txt"))
        let result = await browser.materialize(node: node)
        print("E4 prompts:", prompts, "result:", result?.lastPathComponent ?? "nil",
              "session.password:", browser.session.password ?? "nil")
        XCTAssertNil(result)
        XCTAssertEqual(prompts.count, 2)
        XCTAssertNil(browser.session.password, "the password that was just refused is still the session's password")

        // What comes next: a file dropped in. Nothing is written to an encrypted
        // archive under a password that has not opened it, so the prompt is back,
        // and this time the right one is given.
        driver.onModal = { driver, window, seen in
            prompts.append(seen.texts.first ?? "?")
            driver.type("right", in: window)
            driver.press(L("Continue"), in: window)
        }
        let extra = root.appendingPathComponent("tax-return.txt")
        try "private\n".write(to: extra, atomically: true, encoding: .utf8)
        browser.add(items: [extra])
        try await Review2.waitFor("add") { browser.session.tree.node(at: "tax-return.txt") != nil }
        let engine = SevenZipEngine()
        let onDisk = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
        let added = try XCTUnwrap(onDisk.entries.first { $0.path == "tax-return.txt" })
        var opensWithRight = true
        do {
            try await engine.extract(archive: archive, entries: [added], to: root.appendingPathComponent("check"),
                                     password: "right", overwrite: .overwrite, flattenPaths: false,
                                     cancellation: nil, progress: nil)
        } catch { opensWithRight = false }
        print("E4 added file encrypted:", added.isEncrypted, "opens with the archive's password:", opensWithRight)
        XCTAssertTrue(opensWithRight, "the file added afterwards is locked with the mistyped password")
    }

    // MARK: - E6: Quick Look on several encrypted files, prompt cancelled

    func testCancellingThePasswordForQuickLookAsksAgainForEverySelectedFile() async throws {
        let archive = root.appendingPathComponent("locked.zip")
        let names = ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt"]
        try await SevenZipEngine().create(archive: archive, items: payload(names),
                                          options: CompressionOptions(formatKey: "zip", password: "right"))
        let browser = try await open(archive)
        try select(names, in: browser)

        var prompts = 0
        var settled = Date()
        driver.onModal = { driver, window, _ in
            prompts += 1
            settled = Date()
            driver.press(L("Cancel"), in: window)
        }
        let panel = try XCTUnwrap(QLPreviewPanel.shared())
        browser.loadPreviewItems(showing: panel, thenOpen: false)
        try await Review2.waitFor("first prompt") { prompts > 0 }
        try await Review2.waitFor("prompts to stop", timeout: 20) { Date().timeIntervalSince(settled) > 1.0 }
        print("E6 password prompts after one press of Space with \(names.count) files selected:", prompts)
        XCTAssertEqual(prompts, 1, "Cancel was not taken for an answer")
    }

    // MARK: - E12: Set Password, then Cancel

    func testSetPasswordThenCancelLeavesTheWrongPassword() async throws {
        let archive = root.appendingPathComponent("hidden.7z")
        try await SevenZipEngine().create(archive: archive, items: payload(["a.txt"]),
                                          options: CompressionOptions(formatKey: "7z", password: "right",
                                                                      encryptFileNames: true))
        let browser = try await open(archive, password: "right")
        XCTAssertEqual(browser.session.tree.node(at: "a.txt")?.name, "a.txt")

        var prompts: [String] = []
        driver.onModal = { driver, window, seen in
            prompts.append(seen.texts.first ?? "?")
            if prompts.count == 1 {
                driver.type("tpyo", in: window)
                driver.press(L("Continue"), in: window)
            } else {
                driver.press(L("Cancel"), in: window)
            }
        }
        let generation = browser.listingGeneration
        Review2.asEvent { browser.setPassword(nil) }
        try await Review2.waitFor("both prompts") { prompts.count >= 2 }
        try await Task.sleep(nanoseconds: 300_000_000)
        print("E12 prompts:", prompts, "session.password:", browser.session.password ?? "nil",
              "reloaded:", browser.listingGeneration != generation)
        XCTAssertEqual(browser.session.password, "right",
                       "cancelling put back the password that had just failed, not the one that works")
    }

    // MARK: - E8: a second rewrite started while a confirmation is on screen

    func testDeleteConfirmedWhileAnUpdateIsRunningStartsASecondRewrite() async throws {
        // Enough bulk that a rewrite takes a moment.
        let big = root.appendingPathComponent("payload/big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        var chunk = Data(count: 8 << 20)
        for round in 0..<50 {
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
        let archive = root.appendingPathComponent("work.zip")
        try await SevenZipEngine().create(archive: archive, items: payload(["a.txt", "b.txt"]) + [big],
                                          options: CompressionOptions(formatKey: "zip", level: 1))
        let browser = try await open(archive)

        // a.txt is opened out of the archive and edited in another app.
        let node = try XCTUnwrap(browser.session.tree.node(at: "a.txt"))
        let opened = await browser.materialize(node: node, forEditing: true)
        let local = try XCTUnwrap(opened)
        browser.editedFiles.track(localURL: local, entryPath: "a.txt")
        try "edited in another app, quite a bit longer than before\n".write(to: local, atomically: true, encoding: .utf8)

        // The user selects b.txt and presses Delete: a confirmation comes up.
        try select(["b.txt"], in: browser)
        var log: [String] = []
        var deleteSeen = 0
        driver.onModal = { driver, window, seen in
            let title = seen.texts.first ?? "?"
            if title.hasPrefix("Delete ") {
                deleteSeen += 1
                if deleteSeen == 1 {
                    log.append("delete confirmation up; busy=\(browser.isBusy)")
                    // They switch to the editor and back while it is up: the app
                    // becomes active, which is when edited files are noticed. With a
                    // question already on screen, that one waits its turn.
                    RunLoop.main.perform(inModes: [.common]) {
                        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
                    }
                    driver.revisit()
                } else {
                    log.append("back at the delete confirmation; busy=\(browser.isBusy)")
                    driver.press(L("Delete"), in: window)
                }
            } else if seen.buttons.contains(L("Update Archive")) {
                log.append("edited-outside question; busy=\(browser.isBusy)")
                driver.press(L("Update Archive"), in: window)
            } else {
                log.append("other alert: \(seen.texts)")
                driver.press(seen.buttons.first ?? "", in: window)
            }
        }
        var overlapSeen = false
        let watcher = Timer(timeInterval: 0.005, repeats: true) { _ in
            MainActor.assumeIsolated {
                let sheets = browser.view.window?.sheets.count ?? 0
                if sheets >= 2 { overlapSeen = true }
            }
        }
        RunLoop.main.add(watcher, forMode: .common)
        defer { watcher.invalidate() }

        Review2.asEvent { browser.deleteSelected(nil) }
        try await Review2.waitFor("the delete to be confirmed") { deleteSeen >= 2 }
        try await Review2.waitFor("the delete", timeout: 60) { !browser.isBusy && !browser.isLoadingArchive }
        XCTAssertFalse(log.contains { $0.hasPrefix("edited-outside question") },
                       "the edited-file question came up underneath the delete confirmation")
        // The next time the app comes forward, the edit is noticed and offered.
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        try await Review2.waitFor("the question about the edit") { log.contains { $0.hasPrefix("edited-outside question") } }
        try await Task.sleep(nanoseconds: 300_000_000)
        try await Review2.waitFor("the update", timeout: 60) { !browser.isBusy && !browser.isLoadingArchive }
        for line in log { print("E8", line) }
        print("E8 two progress sheets on the window at once:", overlapSeen)

        let engine = SevenZipEngine()
        let onDisk = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
        let out = root.appendingPathComponent("verify")
        try await engine.extract(archive: archive, entries: onDisk.entries.filter { $0.path == "a.txt" }, to: out,
                                 password: nil, overwrite: .overwrite, flattenPaths: false,
                                 cancellation: nil, progress: nil)
        let aNow = try String(contentsOf: out.appendingPathComponent("a.txt"), encoding: .utf8)
        let bStillThere = onDisk.entries.contains { $0.path == "b.txt" }
        print("E8 on disk afterwards: a.txt updated =", aNow.hasPrefix("edited"), " b.txt still present =", bStillThere)
        XCTAssertFalse(overlapSeen, "two rewrites of one archive ran at the same time")
        XCTAssertTrue(aNow.hasPrefix("edited"), "the update was lost")
        XCTAssertFalse(bStillThere, "the delete was lost")
    }

    // MARK: - E13: an update that fails partway

    func testAnUpdateThatFailsPartwayLeavesTheWindowShowingTheOldArchive() async throws {
        let archive = root.appendingPathComponent("work.zip")
        try await SevenZipEngine().create(archive: archive, items: payload(["a.txt", "b.txt"]),
                                          options: CompressionOptions(formatKey: "zip"))
        let browser = try await open(archive)
        var locals: [String: URL] = [:]
        for name in ["a.txt", "b.txt"] {
            let node = try XCTUnwrap(browser.session.tree.node(at: name))
            // Looked at first, so a viewing copy exists.
            _ = await browser.materialize(node: node, quiet: true)
            let opened = await browser.materialize(node: node, forEditing: true)
            let local = try XCTUnwrap(opened)
            browser.editedFiles.track(localURL: local, entryPath: name)
            try "edited \(name), longer than it was before\n".write(to: local, atomically: true, encoding: .utf8)
            locals[name] = local
        }
        var log: [String] = []
        driver.onModal = { driver, window, seen in
            log.append(seen.texts.first ?? "?")
            if seen.buttons.contains(L("Update Archive")) {
                // b.txt's copy goes away before it can be written back.
                try? FileManager.default.removeItem(at: locals["b.txt"]!)
                driver.press(L("Update Archive"), in: window)
            } else {
                driver.press(seen.buttons.first ?? "", in: window)
            }
        }
        let generation = browser.listingGeneration
        Review2.asEvent {
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        }
        try await Review2.waitFor("the question and the failure") { log.count >= 2 }
        try await Review2.waitFor("idle") { !browser.isBusy }
        try await Task.sleep(nanoseconds: 500_000_000)
        for line in log { print("E13 alert:", line) }

        let engine = SevenZipEngine()
        let out = root.appendingPathComponent("verify")
        let onDisk = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
        try await engine.extract(archive: archive, entries: onDisk.entries.filter { $0.path == "a.txt" }, to: out,
                                 password: nil, overwrite: .overwrite, flattenPaths: false,
                                 cancellation: nil, progress: nil)
        let inArchive = try String(contentsOf: out.appendingPathComponent("a.txt"), encoding: .utf8)
        let node = try XCTUnwrap(browser.session.tree.node(at: "a.txt"))
        let shown = await browser.materialize(node: node, quiet: true)
        let shownText = try String(contentsOf: try XCTUnwrap(shown), encoding: .utf8)
        print("E13 a.txt in the archive:", inArchive.trimmingCharacters(in: .newlines),
              "| a.txt as Quick Look shows it:", shownText.trimmingCharacters(in: .newlines),
              "| reloaded:", browser.listingGeneration != generation,
              "| size listed:", node.entry?.size ?? 0, "size on disk:", onDisk.entries.first { $0.path == "a.txt" }?.size ?? 0)
        XCTAssertEqual(shownText, inArchive, "the window still shows a.txt as it was before the update that did go in")
    }

    // MARK: - E10: a new archive, once saved, is still treated as never loaded

    func testAFailedReloadAfterSavingClosesTheWindow() async throws {
        // performSave is reached here through Save on a session with staged files.
        // Save As on an untitled window ends in the same function with the same flag.
        let archive = root.appendingPathComponent("new.zip")
        try await SevenZipEngine().create(archive: archive, items: payload(["a.txt"]),
                                          options: CompressionOptions(formatKey: "zip"))
        let session = ArchiveSession(archiveURL: archive)
        let browser = ArchiveBrowserViewController(session: session)
        windows.append(Review2.host(browser))
        try await session.load()
        session.stage(items: payload(["b.txt"]))
        browser.reloadFromSession()
        XCTAssertTrue(session.hasUnsavedChanges)
        var loadFailed = false
        browser.onLoadFailed = { loadFailed = true }
        var alerts: [String] = []
        driver.onModal = { driver, window, seen in
            alerts.append(seen.texts.joined(separator: " / "))
            driver.press(seen.buttons.first ?? "", in: window)
        }

        browser.saveArchive(nil)
        try await Review2.waitFor("save") { !session.hasUnsavedChanges && !browser.isBusy }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNotNil(session.tree.node(at: "b.txt"))
        print("E10 after a successful save: hasLoadedOnce =", browser.hasLoadedOnce)

        // The file is moved away in the Finder and the user picks View ▸ Reload.
        try FileManager.default.moveItem(at: archive, to: root.appendingPathComponent("moved.zip"))
        browser.reloadArchive(nil)
        try await Review2.waitFor("the failure to be reported") { !alerts.isEmpty }
        try await Task.sleep(nanoseconds: 300_000_000)
        print("E10 alerts:", alerts, "onLoadFailed called (window is closed or replaced):", loadFailed)
        XCTAssertFalse(loadFailed, "a failed reload of a saved archive was treated as a failed first open")
    }
}
