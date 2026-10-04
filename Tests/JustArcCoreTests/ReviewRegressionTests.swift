import XCTest
@testable import JustArcCore

/// One test per defect found when the engines and models were reviewed.
final class ReviewRegressionTests: XCTestCase {
    private let engine = SevenZipEngine()
    private var root: URL!

    override func setUpWithError() throws {
        root = try FixtureBuilder.makeSourceTree()
    }

    override func tearDown() {
        FixtureBuilder.cleanup(root)
    }

    private func paths(in archive: URL) async throws -> Set<String> {
        Set(try await engine.list(archive: archive, password: nil, encodingCodePage: nil).entries.map(\.path))
    }

    private func run(_ tool: String, _ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardError = Pipe()
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) \(arguments)")
    }

    // MARK: - The "." entry

    /// `tar czf x.tgz .` stores "./", which named the destination folder itself:
    /// reported as a folder that already exists, and deleted by Replace.
    func testATarballOfTheCurrentFolderNeverPutsTheDestinationAtRisk() async throws {
        let archive = root.appendingPathComponent("here.tgz")
        try run("/usr/bin/tar", ["czf", archive.path, "-C", root.appendingPathComponent("payload").path, "."],
                in: root)

        let listing = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
        XCTAssertFalse(listing.entries.contains { $0.path.isEmpty || $0.path == "." },
                       "\(listing.entries.map(\.path))")
        XCTAssertTrue(listing.entries.contains { $0.path == "readme.txt" })

        let destination = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let precious = destination.appendingPathComponent("precious.txt")
        try "keep me\n".write(to: precious, atomically: true, encoding: .utf8)

        let roots = EntryTree(entries: listing.entries).root.children.map(\.path)
        let report = ExtractionConflicts.find(entries: listing.entries, roots: roots + ["."], in: destination)
        XCTAssertFalse(report.folders.contains("."), "the destination itself was reported as a conflict")

        // Even told outright to replace ".", the runner leaves the destination alone.
        let job = ExtractionJob(archive: archive, destination: destination, allEntries: listing.entries,
                                roots: roots, folderConflicts: ["."], folderResolution: .replace,
                                fileOverwrite: .overwrite)
        _ = try? await ExtractionRunner.run(job, engine: engine)
        XCTAssertEqual(try? String(contentsOf: precious, encoding: .utf8), "keep me\n",
                       "the destination folder was emptied")
        engine.release(archive: archive)
    }

    func testNormalisingDropsDotComponents() {
        XCTAssertEqual(ArchivePath.normalize("."), "")
        XCTAssertEqual(ArchivePath.normalize("./"), "")
        XCTAssertEqual(ArchivePath.normalize("./a/./b/"), "a/b")
        XCTAssertEqual(ArchivePath.normalize("a//b"), "a/b")
        XCTAssertEqual(ArchivePath.normalize("/a\\b"), "a/b")
        XCTAssertEqual(ArchivePath.normalize("a/../b"), "a/../b", ".. is for PathSafety to refuse, not to hide")
    }

    // MARK: - Names

    func testOrdinaryNamesThatLookedSuspiciousAreAccepted() {
        XCTAssertTrue(PathSafety.isSafe(entryPath: "~$Report.docx"), "an Office lock file")
        XCTAssertTrue(PathSafety.isSafe(entryPath: "A:B test"), "the Finder's A/B on disk")
        XCTAssertTrue(PathSafety.isSafe(entryPath: "docs/~backup"))
        XCTAssertFalse(PathSafety.isSafe(entryPath: "~/secrets"))
        XCTAssertFalse(PathSafety.isSafe(entryPath: "C:/Windows"))
        XCTAssertFalse(PathSafety.isSafe(entryPath: "C:"))
    }

    func testRenamingOntoAnExistingNameIsRefused() async throws {
        let (fixture, archive) = try await FixtureBuilder.makeArchive(named: "clash.zip")
        defer { FixtureBuilder.cleanup(fixture) }
        do {
            try await engine.rename(entry: ArchiveEntry(path: "payload/docs/notes.txt", isDirectory: false),
                                    to: "payload/docs/ünïcode.txt", in: archive, password: nil)
            XCTFail("two entries now share one path")
        } catch let error as ArchiveError {
            if case .ioFailure = error {} else { XCTFail("unexpected \(error)") }
        }
        let listing = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
        XCTAssertEqual(listing.entries.filter { $0.path == "payload/docs/ünïcode.txt" }.count, 1)
        XCTAssertTrue(listing.entries.contains { $0.path == "payload/docs/notes.txt" })
    }

    func testAddingTwoFilesOfOneNameStoresOne() async throws {
        let other = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try "second\n".write(to: other.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)

        let archive = root.appendingPathComponent("twins.zip")
        try await engine.create(archive: archive,
                                items: [root.appendingPathComponent("payload/readme.txt"),
                                        other.appendingPathComponent("readme.txt")],
                                options: CompressionOptions(formatKey: "zip"))
        let listing = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
        XCTAssertEqual(listing.entries.filter { $0.path == "readme.txt" }.count, 1)
    }

    func testAFileAddedOverAFolderReplacesIt() async throws {
        let (fixture, archive) = try await FixtureBuilder.makeArchive(named: "over.zip")
        defer { FixtureBuilder.cleanup(fixture) }
        let docs = fixture.appendingPathComponent("elsewhere/docs")
        try FileManager.default.createDirectory(at: docs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "now a file\n".write(to: docs, atomically: true, encoding: .utf8)

        try await engine.add(items: [docs], to: archive, into: "payload",
                             options: CompressionOptions(formatKey: "zip"), cancellation: nil, progress: nil)
        let found = try await paths(in: archive)
        XCTAssertTrue(found.contains("payload/docs"))
        XCTAssertFalse(found.contains { $0.hasPrefix("payload/docs/") }, "\(found.sorted())")

        // And the result extracts, which a file and a folder of one name would not.
        try await engine.extract(archive: archive, entries: nil, to: fixture.appendingPathComponent("out"),
                                 password: nil, overwrite: .overwrite, flattenPaths: false)
    }

    func testAddingIntoAPathThatIsAFileIsRefused() async throws {
        let (fixture, archive) = try await FixtureBuilder.makeArchive(named: "file-folder.zip")
        defer { FixtureBuilder.cleanup(fixture) }
        do {
            try await engine.add(items: [fixture.appendingPathComponent("payload/readme.txt")], to: archive,
                                 into: "payload/readme.txt", options: CompressionOptions(formatKey: "zip"),
                                 cancellation: nil, progress: nil)
            XCTFail("a file was used as a folder")
        } catch is ArchiveError {}
    }

    // MARK: - macOS companions

    func testDeletingAFileTakesItsHiddenCompanionsAlong() async throws {
        let shadow = root.appendingPathComponent("__MACOSX/payload")
        try FileManager.default.createDirectory(at: shadow, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: shadow.appendingPathComponent("._readme.txt"))
        try Data("x".utf8).write(to: root.appendingPathComponent("payload/docs/._notes.txt"))
        let archive = root.appendingPathComponent("finder.zip")
        try await engine.create(archive: archive,
                                items: [root.appendingPathComponent("payload"), root.appendingPathComponent("__MACOSX")],
                                options: CompressionOptions(formatKey: "zip", excludeMacMetadata: false))

        try await engine.delete(entries: [ArchiveEntry(path: "payload/readme.txt", isDirectory: false),
                                          ArchiveEntry(path: "payload/docs", isDirectory: true)],
                                from: archive, password: nil)

        // Read with 7zz, which hides nothing.
        let raw = try await FixtureBuilder.run(["l", "-slt", archive.path], in: root).standardOutput
        XCTAssertFalse(raw.contains("._readme.txt"), "the deleted file's companion is still in the archive")
        XCTAssertFalse(raw.contains("._notes.txt"))
    }

    func testMetadataIsMappedToTheItemItDescribes() {
        XCTAssertEqual(MacMetadata.itemDescribed(by: "__MACOSX/Docs/._a.txt"), "Docs/a.txt")
        XCTAssertEqual(MacMetadata.itemDescribed(by: "Docs/._a.txt"), "Docs/a.txt")
        XCTAssertEqual(MacMetadata.itemDescribed(by: "__MACOSX/Docs"), "Docs")
        XCTAssertNil(MacMetadata.itemDescribed(by: "Docs/a.txt"))
        XCTAssertNil(MacMetadata.itemDescribed(by: "__MACOSX"))
    }

    // MARK: - Sizes

    func testEnormousDeclaredSizesDoNotOverflow() {
        let listing = ArchiveListing(info: ArchiveInfo(), entries: [
            ArchiveEntry(path: "a", isDirectory: false, size: .max - 15, packedSize: .max - 15),
            ArchiveEntry(path: "b", isDirectory: false, size: .max - 15, packedSize: .max - 15),
        ])
        XCTAssertEqual(listing.totalSize, .max)
        XCTAssertEqual(listing.totalPacked, .max)
        XCTAssertEqual(EntryTree(entries: listing.entries).root.totalSize, .max)
        XCTAssertTrue(PathSafety.evaluate(listing: listing).isSuspicious)
        _ = Formatting.ratio(size: 1, packed: .max)
    }

    func testAbsurdVolumeSizesAreRejectedNotTrapped() {
        XCTAssertNil(VolumeSize.normalize("99999999999999999999"))
        XCTAssertThrowsError(try SevenZipEngine.volumeBytes("17179869184g"))
        XCTAssertEqual(try SevenZipEngine.volumeBytes("2g"), 2 << 30)
    }

    // MARK: - Saving

    func testSavingANewArchiveSplitIntoVolumesWorks() async throws {
        var bytes = [UInt8](repeating: 0, count: 300 * 1024)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        try Data(bytes).write(to: root.appendingPathComponent("payload/random.bin"))

        let session = ArchiveSession(archiveURL: nil)
        session.stage(items: [root.appendingPathComponent("payload")])
        let destination = root.appendingPathComponent("split.7z")
        try await session.save(to: destination,
                               options: CompressionOptions(formatKey: "7z", level: 0, volumeSize: "100k"))

        let first = URL(fileURLWithPath: destination.path + ".001")
        XCTAssertEqual(session.archiveURL, first, "a split archive is opened through its first volume")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path + ".003"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(session.visibleEntries.contains { $0.path == "payload/random.bin" })

        // A smaller save of the same name must not leave the old tail behind.
        try FileManager.default.removeItem(at: root.appendingPathComponent("payload/random.bin"))
        let smaller = ArchiveSession(archiveURL: nil)
        smaller.stage(items: [root.appendingPathComponent("payload")])
        try await smaller.save(to: destination,
                               options: CompressionOptions(formatKey: "7z", level: 0, volumeSize: "100k"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path + ".003"),
                       "a volume from the earlier, larger save was left in place")
        XCTAssertTrue(smaller.visibleEntries.contains { $0.path == "payload/readme.txt" })
    }

    func testVolumeNamesAreRecognised() {
        XCTAssertTrue(ArchiveSession.isVolume("a.7z.001", of: "a.7z"))
        XCTAssertTrue(ArchiveSession.isVolume("a.part12.rar", of: "a.rar"))
        XCTAssertFalse(ArchiveSession.isVolume("a.7z.bak", of: "a.7z"))
        XCTAssertFalse(ArchiveSession.isVolume("ab.7z.001", of: "a.7z"))
        XCTAssertFalse(ArchiveSession.isVolume("a.partial.rar", of: "a.rar"))
    }

    func testSaveAsOverTheOpenArchiveAppliesTheOptions() async throws {
        let (fixture, archive) = try await FixtureBuilder.makeArchive(named: "same.zip")
        defer { FixtureBuilder.cleanup(fixture) }
        let session = ArchiveSession(archiveURL: archive)
        try await session.load()
        XCTAssertFalse(session.listing.containsEncryptedEntries)

        try await session.save(to: archive, options: CompressionOptions(formatKey: "zip", password: "sesame"),
                               rebuild: true)
        XCTAssertTrue(session.listing.containsEncryptedEntries, "the password chosen in Save As was dropped")
        XCTAssertEqual(session.password, "sesame")
    }

    func testSavingWithEncryptedNamesReopensWithTheNewPassword() async throws {
        let session = ArchiveSession(archiveURL: nil)
        session.stage(items: [root.appendingPathComponent("payload")])
        let destination = root.appendingPathComponent("hidden.7z")
        try await session.save(to: destination,
                               options: CompressionOptions(formatKey: "7z", password: "sesame", encryptFileNames: true))
        XCTAssertEqual(session.archiveURL, destination)
        XCTAssertTrue(session.visibleEntries.contains { $0.path == "payload/readme.txt" })
        XCTAssertFalse(session.hasUnsavedChanges)
    }

    func testConvertingKeepsEmptyFoldersButNotDeletedFiles() async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("payload/empty"),
                                                withIntermediateDirectories: true)
        let archive = root.appendingPathComponent("source.zip")
        try await engine.create(archive: archive, items: [root.appendingPathComponent("payload")],
                                options: CompressionOptions(formatKey: "zip"))
        let session = ArchiveSession(archiveURL: archive)
        try await session.load()
        // Empties "docs" without deleting the folder itself.
        session.markForDeletion(["payload/docs/notes.txt", "payload/docs/ünïcode.txt"])

        let destination = root.appendingPathComponent("converted.7z")
        try await session.save(to: destination, options: CompressionOptions(formatKey: "7z", level: 1))
        let listing = try await engine.list(archive: destination, password: nil, encodingCodePage: nil)
        let found = Set(listing.entries.map(\.path))
        XCTAssertTrue(found.contains("payload/empty"), "\(found.sorted())")
        XCTAssertTrue(found.contains("payload/docs"), "\(found.sorted())")
        XCTAssertFalse(found.contains("payload/docs/notes.txt"), "a deleted file came back")
        XCTAssertTrue(found.contains("payload/readme.txt"))
    }

    func testADiskImageKeepsTheFolderAndIsNamedAfterItself() async throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("My Project \(UUID().uuidString.prefix(4)).dmg")
        let dmg = DMGEngine()
        defer {
            dmg.release(archive: destination)
            try? FileManager.default.removeItem(at: destination)
        }
        let session = ArchiveSession(archiveURL: nil)
        session.stage(items: [root.appendingPathComponent("payload")])
        try await session.save(to: destination, options: CompressionOptions(formatKey: "dmg", level: 1))

        XCTAssertTrue(session.visibleEntries.contains { $0.path == "payload/readme.txt" },
                      "the folder was dissolved into the image's root: \(session.visibleEntries.map(\.path).sorted())")
        let info = Process()
        info.executableURL = EngineLocator.hdiutil
        info.arguments = ["imageinfo", destination.path]
        let pipe = Pipe()
        info.standardOutput = pipe
        info.standardError = Pipe()
        try info.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        info.waitUntilExit()
        XCTAssertFalse(text.contains("justarc-out"), "the volume is named after a temporary file")
    }

    // MARK: - Disk image extraction

    func testExtractingADiskImageMergesIntoFoldersInsteadOfDeletingThem() async throws {
        let image = FileManager.default.temporaryDirectory
            .appendingPathComponent("justarc-merge-\(UUID().uuidString).dmg")
        let dmg = DMGEngine()
        defer {
            dmg.release(archive: image)
            try? FileManager.default.removeItem(at: image)
        }
        try await dmg.create(archive: image, items: [root.appendingPathComponent("payload")],
                             options: CompressionOptions(formatKey: "dmg", level: 1))

        let destination = root.appendingPathComponent("out")
        let mine = destination.appendingPathComponent("payload/docs/mine.txt")
        try FileManager.default.createDirectory(at: mine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "unrelated\n".write(to: mine, atomically: true, encoding: .utf8)
        try "old\n".write(to: destination.appendingPathComponent("payload/readme.txt"), atomically: true, encoding: .utf8)

        try await dmg.extract(archive: image, entries: nil, to: destination, password: nil,
                              overwrite: .overwrite, flattenPaths: false, cancellation: nil, progress: nil)
        XCTAssertEqual(try? String(contentsOf: mine, encoding: .utf8), "unrelated\n",
                       "a file that was already in the folder was deleted with it")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("payload/readme.txt"), encoding: .utf8),
                       "hello world\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("payload 2").path))

        try await dmg.extract(archive: image, entries: nil, to: destination, password: nil,
                              overwrite: .renameNew, flattenPaths: false, cancellation: nil, progress: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("payload/readme 2.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("payload 2").path),
                       "Keep Both for files made a second copy of the whole folder")
    }

    // MARK: - Processes

    func testCancellingBeforeAToolStartsDoesNotCrash() async throws {
        let token = CancellationToken()
        token.cancel()
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"),
                                                 arguments: ["5"], cancellation: token)
        XCTAssertNotEqual(result.exitCode, 0, "the tool ran to completion although cancelled")
    }
}
