import XCTest
@testable import JustArcCore

/// Runs real extractions for each way of resolving a folder that is already there.
final class ExtractionRunnerTests: XCTestCase {
    private let engine = SevenZipEngine()
    private var root: URL!
    private var archive: URL!
    private var destination: URL!
    private var listing: ArchiveListing!

    override func setUp() async throws {
        try await super.setUp()
        (root, archive) = try await FixtureBuilder.makeArchive(named: "folders.zip")
        destination = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        listing = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
    }

    override func tearDown() {
        FixtureBuilder.cleanup(root)
        super.tearDown()
    }

    /// Puts a "payload" folder at the destination holding one file of our own.
    private func placeExistingFolder() throws {
        let existing = destination.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try "mine\n".write(to: existing.appendingPathComponent("of-my-own.txt"),
                           atomically: true, encoding: .utf8)
        try "mine\n".write(to: existing.appendingPathComponent("readme.txt"),
                           atomically: true, encoding: .utf8)
    }

    private func job(_ resolution: FolderConflictResolution,
                     fileOverwrite: OverwriteMode = .overwrite) -> ExtractionJob {
        ExtractionJob(archive: archive,
                      destination: destination,
                      allEntries: listing.entries,
                      selectedEntries: nil,
                      roots: ["payload"],
                      folderConflicts: ["payload"],
                      folderResolution: resolution,
                      fileOverwrite: fileOverwrite)
    }

    private func contents(_ relative: String) -> [String] {
        let url = destination.appendingPathComponent(relative)
        return ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    func testFolderConflictIsDetected() throws {
        try placeExistingFolder()
        let report = ExtractionConflicts.find(entries: listing.entries,
                                              roots: ["payload"], in: destination)
        XCTAssertEqual(report.folders, ["payload"])
        XCTAssertTrue(report.hasFileConflicts, "readme.txt collides inside the folder")
    }

    func testNoFolderConflictWhenTheDestinationIsEmpty() {
        let report = ExtractionConflicts.find(entries: listing.entries,
                                              roots: ["payload"], in: destination)
        XCTAssertTrue(report.isEmpty)
    }

    func testMergeKeepsWhatWasThereAndAddsTheArchive() async throws {
        try placeExistingFolder()
        let outcome = try await ExtractionRunner.run(job(.merge), engine: engine)

        let names = contents("payload")
        XCTAssertTrue(names.contains("of-my-own.txt"), "merging must not lose existing files")
        XCTAssertTrue(names.contains("readme.txt"))
        XCTAssertTrue(names.contains("docs"))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("payload/readme.txt"),
                                  encoding: .utf8), "hello world\n",
                       "the archived file should have won, since the file rule was overwrite")
        XCTAssertEqual(outcome.producedItems.map(\.lastPathComponent), ["payload"])
        XCTAssertTrue(outcome.trashedFolders.isEmpty)
    }

    func testMergeCanKeepTheExistingFileInstead() async throws {
        try placeExistingFolder()
        _ = try await ExtractionRunner.run(job(.merge, fileOverwrite: .skip), engine: engine)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("payload/readme.txt"),
                                  encoding: .utf8), "mine\n")
        XCTAssertTrue(contents("payload").contains("docs"), "the rest still extracted")
    }

    func testReplaceRemovesTheExistingFolderEntirely() async throws {
        try placeExistingFolder()
        let outcome = try await ExtractionRunner.run(job(.replace), engine: engine)

        let names = contents("payload")
        XCTAssertFalse(names.contains("of-my-own.txt"), "replace means the old folder is gone")
        XCTAssertTrue(names.contains("readme.txt"))
        XCTAssertEqual(outcome.trashedFolders, ["payload"])
    }

    func testKeepBothLeavesTheExistingFolderUntouched() async throws {
        try placeExistingFolder()
        let outcome = try await ExtractionRunner.run(job(.keepBoth), engine: engine)

        XCTAssertTrue(contents("payload").contains("of-my-own.txt"),
                      "the folder that was already there must be untouched")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("payload/readme.txt"),
                                  encoding: .utf8), "mine\n")

        let produced = try XCTUnwrap(outcome.producedItems.first)
        XCTAssertNotEqual(produced.lastPathComponent, "payload")
        XCTAssertTrue(produced.lastPathComponent.hasPrefix("payload"), produced.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: produced.appendingPathComponent("readme.txt").path))
    }

    func testKeepBothLeavesNoStagingFolderBehind() async throws {
        try placeExistingFolder()
        _ = try await ExtractionRunner.run(job(.keepBoth), engine: engine)
        let leftovers = contents("").filter { $0.hasPrefix(".justarc-extract") }
        XCTAssertTrue(leftovers.isEmpty, "staging should be cleaned up: \(leftovers)")
    }

    func testSkipExtractsNothingIntoTheExistingFolder() async throws {
        try placeExistingFolder()
        let outcome = try await ExtractionRunner.run(job(.skip), engine: engine)

        XCTAssertEqual(contents("payload").sorted(), ["of-my-own.txt", "readme.txt"],
                       "nothing from the archive should have been written")
        XCTAssertEqual(outcome.skippedFolders, ["payload"])
        XCTAssertTrue(outcome.extractedNothing)
    }

    func testSkipStillExtractsTheFoldersThatDoNotCollide() async throws {
        try placeExistingFolder()
        // A second root that is not in the way.
        let extra = root.appendingPathComponent("extra.txt")
        try "extra\n".write(to: extra, atomically: true, encoding: .utf8)
        _ = try await FixtureBuilder.run(["a", archive.path, "extra.txt"], in: root)
        listing = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)

        var pending = job(.skip)
        pending.allEntries = listing.entries
        pending.roots = ["payload", "extra.txt"]
        let outcome = try await ExtractionRunner.run(pending, engine: engine)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("extra.txt").path))
        XCTAssertEqual(outcome.producedItems.map(\.lastPathComponent), ["extra.txt"])
        XCTAssertEqual(contents("payload").sorted(), ["of-my-own.txt", "readme.txt"])
    }

    func testResolvingTheFolderRemovesTheFileQuestionsInsideIt() throws {
        try placeExistingFolder()
        let report = ExtractionConflicts.find(entries: listing.entries,
                                              roots: ["payload"], in: destination)
        XCTAssertTrue(report.hasFileConflicts)

        for resolution in [FolderConflictResolution.replace, .keepBoth, .skip] {
            let remaining = ExtractionConflicts.fileConflictsRemaining(
                after: resolution, report: report, entries: listing.entries, in: destination)
            XCTAssertFalse(remaining.hasFileConflicts,
                           "\(resolution) settles everything inside the folder")
        }

        let merged = ExtractionConflicts.fileConflictsRemaining(
            after: .merge, report: report, entries: listing.entries, in: destination)
        XCTAssertTrue(merged.hasFileConflicts, "merging still has to ask about the files")
    }
}
