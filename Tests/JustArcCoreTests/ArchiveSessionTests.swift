import XCTest
@testable import JustArcCore

final class ArchiveSessionTests: XCTestCase {
    private let engine = SevenZipEngine()

    func testStagingAFolderKeepsItsNameAtTheRoot() throws {
        let root = try FixtureBuilder.makeSourceTree()
        defer { FixtureBuilder.cleanup(root) }

        let session = ArchiveSession(archiveURL: nil)
        session.stage(items: [root.appendingPathComponent("payload")])

        let paths = Set(session.visibleEntries.map(\.path))
        XCTAssertTrue(paths.contains("payload"))
        XCTAssertTrue(paths.contains("payload/readme.txt"))
        XCTAssertTrue(paths.contains("payload/docs/notes.txt"))
        XCTAssertTrue(session.hasUnsavedChanges)
        XCTAssertTrue(session.isUntitled)
    }

    func testStagedEntriesResolveBackToTheirFileOnDisk() throws {
        let root = try FixtureBuilder.makeSourceTree()
        defer { FixtureBuilder.cleanup(root) }

        let session = ArchiveSession(archiveURL: nil)
        session.stage(items: [root.appendingPathComponent("payload")])

        let source = try XCTUnwrap(session.stagedSource(for: "payload/readme.txt"))
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "hello world\n")
    }

    func testUnstagingRemovesTheWholeSubtree() throws {
        let root = try FixtureBuilder.makeSourceTree()
        defer { FixtureBuilder.cleanup(root) }

        let payload = root.appendingPathComponent("payload")
        let session = ArchiveSession(archiveURL: nil)
        session.stage(items: [payload])
        session.unstage(root: payload)

        XCTAssertTrue(session.visibleEntries.isEmpty)
        XCTAssertFalse(session.hasUnsavedChanges)
    }

    func testSavingAnUntitledSessionWritesAReadableArchive() async throws {
        let root = try FixtureBuilder.makeSourceTree()
        defer { FixtureBuilder.cleanup(root) }

        let session = ArchiveSession(archiveURL: nil)
        session.stage(items: [root.appendingPathComponent("payload")])

        let destination = root.appendingPathComponent("New.zip")
        try await session.save(to: destination, options: CompressionOptions(formatKey: "zip", level: 1))

        XCTAssertEqual(session.archiveURL, destination)
        XCTAssertFalse(session.hasUnsavedChanges)
        let paths = Set(session.visibleEntries.map(\.path))
        XCTAssertTrue(paths.contains("payload/readme.txt"))

        // Reading it back through a fresh session proves the file itself is valid.
        let reopened = ArchiveSession(archiveURL: destination)
        try await reopened.load()
        XCTAssertTrue(reopened.visibleEntries.contains { $0.path == "payload/docs/notes.txt" })
    }

    func testSavingOverTheOpenZipAddsStagedFilesInPlace() async throws {
        let (root, archive) = try await FixtureBuilder.makeArchive(named: "inplace.zip")
        defer { FixtureBuilder.cleanup(root) }

        let extra = root.appendingPathComponent("extra.txt")
        try "added later\n".write(to: extra, atomically: true, encoding: .utf8)

        let session = ArchiveSession(archiveURL: archive)
        try await session.load()
        session.stage(items: [extra])
        try await session.save(to: archive, options: CompressionOptions(formatKey: "zip", level: 1))

        let paths = Set(session.visibleEntries.map(\.path))
        XCTAssertTrue(paths.contains("extra.txt"), "staged file was not added")
        XCTAssertTrue(paths.contains("payload/readme.txt"), "existing entries were lost")
    }

    func testSaveAsADifferentFormatRebuildsTheContents() async throws {
        let (root, archive) = try await FixtureBuilder.makeArchive(named: "source.zip")
        defer { FixtureBuilder.cleanup(root) }

        let session = ArchiveSession(archiveURL: archive)
        try await session.load()

        let destination = root.appendingPathComponent("converted.7z")
        try await session.save(to: destination, options: CompressionOptions(formatKey: "7z", level: 1))

        XCTAssertEqual(session.archiveURL, destination)
        let listing = try await engine.list(archive: destination, password: nil, encodingCodePage: nil)
        XCTAssertEqual(listing.info.formatName.lowercased(), "7z")
        XCTAssertTrue(listing.entries.contains { $0.path == "payload/docs/notes.txt" })
    }

    func testPendingDeletionsAreHiddenAndDroppedOnRebuild() async throws {
        let (root, archive) = try await FixtureBuilder.makeArchive(named: "prune.zip")
        defer { FixtureBuilder.cleanup(root) }

        let session = ArchiveSession(archiveURL: archive)
        try await session.load()
        session.markForDeletion(["payload/readme.txt"])
        XCTAssertFalse(session.visibleEntries.contains { $0.path == "payload/readme.txt" })

        let destination = root.appendingPathComponent("pruned.7z")
        try await session.save(to: destination, options: CompressionOptions(formatKey: "7z", level: 1))

        let listing = try await engine.list(archive: destination, password: nil, encodingCodePage: nil)
        XCTAssertFalse(listing.entries.contains { $0.path == "payload/readme.txt" })
        XCTAssertTrue(listing.entries.contains { $0.path == "payload/docs/notes.txt" })
    }

    func testReadOnlyFormatsAreReportedAsSuch() {
        let iso = ArchiveSession(archiveURL: URL(fileURLWithPath: "/tmp/disc.iso"))
        XCTAssertTrue(iso.isReadOnly)
        let zip = ArchiveSession(archiveURL: URL(fileURLWithPath: "/tmp/a.zip"))
        XCTAssertFalse(zip.isReadOnly)
    }

    func testSavingWithNothingStagedFails() async throws {
        let session = ArchiveSession(archiveURL: nil)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString).zip")
        do {
            try await session.save(to: destination, options: CompressionOptions(formatKey: "zip"))
            XCTFail("saving an empty session should fail")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }
}

final class ExtractionPlanTests: XCTestCase {
    private func listing(_ paths: [String]) -> ArchiveListing {
        ArchiveListing(info: ArchiveInfo(physicalSize: 100),
                       entries: paths.map { ArchiveEntry(path: $0, isDirectory: false, size: 10) })
    }

    func testSingleRootItemExtractsWithoutAWrapperFolder() {
        let plan = ExtractionPlan.make(archive: URL(fileURLWithPath: "/tmp/Project.zip"),
                                       into: URL(fileURLWithPath: "/tmp/out"),
                                       listing: listing(["Project/a.txt", "Project/b.txt"]),
                                       smartFolder: true)
        XCTAssertFalse(plan.createdWrapperFolder)
        XCTAssertEqual(plan.destination.path, "/tmp/out")
        XCTAssertEqual(plan.revealTarget.lastPathComponent, "Project")
    }

    func testLooseFilesGetAWrapperFolderNamedAfterTheArchive() {
        let plan = ExtractionPlan.make(archive: URL(fileURLWithPath: "/tmp/Loose.tar.gz"),
                                       into: URL(fileURLWithPath: "/tmp/out"),
                                       listing: listing(["a.txt", "b.txt"]),
                                       smartFolder: true)
        XCTAssertTrue(plan.createdWrapperFolder)
        XCTAssertEqual(plan.destination.lastPathComponent, "Loose")
    }

    func testTurningOffSmartFolderAlwaysWraps() {
        let plan = ExtractionPlan.make(archive: URL(fileURLWithPath: "/tmp/Project.zip"),
                                       into: URL(fileURLWithPath: "/tmp/out"),
                                       listing: listing(["Project/a.txt"]),
                                       smartFolder: false)
        XCTAssertTrue(plan.createdWrapperFolder)
        XCTAssertEqual(plan.destination.lastPathComponent, "Project")
    }
}
