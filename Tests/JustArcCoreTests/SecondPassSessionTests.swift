import XCTest
@testable import JustArcCore

/// Second-pass review: ArchiveSession staging, deletion and saving.
/// Each test asserts the behaviour a user would expect; a failure is a finding.
final class SecondPassSessionTests: XCTestCase {
    private let engine = SevenZipEngine()
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("justarc-review2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ text: String, _ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func paths(in archive: URL) async throws -> [String] {
        try await engine.list(archive: archive, password: nil, encodingCodePage: nil).entries.map(\.path).sorted()
    }

    private func extractAll(_ archive: URL) async throws -> URL {
        let out = root.appendingPathComponent("out-\(UUID().uuidString)")
        try await engine.extract(archive: archive, entries: nil, to: out, password: nil,
                                 overwrite: .overwrite, flattenPaths: false)
        return out
    }

    // MARK: - S1: two staged roots of one name, then delete the row

    func testDeletingARowThatTwoStagedFilesShareRemovesBoth() async throws {
        let first = try write("first\n", "a/notes.txt")
        let second = try write("second\n", "b/notes.txt")
        let keep = try write("keep\n", "keep.txt")
        let session = ArchiveSession(archiveURL: nil)
        session.stage(items: [first, keep])
        session.stage(items: [second])
        XCTAssertEqual(session.visibleEntries.filter { $0.path == "notes.txt" }.count, 1)

        session.markForDeletion(["notes.txt"])
        XCTAssertFalse(session.visibleEntries.contains { $0.path == "notes.txt" }, "row still shown")
        print("S1 stagedRoots after delete:", session.stagedRoots.map(\.path))

        let destination = root.appendingPathComponent("s1.zip")
        try await session.save(to: destination, options: CompressionOptions(formatKey: "zip"))
        let found = try await paths(in: destination)
        XCTAssertFalse(found.contains("notes.txt"),
                       "the deleted row was written anyway: \(found)")
    }

    func testDeletingAFolderRowThatTwoStagedFoldersShareRemovesBoth() async throws {
        try write("x\n", "a/dir/x.txt")
        try write("y\n", "b/dir/y.txt")
        let keep = try write("keep\n", "keep.txt")
        let session = ArchiveSession(archiveURL: nil)
        session.stage(items: [root.appendingPathComponent("a/dir"), keep])
        session.stage(items: [root.appendingPathComponent("b/dir")])
        print("S1b visible before:", session.visibleEntries.map(\.path).sorted())
        session.markForDeletion(["dir"])
        print("S1b visible after:", session.visibleEntries.map(\.path).sorted())
        XCTAssertFalse(session.visibleEntries.contains { $0.path.hasPrefix("dir") })

        let destination = root.appendingPathComponent("s1b.zip")
        try await session.save(to: destination, options: CompressionOptions(formatKey: "zip"))
        let found = try await paths(in: destination)
        XCTAssertFalse(found.contains { $0.hasPrefix("dir") }, "deleted folder written anyway: \(found)")
    }

    /// A file dropped into a staged folder over one of the folder's own: the row
    /// stands for both, and deleting it must not bring the folder's copy back.
    func testDeletingARowSharedByAStagedFolderAndAFileDroppedIntoItRemovesBoth() async throws {
        try write("the folder's own\n", "one/docs/x.txt")
        try write("stays\n", "one/docs/stays.txt")
        let loose = try write("dropped in\n", "two/x.txt")
        let session = ArchiveSession(archiveURL: nil)
        session.stage(items: [root.appendingPathComponent("one/docs")])
        session.stage(items: [loose], into: "docs")
        XCTAssertEqual(session.stagedSource(for: "docs/x.txt")?.path, loose.standardizedFileURL.path)

        session.markForDeletion(["docs/x.txt"])
        XCTAssertFalse(session.visibleEntries.contains { $0.path == "docs/x.txt" },
                       "the folder's own copy reappeared in place of the one deleted")

        let destination = root.appendingPathComponent("shared.zip")
        try await session.save(to: destination, options: CompressionOptions(formatKey: "zip"))
        let found = try await paths(in: destination)
        XCTAssertEqual(found.filter { $0 != "docs" }, ["docs/stays.txt"])
    }

    // MARK: - S2: what the list shows for a path is what gets saved

    func testTheVersionShownIsTheVersionSaved() async throws {
        // B goes into "docs" first; then a folder "docs" holding its own x.txt is staged
        // at the root. The list shows the later one (the folder's).
        try write("from the folder\n", "one/docs/x.txt")
        let loose = try write("the loose file\n", "two/x.txt")
        try write("anchor\n", "zero/docs/anchor.txt")

        let session = ArchiveSession(archiveURL: nil)
        session.stage(items: [root.appendingPathComponent("zero/docs")])
        session.stage(items: [loose], into: "docs")
        session.stage(items: [root.appendingPathComponent("one/docs")])
        let shown = session.stagedSource(for: "docs/x.txt")
        let shownText = try String(contentsOf: XCTUnwrap(shown), encoding: .utf8)
        print("S2 list shows:", shown?.path ?? "nil")

        let destination = root.appendingPathComponent("s2.zip")
        try await session.save(to: destination, options: CompressionOptions(formatKey: "zip"))
        let out = try await extractAll(destination)
        let saved = try String(contentsOf: out.appendingPathComponent("docs/x.txt"), encoding: .utf8)
        XCTAssertEqual(saved, shownText, "the list showed one file and the archive got the other")
        let found = try await paths(in: destination)
        print("S2 saved:", found)
        XCTAssertTrue(found.contains("docs/anchor.txt"), "\(found)")
    }

    // MARK: - S4: a failed in-place save must not have half-applied itself

    func testAFailedInPlaceSaveLeavesTheArchiveAsItWas() async throws {
        let (fixture, archive) = try await FixtureBuilder.makeArchive(named: "half.zip")
        defer { FixtureBuilder.cleanup(fixture) }
        let extra = try write("extra\n", "extra.txt")

        let session = ArchiveSession(archiveURL: archive)
        try await session.load()
        session.markForDeletion(["payload/readme.txt"])
        session.stage(items: [extra])
        // The staged file disappears before the user saves.
        try FileManager.default.removeItem(at: extra)

        do {
            try await session.save(to: archive, options: CompressionOptions(formatKey: "zip"))
            XCTFail("the save should have failed: the staged file is gone")
        } catch {
            print("S4 save failed as expected:", error.localizedDescription)
        }
        let found = try await paths(in: archive)
        XCTAssertTrue(found.contains("payload/readme.txt"),
                      "the save failed, yet the deletion had already been applied: \(found)")
        print("S4 session still says unsaved:", session.hasUnsavedChanges,
              "visible has readme:", session.visibleEntries.contains { $0.path == "payload/readme.txt" })
    }

    // MARK: - S5: stale-volume cleanup must only remove volumes

    func testSavingSplitVolumesLeavesUnrelatedFilesAlone() async throws {
        let folder = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // wget names a second download "name.1"; a dated backup is "name.2024".
        let wget = folder.appendingPathComponent("backup.7z.1")
        let dated = folder.appendingPathComponent("backup.7z.2024")
        try "a different download\n".write(to: wget, atomically: true, encoding: .utf8)
        try "last year's\n".write(to: dated, atomically: true, encoding: .utf8)

        var bytes = [UInt8](repeating: 0, count: 300_000)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        let blob = root.appendingPathComponent("blob.bin")
        try Data(bytes).write(to: blob)

        let session = ArchiveSession(archiveURL: nil)
        session.stage(items: [blob])
        try await session.save(to: folder.appendingPathComponent("backup.7z"),
                               options: CompressionOptions(formatKey: "7z", level: 0, volumeSize: "100k"))
        let after = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        print("S5 folder after:", after)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wget.path), "backup.7z.1 was deleted: \(after)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dated.path), "backup.7z.2024 was deleted: \(after)")
    }

    /// Volumes left by an earlier, larger save of the same name would be read as
    /// part of the new set, so the ones that continue its numbering are cleared away.
    func testSavingFewerVolumesClearsAwayTheOnesThatWouldContinueTheSet() async throws {
        let folder = root.appendingPathComponent("again")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var cleared: [String] = []
        let realTrash = ExtractionRunner.trash
        ExtractionRunner.trash = { url in
            cleared.append(url.lastPathComponent)
            try FileManager.default.removeItem(at: url)
        }
        defer { ExtractionRunner.trash = realTrash }

        func save(bytes: Int) async throws -> [String] {
            var data = Data(count: bytes)
            data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, bytes) }
            let blob = root.appendingPathComponent("blob-\(bytes).bin")
            try data.write(to: blob)
            let session = ArchiveSession(archiveURL: nil)
            session.stage(items: [blob])
            try await session.save(to: folder.appendingPathComponent("set.7z"),
                                   options: CompressionOptions(formatKey: "7z", level: 0, volumeSize: "100k"))
            return try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        }
        let large = try await save(bytes: 450_000)
        XCTAssertGreaterThanOrEqual(large.count, 5, "\(large)")
        // A file that only looks a little like a volume, and is not in sequence.
        try "mine\n".write(to: folder.appendingPathComponent("set.7z.900"), atomically: true, encoding: .utf8)

        let small = try await save(bytes: 150_000)
        XCTAssertEqual(small, ["set.7z.001", "set.7z.002", "set.7z.900"], "cleared: \(cleared)")
        XCTAssertFalse(cleared.contains("set.7z.900"))
        let listing = try await engine.list(archive: folder.appendingPathComponent("set.7z.001"),
                                            password: nil, encodingCodePage: nil)
        XCTAssertEqual(listing.entries.map(\.path), ["blob-150000.bin"])
    }

    // MARK: - S8: a staged folder that vanished must fail the save, not become empty

    func testAStagedFolderThatVanishedIsNotSavedAsAnEmptyFolder() async throws {
        try write("a\n", "gone/a.txt")
        try write("b\n", "gone/b.txt")
        let keep = try write("keep\n", "keep.txt")
        let session = ArchiveSession(archiveURL: nil)
        session.stage(items: [root.appendingPathComponent("gone"), keep])
        session.markForDeletion(["gone/a.txt"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("gone"))

        let destination = root.appendingPathComponent("s8.zip")
        do {
            try await session.save(to: destination, options: CompressionOptions(formatKey: "zip"))
            let found = try await paths(in: destination)
            XCTFail("saved without complaint although gone/b.txt could not be read: \(found)")
        } catch {
            print("S8 failed properly:", error.localizedDescription)
        }
    }

    // MARK: - S9: a symbolic link to a folder

    func testAStagedLinkToAFolderIsShownAsWhatWillBeStored() async throws {
        try write("inside\n", "real/inside.txt")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("real"))
        let session = ArchiveSession(archiveURL: nil)
        session.stage(items: [link])
        let shown = session.visibleEntries.map(\.path).sorted()
        let destination = root.appendingPathComponent("s9.zip")
        try await session.save(to: destination, options: CompressionOptions(formatKey: "zip"))
        let found = try await paths(in: destination)
        print("S9 shown:", shown, "saved:", found)
        XCTAssertEqual(shown, found, "the list and the archive disagree about a linked folder")
    }

    // MARK: - S10: unstaging after the folder changed on disk

    func testUnstagingAFolderThatChangedOnDiskLeavesNoGhosts() throws {
        try write("a\n", "folder/a.txt")
        let b = try write("b\n", "folder/b.txt")
        let session = ArchiveSession(archiveURL: nil)
        session.stage(items: [root.appendingPathComponent("folder")])
        try FileManager.default.removeItem(at: b)
        session.markForDeletion(["folder"])
        let shown = session.visibleEntries.map(\.path).sorted()
        print("S10 shown:", shown, "unsaved:", session.hasUnsavedChanges, "roots:", session.stagedRoots.count)
        XCTAssertTrue(shown.isEmpty, "rows remain for a folder that was taken out: \(shown)")
    }

    func testUnstagingAFolderThatWasRemovedFromDiskLeavesNoGhosts() throws {
        try write("a\n", "folder/a.txt")
        try write("b\n", "folder/sub/b.txt")
        let session = ArchiveSession(archiveURL: nil)
        session.stage(items: [root.appendingPathComponent("folder")])
        try FileManager.default.removeItem(at: root.appendingPathComponent("folder"))
        session.markForDeletion(["folder"])
        let shown = session.visibleEntries.map(\.path).sorted()
        print("S10b shown:", shown, "unsaved:", session.hasUnsavedChanges, "roots:", session.stagedRoots.count)
        XCTAssertTrue(shown.isEmpty, "rows remain for a folder that was taken out: \(shown)")
    }

    // MARK: - S11: a name with a backslash

    func testDeletingAStagedFileWhoseNameHasABackslash() async throws {
        let odd = try write("odd\n", "we\\ird.txt")
        let keep = try write("keep\n", "keep.txt")
        let session = ArchiveSession(archiveURL: nil)
        session.stage(items: [odd, keep])
        let shown = session.visibleEntries.map(\.path).sorted()
        print("S11 shown:", shown)
        // Delete whatever row stands for it.
        session.markForDeletion(shown.filter { $0 != "keep.txt" })
        print("S11 shown after delete:", session.visibleEntries.map(\.path).sorted(),
              "roots:", session.stagedRoots.map(\.lastPathComponent))
        let destination = root.appendingPathComponent("s11.zip")
        try await session.save(to: destination, options: CompressionOptions(formatKey: "zip"))
        let found = try await paths(in: destination)
        XCTAssertEqual(found, ["keep.txt"], "the deleted file was saved anyway")
    }

    // MARK: - S25: the same item into two folders

    func testTheSameFileCanGoIntoTwoFolders() throws {
        let file = try write("x\n", "x.txt")
        try write("d\n", "dir/d.txt")
        let session = ArchiveSession(archiveURL: nil)
        session.stage(items: [root.appendingPathComponent("dir")])
        session.stage(items: [file])
        let added = session.stage(items: [file], into: "dir")
        let shown = session.visibleEntries.map(\.path).sorted()
        print("S25 added:", added.map(\.path), "shown:", shown)
        XCTAssertTrue(shown.contains("dir/x.txt"), "the second drop was ignored without a word: \(shown)")
    }

    // MARK: - S20: converting keeps links

    func testConvertingKeepsALinkThatPointsOutside() async throws {
        try write("t\n", "tree/t.txt")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("tree/apps").path,
                                                   withDestinationPath: "/Applications")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("tree/sibling").path,
                                                   withDestinationPath: "t.txt")
        let archive = root.appendingPathComponent("links.zip")
        try await engine.create(archive: archive, items: [root.appendingPathComponent("tree")],
                                options: CompressionOptions(formatKey: "zip"))
        let before = try await paths(in: archive)
        let session = ArchiveSession(archiveURL: archive)
        try await session.load()
        let destination = root.appendingPathComponent("links.7z")
        try await session.save(to: destination, options: CompressionOptions(formatKey: "7z", level: 1))
        let after = try await paths(in: destination)
        print("S20 before:", before, "after:", after)
        XCTAssertEqual(before, after, "converting dropped entries without saying so")
    }

    // MARK: - Leaks and cancelling

    /// Everything JustArc might leave in the temporary folder, by name.
    private func leftovers() -> Set<String> {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory
        var found = Set<String>()
        for name in (try? fm.contentsOfDirectory(atPath: temp.path)) ?? []
        where (name.hasPrefix("justarc-") || name.hasPrefix(".justarc")) && !name.hasPrefix("justarc-review2-")
            && !name.hasPrefix("justarc-tests-") {
            found.insert(name)
        }
        let items = temp.appendingPathComponent("TemporaryItems")
        for name in (try? fm.contentsOfDirectory(atPath: items.path)) ?? [] {
            found.insert("TemporaryItems/" + name)
        }
        return found
    }

    private func hidden(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    func testAFailedOrCancelledSaveLeavesNothingBehindAndTheArchiveIntact() async throws {
        let (fixture, archive) = try await FixtureBuilder.makeArchive(named: "intact.zip")
        defer { FixtureBuilder.cleanup(fixture) }
        var blob = Data(count: 30_000_000)
        blob.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, 30_000_000) }
        let big = root.appendingPathComponent("big.bin")
        try blob.write(to: big)
        let originalPaths = try await paths(in: archive)
        let originalData = try Data(contentsOf: archive)
        let before = leftovers()
        var report: [String] = []

        // 1. A destination folder that cannot be written to.
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        do {
            let session = ArchiveSession(archiveURL: archive)
            try await session.load()
            session.stage(items: [big])
            try await session.save(to: locked.appendingPathComponent("out.7z"), options: CompressionOptions(formatKey: "7z", level: 1))
            report.append("read-only folder: saved?!")
        } catch { report.append("read-only folder: \(error.localizedDescription)") }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        report.append("  left in that folder: \(hidden(in: locked))  temp: \(leftovers().subtracting(before).sorted())")

        // 2. Cancelled while converting, at several points.
        for trigger in [0, 3, 12, 40] {
            let token = CancellationToken()
            let counter = Counter()
            let session = ArchiveSession(archiveURL: archive)
            try await session.load()
            session.stage(items: [big])
            let destination = root.appendingPathComponent("cancel-\(trigger).7z")
            if trigger == 0 { token.cancel() }
            do {
                try await session.save(to: destination, options: CompressionOptions(formatKey: "7z", level: 1),
                                       cancellation: token, progress: { _ in if counter.next() == trigger { token.cancel() } })
                report.append("convert, cancel at \(trigger): finished; exists \(FileManager.default.fileExists(atPath: destination.path))")
            } catch { report.append("convert, cancel at \(trigger): \(error.localizedDescription); destination exists \(FileManager.default.fileExists(atPath: destination.path))") }
            report.append("  temp: \(leftovers().subtracting(before).sorted())")
        }

        // 3. Cancelled while saving in place.
        for trigger in [0, 2, 8, 30] {
            let token = CancellationToken()
            let counter = Counter()
            let session = ArchiveSession(archiveURL: archive)
            try await session.load()
            session.stage(items: [big])
            if trigger == 0 { token.cancel() }
            do {
                try await session.save(to: archive, options: CompressionOptions(formatKey: "zip", level: 1),
                                       cancellation: token, progress: { _ in if counter.next() == trigger { token.cancel() } })
                report.append("in place, cancel at \(trigger): finished")
                // Put it back for the next round.
                try originalData.write(to: archive)
                SevenZipEngine().release(archive: archive)
            } catch {
                let now = (try? await paths(in: archive)) ?? ["<unreadable>"]
                report.append("in place, cancel at \(trigger): \(error.localizedDescription); archive unchanged \(now == originalPaths)")
            }
            report.append("  beside the archive: \(hidden(in: fixture))  temp: \(leftovers().subtracting(before).sorted())")
        }
        print("LEAK\n" + report.joined(separator: "\n"))
        XCTAssertTrue(leftovers().subtracting(before).isEmpty, "\(leftovers().subtracting(before).sorted())")
    }

    // MARK: - Names that differ only in case

    func testConvertingKeepsBothOfTwoNamesThatDifferOnlyInCase() async throws {
        let script = """
        import zipfile
        with zipfile.ZipFile('case.zip', 'w') as z:
            z.writestr('Readme.txt', 'one')
            z.writestr('README.TXT', 'two')
            z.writestr('dir/a.txt', 'three')
            z.writestr('DIR/b.txt', 'four')
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script]
        process.currentDirectoryURL = root
        try process.run()
        process.waitUntilExit()
        let archive = root.appendingPathComponent("case.zip")
        let before = try await paths(in: archive)
        let session = ArchiveSession(archiveURL: archive)
        try await session.load()
        let destination = root.appendingPathComponent("case.7z")
        try await session.save(to: destination, options: CompressionOptions(formatKey: "7z", level: 1))
        let after = try await paths(in: destination)
        print("CASE before:", before, "after:", after)
        XCTAssertEqual(after.filter { !$0.lowercased().hasPrefix("dir") || $0.contains("/") }.count,
                       before.filter { !$0.lowercased().hasPrefix("dir") || $0.contains("/") }.count,
                       "files were lost in conversion: \(before) became \(after)")
    }

    // MARK: - Save As over the archive itself

    func testSavingOverTheArchiveItselfKeepsEverythingThatWasInIt() async throws {
        let script = """
        import zipfile
        with zipfile.ZipFile('self.zip', 'w') as z:
            z.writestr('Readme.txt', 'one')
            z.writestr('README.TXT', 'two')
            z.writestr('photo.jpg', 'jpeg')
            z.writestr('__MACOSX/._photo.jpg', 'resource fork and Finder info')
            link = zipfile.ZipInfo('apps'); link.create_system = 3; link.external_attr = (0o120777 << 16)
            z.writestr(link, '/Applications')
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script]
        process.currentDirectoryURL = root
        try process.run()
        process.waitUntilExit()
        let archive = root.appendingPathComponent("self.zip")
        // Folders that were only implied by the paths under them are written out
        // as entries of their own, so it is the files that are compared.
        let before = try BridgeArchive.open(archive, password: nil, codePage: nil).entries()
            .filter { !$0.isDirectory }.map(\.path).sorted()
        let session = ArchiveSession(archiveURL: archive)
        try await session.load()
        // "Save As…" onto the same file, to give it a password.
        try await session.save(to: archive, options: CompressionOptions(formatKey: "zip", password: "secret"), rebuild: true)
        let after = try BridgeArchive.open(archive, password: "secret", codePage: nil).entries()
            .filter { !$0.isDirectory }.map(\.path).sorted()
        print("SELF before:", before, "after:", after)
        XCTAssertEqual(after, before, "re-saving the archive over itself dropped entries")
    }

    // MARK: - Legacy name encodings

    private func makeLegacyZip() throws -> URL {
        let script = """
        import zipfile
        class Legacy(zipfile.ZipInfo):
            def _encodeFilenameFlags(self):
                return self.filename.encode('cp866'), self.flag_bits & ~0x800
        with zipfile.ZipFile('ru.zip', 'w') as z:
            for raw, data in [('afe0a8a2a5e2', 'hello'), ('afa0afaaa02fe4a0a9ab', 'file')]:
                info = Legacy(bytes.fromhex(raw).decode('cp866') + '.txt')
                info.create_system = 0
                z.writestr(info, data)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script]
        process.currentDirectoryURL = root
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return root.appendingPathComponent("ru.zip")
    }

    func testChoosingCyrillicDOSReadsNamesWrittenInCp866() async throws {
        let archive = try makeLegacyZip()
        // The window, with Cyrillic (DOS 866) chosen.
        let listing = try await engine.list(archive: archive, password: nil, encodingCodePage: 866)
        print("ENC window lists:", listing.entries.map(\.path).sorted())
        XCTAssertTrue(listing.entries.contains { $0.path == "привет.txt" })
        // Quick Extract, or a second window, reads the same file its own way.
        _ = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
        // The window extracts what is selected.
        let out = root.appendingPathComponent("enc-out")
        try await engine.extract(archive: archive, entries: listing.entries, to: out, password: nil,
                                 overwrite: .overwrite, flattenPaths: false)
        let produced = (try? FileManager.default.subpathsOfDirectory(atPath: out.path))?.sorted() ?? []
        print("ENC extracted:", produced)
        XCTAssertTrue(produced.contains("привет.txt"), "the extraction reported success and wrote \(produced)")
    }

    func testAChosenEncodingSurvivesEditingAndSavingAs() async throws {
        let archive = try makeLegacyZip()
        let extra = try write("extra\n", "новый.txt")
        let session = ArchiveSession(archiveURL: archive)
        session.encodingCodePage = 866
        try await session.load()
        session.stage(items: [extra])
        try await session.save(to: archive, options: CompressionOptions(formatKey: "zip"))
        let inPlace = session.visibleEntries.map(\.path).sorted()
        print("ENC after saving in place:", inPlace)
        XCTAssertTrue(inPlace.contains("привет.txt") && inPlace.contains("новый.txt") && inPlace.contains("папка/файл.txt"), "\(inPlace)")

        let destination = root.appendingPathComponent("ru-converted.zip")
        try await session.save(to: destination, options: CompressionOptions(formatKey: "zip"), rebuild: true)
        let converted = session.visibleEntries.map(\.path).sorted()
        print("ENC after Save As:", converted)
        XCTAssertTrue(converted.contains("привет.txt") && converted.contains("новый.txt") && converted.contains("папка/файл.txt"), "\(converted)")
    }

    // MARK: - S3: scaling

    func testMarkingManyRowsForDeletionScales() throws {
        func time(_ count: Int) -> Double {
            let entries = (0..<count).map { ArchiveEntry(path: "big/file-\($0).txt", isDirectory: false, size: 1) }
            let folder = URL(fileURLWithPath: "/nonexistent/big")
            let scanned = ArchiveSession.Scanned(url: folder,
                                                 entries: [ArchiveEntry(path: "big", isDirectory: true)] + entries)
            let session = ArchiveSession(archiveURL: nil)
            session.stage(scanned: [scanned])
            let start = Date()
            session.markForDeletion(entries.map(\.path))
            return Date().timeIntervalSince(start)
        }
        let small = time(2_000), medium = time(4_000), large = time(8_000)
        print(String(format: "S3 markForDeletion: 2k %.2fs, 4k %.2fs, 8k %.2fs", small, medium, large))
        XCTAssertLessThan(large, small * 8, "doubling the rows more than doubles the time each step: quadratic")
    }

    func testStagingManyLooseFilesScales() throws {
        func time(_ count: Int) -> (stage: Double, delete: Double) {
            let scanned = (0..<count).map {
                ArchiveSession.Scanned(url: URL(fileURLWithPath: "/nonexistent/loose/file-\($0).txt"),
                                       entries: [ArchiveEntry(path: "file-\($0).txt", isDirectory: false, size: 1)])
            }
            let session = ArchiveSession(archiveURL: nil)
            var start = Date()
            session.stage(scanned: scanned)
            let stage = Date().timeIntervalSince(start)
            start = Date()
            session.markForDeletion(scanned.map { $0.url.lastPathComponent })
            return (stage, Date().timeIntervalSince(start))
        }
        let small = time(1_000), large = time(4_000)
        print(String(format: "S3b loose files: stage 1k %.2fs / 4k %.2fs; select-all delete 1k %.2fs / 4k %.2fs",
                     small.stage, large.stage, small.delete, large.delete))
        XCTAssertLessThan(large.delete, max(small.delete, 0.01) * 8)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}
