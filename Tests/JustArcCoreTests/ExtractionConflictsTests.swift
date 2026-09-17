import XCTest
@testable import JustArcCore

final class ExtractionConflictsTests: XCTestCase {
    private var destination: URL!

    private let entries = [
        ArchiveEntry(path: "payload", isDirectory: true),
        ArchiveEntry(path: "payload/readme.txt", isDirectory: false, size: 12),
        ArchiveEntry(path: "payload/docs", isDirectory: true),
        ArchiveEntry(path: "payload/docs/notes.txt", isDirectory: false, size: 20),
        ArchiveEntry(path: "payload/new.txt", isDirectory: false, size: 5),
    ]

    override func setUpWithError() throws {
        destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("conflicts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: destination)
    }

    private func makeFolders() throws {
        try FileManager.default.createDirectory(
            at: destination.appendingPathComponent("payload/docs"), withIntermediateDirectories: true)
    }

    private func place(_ relative: String) throws {
        try "existing\n".write(to: destination.appendingPathComponent(relative),
                               atomically: true, encoding: .utf8)
    }

    func testAnEmptyDestinationHasNoConflicts() {
        let report = ExtractionConflicts.find(entries: entries, roots: ["payload"], in: destination)
        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(report.fileCount, 0)
        XCTAssertTrue(report.folders.isEmpty)
    }

    /// An existing folder is reported separately from the files inside it, because
    /// merging into it is a reasonable thing to want and a file collision is not.
    func testAnExistingRootFolderIsAFolderConflict() throws {
        try makeFolders()
        let report = ExtractionConflicts.find(entries: entries, roots: ["payload"], in: destination)
        XCTAssertEqual(report.folders, ["payload"])
        XCTAssertFalse(report.hasFileConflicts, "no files are there yet, only the folders")
    }

    func testDirectoryEntriesAreNeverCountedAsFileConflicts() throws {
        try makeFolders()
        let report = ExtractionConflicts.find(entries: entries, roots: [], in: destination)
        XCTAssertEqual(report.fileCount, 0)
    }

    func testOnlyFilesThatAreActuallyThereCount() throws {
        try makeFolders()
        try place("payload/readme.txt")
        let report = ExtractionConflicts.find(entries: entries, roots: [], in: destination)
        XCTAssertEqual(report.fileCount, 1)
        XCTAssertEqual(report.files, ["payload/readme.txt"])
    }

    func testSeveralConflictsAreCountedAndSampled() throws {
        try makeFolders()
        try place("payload/readme.txt")
        try place("payload/docs/notes.txt")
        try place("payload/new.txt")

        let report = ExtractionConflicts.find(entries: entries, roots: [], in: destination,
                                              sampleLimit: 2)
        XCTAssertEqual(report.fileCount, 3)
        XCTAssertEqual(report.files.count, 2, "the sample is capped for display")
    }

    func testUnsafePathsAreIgnored() {
        let hostile = [ArchiveEntry(path: "../escape.txt", isDirectory: false)]
        let report = ExtractionConflicts.find(entries: hostile, roots: ["../escape"], in: destination)
        XCTAssertTrue(report.isEmpty)
    }

    func testADanglingSymlinkStillCounts() throws {
        try makeFolders()
        let link = destination.appendingPathComponent("payload/readme.txt")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: URL(fileURLWithPath: "/nowhere-\(UUID().uuidString)"))
        let report = ExtractionConflicts.find(entries: entries, roots: [], in: destination)
        XCTAssertEqual(report.fileCount, 1, "extracting over a broken link would still fail")
    }

    func testAFileWhereAFolderShouldGoIsNotAFolderConflict() throws {
        try place("payload")
        let report = ExtractionConflicts.find(entries: entries, roots: ["payload"], in: destination)
        XCTAssertTrue(report.folders.isEmpty, "a file is not something you can merge into")
    }
}

final class OverwriteModeSettingTests: XCTestCase {
    func testEachFixedChoiceMapsOntoAnEngineMode() {
        XCTAssertEqual(OverwriteMode.overwrite.sevenZipFlag, "-aoa")
        XCTAssertEqual(OverwriteMode.skip.sevenZipFlag, "-aos")
        XCTAssertEqual(OverwriteMode.renameNew.sevenZipFlag, "-aou")
        XCTAssertEqual(OverwriteMode.renameExisting.sevenZipFlag, "-aot")
    }
}
