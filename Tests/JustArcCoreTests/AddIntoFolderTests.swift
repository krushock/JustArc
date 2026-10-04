import XCTest
@testable import JustArcCore

/// Adding files to a folder inside an archive rather than to its root.
final class AddIntoFolderTests: XCTestCase {
    private let engine = SevenZipEngine()

    private func makeExtra(in root: URL, named name: String = "extra.txt",
                           text: String = "added later\n") throws -> URL {
        let extra = root.appendingPathComponent(name)
        try text.write(to: extra, atomically: true, encoding: .utf8)
        return extra
    }

    private func paths(in archive: URL) async throws -> Set<String> {
        Set(try await engine.list(archive: archive, password: nil, encodingCodePage: nil).entries.map(\.path))
    }

    // MARK: - Engine

    func testFilesLandInTheFolderInEveryEditableFormat() async throws {
        for name in ["add.zip", "add.7z", "add.tar"] {
            let (root, archive) = try await FixtureBuilder.makeArchive(named: name)
            defer { FixtureBuilder.cleanup(root) }
            let extra = try makeExtra(in: root)

            try await engine.add(items: [extra], to: archive, into: "payload/docs",
                                 options: CompressionOptions(formatKey: FormatRegistry.format(for: archive)!.key),
                                 cancellation: nil, progress: nil)

            let found = try await paths(in: archive)
            XCTAssertTrue(found.contains("payload/docs/extra.txt"), "\(name): \(found.sorted())")
            XCTAssertFalse(found.contains("extra.txt"), "\(name): the file also went to the root")
            XCTAssertTrue(found.contains("payload/readme.txt"), "\(name): existing entries were lost")
        }
    }

    func testFoldersKeepTheirShapeUnderTheTarget() async throws {
        let (root, archive) = try await FixtureBuilder.makeArchive(named: "nest.zip")
        defer { FixtureBuilder.cleanup(root) }
        let folder = root.appendingPathComponent("assets/icons")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "png".write(to: folder.appendingPathComponent("a.png"), atomically: true, encoding: .utf8)

        try await engine.add(items: [root.appendingPathComponent("assets")], to: archive, into: "payload",
                             options: CompressionOptions(formatKey: "zip"), cancellation: nil, progress: nil)
        let found = try await paths(in: archive)
        XCTAssertTrue(found.contains("payload/assets/icons/a.png"), "\(found.sorted())")
    }

    func testAddingAgainReplacesTheFileInThatFolderOnly() async throws {
        let (root, archive) = try await FixtureBuilder.makeArchive(named: "replace.zip")
        defer { FixtureBuilder.cleanup(root) }
        // Same name as a file that already sits one level up.
        let readme = try makeExtra(in: root, named: "readme.txt", text: "the new one\n")

        for _ in 0..<2 {
            try await engine.add(items: [readme], to: archive, into: "payload/docs",
                                 options: CompressionOptions(formatKey: "zip"), cancellation: nil, progress: nil)
        }
        let listing = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
        XCTAssertEqual(listing.entries.filter { $0.path == "payload/docs/readme.txt" }.count, 1)

        let out = root.appendingPathComponent("out")
        try await engine.extract(archive: archive, entries: nil, to: out, password: nil,
                                 overwrite: .overwrite, flattenPaths: false)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("payload/docs/readme.txt"), encoding: .utf8),
                       "the new one\n")
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("payload/readme.txt"), encoding: .utf8),
                       "hello world\n", "the file of the same name in the parent folder was replaced")
    }

    func testACompressedTarTakesFilesInAFolderToo() async throws {
        let root = try FixtureBuilder.makeSourceTree()
        defer { FixtureBuilder.cleanup(root) }
        let archive = root.appendingPathComponent("made.tar.gz")
        try await engine.create(archive: archive, items: [root.appendingPathComponent("payload")],
                                options: CompressionOptions(formatKey: "tgz"))
        let extra = try makeExtra(in: root)

        try await engine.add(items: [extra], to: archive, into: "payload/docs",
                             options: CompressionOptions(formatKey: "tgz"), cancellation: nil, progress: nil)
        let found = try await paths(in: archive)
        XCTAssertTrue(found.contains("payload/docs/extra.txt"), "\(found.sorted())")
        engine.release(archive: archive)
    }

    func testAFolderThatDoesNotExistYetIsCreatedByTheFile() async throws {
        let root = try FixtureBuilder.makeSourceTree()
        defer { FixtureBuilder.cleanup(root) }
        let archive = root.appendingPathComponent("fresh.zip")
        let extra = try makeExtra(in: root)

        try await engine.add(items: [extra], to: archive, into: "new/place",
                             options: CompressionOptions(formatKey: "zip"), cancellation: nil, progress: nil)
        let found = try await paths(in: archive)
        XCTAssertEqual(found, ["new/place/extra.txt"])
    }

    func testAFolderThatClimbsOutOfTheArchiveIsRefused() async throws {
        let (root, archive) = try await FixtureBuilder.makeArchive(named: "unsafe.zip")
        defer { FixtureBuilder.cleanup(root) }
        let extra = try makeExtra(in: root)
        do {
            try await engine.add(items: [extra], to: archive, into: "payload/../..",
                                 options: CompressionOptions(formatKey: "zip"), cancellation: nil, progress: nil)
            XCTFail("a folder with .. in it should be refused")
        } catch let error as ArchiveError {
            if case .unsafeEntry = error {} else { XCTFail("unexpected \(error)") }
        }
    }

    func testRarIsToldThePathInsideTheArchive() {
        let arguments = RarEngine.addArguments(archive: URL(fileURLWithPath: "/tmp/a.rar"), names: ["extra.txt"],
                                               options: CompressionOptions(formatKey: "rar"),
                                               folder: "payload/docs")
        XCTAssertTrue(arguments.contains("-appayload/docs"), "\(arguments)")
        XCTAssertFalse(RarEngine.addArguments(archive: URL(fileURLWithPath: "/tmp/a.rar"), names: ["x"],
                                              options: CompressionOptions(formatKey: "rar"))
            .contains { $0.hasPrefix("-ap") })
    }

    /// Runs only where RARLAB's tool is installed, since JustArc cannot ship it.
    func testRarPutsFilesInTheFolder() async throws {
        try XCTSkipUnless(EngineLocator.externalRAR != nil, "RARLAB's rar is not installed")
        let root = try FixtureBuilder.makeSourceTree()
        defer { FixtureBuilder.cleanup(root) }
        let rar = RarEngine()
        let archive = root.appendingPathComponent("made.rar")
        try await rar.create(archive: archive, items: [root.appendingPathComponent("payload")],
                             options: CompressionOptions(formatKey: "rar"))
        let extra = try makeExtra(in: root)

        try await rar.add(items: [extra], to: archive, into: "payload/docs",
                          options: CompressionOptions(formatKey: "rar"), cancellation: nil, progress: nil)
        let found = try await paths(in: archive)
        XCTAssertTrue(found.contains("payload/docs/extra.txt"), "\(found.sorted())")
        XCTAssertFalse(found.contains("extra.txt"))
        XCTAssertTrue(found.contains("payload/readme.txt"))
    }

    // MARK: - Session

    func testStagingIntoAFolderShowsTheFileThere() throws {
        let root = try FixtureBuilder.makeSourceTree()
        defer { FixtureBuilder.cleanup(root) }
        let extra = try makeExtra(in: root)

        let session = ArchiveSession(archiveURL: nil)
        session.stage(items: [root.appendingPathComponent("payload")])
        session.stage(items: [extra], into: "payload/docs")

        XCTAssertNotNil(session.tree.node(at: "payload/docs/extra.txt"))
        XCTAssertNil(session.tree.node(at: "extra.txt"))
        XCTAssertEqual(session.stagedSource(for: "payload/docs/extra.txt"), extra.standardizedFileURL)
        XCTAssertEqual(session.stagedFolder(for: extra), "payload/docs")
    }

    func testRemovingAFolderTakesWhatWasStagedIntoItAlong() throws {
        let root = try FixtureBuilder.makeSourceTree()
        defer { FixtureBuilder.cleanup(root) }
        let extra = try makeExtra(in: root)
        let payload = root.appendingPathComponent("payload")

        let session = ArchiveSession(archiveURL: nil)
        session.stage(items: [payload])
        session.stage(items: [extra], into: "payload/docs")
        session.unstage(root: payload)

        XCTAssertTrue(session.visibleEntries.isEmpty, "\(session.visibleEntries.map(\.path))")
        XCTAssertFalse(session.hasUnsavedChanges)
    }

    func testRemovingOnlyTheNestedFileLeavesTheFolder() throws {
        let root = try FixtureBuilder.makeSourceTree()
        defer { FixtureBuilder.cleanup(root) }
        let extra = try makeExtra(in: root)

        let session = ArchiveSession(archiveURL: nil)
        session.stage(items: [root.appendingPathComponent("payload")])
        session.stage(items: [extra], into: "payload/docs")
        session.unstage(root: extra)

        XCTAssertNil(session.tree.node(at: "payload/docs/extra.txt"))
        XCTAssertNotNil(session.tree.node(at: "payload/docs/notes.txt"))
    }

    func testSavingANewArchivePutsNestedFilesWhereTheyWereStaged() async throws {
        for name in ["new.zip", "new.7z", "new.tar.gz"] {
            let root = try FixtureBuilder.makeSourceTree()
            defer { FixtureBuilder.cleanup(root) }
            let extra = try makeExtra(in: root)
            let destination = root.appendingPathComponent(name)

            let session = ArchiveSession(archiveURL: nil)
            session.stage(items: [root.appendingPathComponent("payload")])
            session.stage(items: [extra], into: "payload/docs")
            try await session.save(to: destination,
                                   options: CompressionOptions(formatKey: FormatRegistry.format(for: destination)!.key))

            let found = try await paths(in: destination)
            XCTAssertTrue(found.contains("payload/docs/extra.txt"), "\(name): \(found.sorted())")
            XCTAssertTrue(found.contains("payload/docs/notes.txt"), "\(name): \(found.sorted())")
            XCTAssertFalse(found.contains("extra.txt"), name)
            XCTAssertFalse(session.hasUnsavedChanges)
            engine.release(archive: destination)
        }
    }

    func testSavingInPlacePutsNestedFilesWhereTheyWereStaged() async throws {
        let (root, archive) = try await FixtureBuilder.makeArchive(named: "inplace.zip")
        defer { FixtureBuilder.cleanup(root) }
        let extra = try makeExtra(in: root)
        let top = try makeExtra(in: root, named: "top.txt")

        let session = ArchiveSession(archiveURL: archive)
        try await session.load()
        session.stage(items: [top])
        session.stage(items: [extra], into: "payload/docs")
        try await session.save(to: archive, options: CompressionOptions(formatKey: "zip"))

        let found = Set(session.visibleEntries.map(\.path))
        XCTAssertTrue(found.contains("payload/docs/extra.txt"), "\(found.sorted())")
        XCTAssertTrue(found.contains("top.txt"))
        XCTAssertTrue(found.contains("payload/readme.txt"))
    }

    func testConvertingAnArchiveKeepsNestedAdditions() async throws {
        let (root, archive) = try await FixtureBuilder.makeArchive(named: "source.zip")
        defer { FixtureBuilder.cleanup(root) }
        let extra = try makeExtra(in: root)

        let session = ArchiveSession(archiveURL: archive)
        try await session.load()
        session.stage(items: [extra], into: "payload/docs")
        let destination = root.appendingPathComponent("converted.7z")
        try await session.save(to: destination, options: CompressionOptions(formatKey: "7z", level: 1))

        let found = try await paths(in: destination)
        XCTAssertTrue(found.contains("payload/docs/extra.txt"), "\(found.sorted())")
        XCTAssertTrue(found.contains("payload/docs/notes.txt"))
    }

    // MARK: - Deleting from a new archive

    private func stagedSession(_ root: URL) -> ArchiveSession {
        let session = ArchiveSession(archiveURL: nil)
        session.stage(items: [root.appendingPathComponent("payload")])
        return session
    }

    func testDeletingOneFileInsideAStagedFolderHidesJustThatFile() throws {
        let root = try FixtureBuilder.makeSourceTree()
        defer { FixtureBuilder.cleanup(root) }
        let session = stagedSession(root)

        session.markForDeletion(["payload/docs/notes.txt"])
        XCTAssertNil(session.tree.node(at: "payload/docs/notes.txt"))
        XCTAssertNotNil(session.tree.node(at: "payload/docs/ünïcode.txt"))
        XCTAssertNotNil(session.tree.node(at: "payload/readme.txt"))
        XCTAssertTrue(session.hasUnsavedChanges)
    }

    func testDeletingAFolderInsideAStagedFolderHidesEverythingInIt() throws {
        let root = try FixtureBuilder.makeSourceTree()
        defer { FixtureBuilder.cleanup(root) }
        let extra = try makeExtra(in: root)
        let session = stagedSession(root)
        session.stage(items: [extra], into: "payload/docs")

        session.markForDeletion(["payload/docs"])
        XCTAssertNil(session.tree.node(at: "payload/docs"))
        XCTAssertFalse(session.visibleEntries.contains { $0.path.hasPrefix("payload/docs") },
                       "\(session.visibleEntries.map(\.path))")
        XCTAssertFalse(session.stagedRoots.contains(extra.standardizedFileURL),
                       "the file staged into the deleted folder is still queued")
        XCTAssertNotNil(session.tree.node(at: "payload/readme.txt"))
    }

    func testDeletedFilesAreLeftOutOfTheSavedArchive() async throws {
        for name in ["trim.zip", "trim.7z", "trim.tar.gz"] {
            let root = try FixtureBuilder.makeSourceTree()
            defer { FixtureBuilder.cleanup(root) }
            let session = stagedSession(root)
            session.markForDeletion(["payload/docs/notes.txt"])

            let destination = root.appendingPathComponent(name)
            try await session.save(to: destination,
                                   options: CompressionOptions(formatKey: FormatRegistry.format(for: destination)!.key))
            let found = try await paths(in: destination)
            XCTAssertFalse(found.contains("payload/docs/notes.txt"), "\(name): \(found.sorted())")
            XCTAssertTrue(found.contains("payload/docs/ünïcode.txt"), "\(name): \(found.sorted())")
            XCTAssertTrue(found.contains("payload/readme.txt"), "\(name): \(found.sorted())")
            XCTAssertEqual(Set(session.visibleEntries.map(\.path)), found,
                           "\(name): what the window shows after saving is not what was written")
            engine.release(archive: destination)
        }
    }

    func testADeletedFolderIsLeftOutOfTheSavedArchive() async throws {
        let root = try FixtureBuilder.makeSourceTree()
        defer { FixtureBuilder.cleanup(root) }
        let session = stagedSession(root)
        session.markForDeletion(["payload/docs"])

        let destination = root.appendingPathComponent("nodocs.zip")
        try await session.save(to: destination, options: CompressionOptions(formatKey: "zip"))
        let found = try await paths(in: destination)
        XCTAssertFalse(found.contains { $0.hasPrefix("payload/docs") }, "\(found.sorted())")
        XCTAssertTrue(found.contains("payload/readme.txt"))
    }

    func testAFolderEmptiedByDeletionsIsStillWritten() async throws {
        let root = try FixtureBuilder.makeSourceTree()
        defer { FixtureBuilder.cleanup(root) }
        let session = stagedSession(root)
        session.markForDeletion(["payload/docs/notes.txt", "payload/docs/ünïcode.txt"])
        XCTAssertNotNil(session.tree.node(at: "payload/docs"), "the folder itself was not deleted")

        let destination = root.appendingPathComponent("emptied.zip")
        try await session.save(to: destination, options: CompressionOptions(formatKey: "zip"))
        let listing = try await engine.list(archive: destination, password: nil, encodingCodePage: nil)
        XCTAssertTrue(listing.entries.contains { $0.path == "payload/docs" && $0.isDirectory },
                      "\(listing.entries.map(\.path).sorted())")
        XCTAssertFalse(listing.entries.contains { $0.path.hasPrefix("payload/docs/") })
    }

    func testEverythingDeletedLeavesNothingToSave() throws {
        let root = try FixtureBuilder.makeSourceTree()
        defer { FixtureBuilder.cleanup(root) }
        let session = stagedSession(root)
        session.markForDeletion(["payload/docs/notes.txt"])
        session.markForDeletion(["payload"])

        XCTAssertTrue(session.visibleEntries.isEmpty)
        XCTAssertFalse(session.hasUnsavedChanges, "an empty new archive still claims unsaved changes")
    }

    func testAFileStagedAfterADeletionInTheSameFolderIsKept() async throws {
        let root = try FixtureBuilder.makeSourceTree()
        defer { FixtureBuilder.cleanup(root) }
        let session = stagedSession(root)
        session.markForDeletion(["payload/docs/notes.txt"])
        // A different file, with the name of the one just deleted.
        let replacement = root.appendingPathComponent("elsewhere/notes.txt")
        try FileManager.default.createDirectory(at: replacement.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "replacement\n".write(to: replacement, atomically: true, encoding: .utf8)
        session.stage(items: [replacement], into: "payload/docs")
        XCTAssertNotNil(session.tree.node(at: "payload/docs/notes.txt"))

        let destination = root.appendingPathComponent("swap.zip")
        try await session.save(to: destination, options: CompressionOptions(formatKey: "zip"))
        let out = root.appendingPathComponent("out")
        try await engine.extract(archive: destination, entries: nil, to: out, password: nil,
                                 overwrite: .overwrite, flattenPaths: false)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("payload/docs/notes.txt"), encoding: .utf8),
                       "replacement\n")
    }

    func testDeletingAFolderInAnOpenArchiveDropsItsContentsOnConversion() async throws {
        let (root, archive) = try await FixtureBuilder.makeArchive(named: "source.zip")
        defer { FixtureBuilder.cleanup(root) }
        let session = ArchiveSession(archiveURL: archive)
        try await session.load()
        session.markForDeletion(["payload/docs"])
        XCTAssertFalse(session.visibleEntries.contains { $0.path.hasPrefix("payload/docs") })

        let destination = root.appendingPathComponent("converted.7z")
        try await session.save(to: destination, options: CompressionOptions(formatKey: "7z", level: 1))
        let found = try await paths(in: destination)
        XCTAssertFalse(found.contains { $0.hasPrefix("payload/docs") }, "\(found.sorted())")
        XCTAssertTrue(found.contains("payload/readme.txt"))
    }

    /// A disk image is built in one go and cannot be added to, so this takes a
    /// different route from every other format.
    func testADiskImageGetsNestedFilesToo() async throws {
        let root = try FixtureBuilder.makeSourceTree()
        let extra = try makeExtra(in: root)
        let other = try makeExtra(in: root, named: "top.txt")
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("justarc-nested-\(UUID().uuidString).dmg")
        let dmg = DMGEngine()
        defer {
            dmg.release(archive: destination)
            FixtureBuilder.cleanup(root)
            try? FileManager.default.removeItem(at: destination)
        }

        let session = ArchiveSession(archiveURL: nil)
        session.stage(items: [root.appendingPathComponent("payload"), other])
        session.stage(items: [extra], into: "payload/docs")
        try await session.save(to: destination, options: CompressionOptions(formatKey: "dmg", level: 1))

        let found = Set(try await dmg.list(archive: destination, password: nil, encodingCodePage: nil)
            .entries.map(\.path))
        XCTAssertTrue(found.contains("payload/docs/extra.txt"), "\(found.sorted())")
        XCTAssertTrue(found.contains("payload/docs/notes.txt"), "\(found.sorted())")
        XCTAssertTrue(found.contains("top.txt"), "\(found.sorted())")
    }
}
