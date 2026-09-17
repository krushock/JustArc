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
        try FileManager.default.createDirectory(
            at: destination.appendingPathComponent("payload/docs"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: destination)
    }

    private func place(_ relative: String) throws {
        try "existing\n".write(to: destination.appendingPathComponent(relative),
                               atomically: true, encoding: .utf8)
    }

    func testAnEmptyDestinationHasNoConflicts() {
        let report = ExtractionConflicts.find(entries: entries, in: destination)
        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(report.count, 0)
    }

    func testOnlyFilesThatAreActuallyThereCount() throws {
        try place("payload/readme.txt")
        let report = ExtractionConflicts.find(entries: entries, in: destination)
        XCTAssertEqual(report.count, 1)
        XCTAssertEqual(report.paths, ["payload/readme.txt"])
    }

    func testDirectoriesAreNotConflicts() throws {
        // payload/ and payload/docs/ both exist, but merging into a folder is normal.
        let report = ExtractionConflicts.find(entries: entries, in: destination)
        XCTAssertTrue(report.isEmpty, "an existing folder is not a collision")
    }

    func testSeveralConflictsAreCountedAndSampled() throws {
        try place("payload/readme.txt")
        try place("payload/docs/notes.txt")
        try place("payload/new.txt")

        let report = ExtractionConflicts.find(entries: entries, in: destination, sampleLimit: 2)
        XCTAssertEqual(report.count, 3)
        XCTAssertEqual(report.paths.count, 2, "the sample is capped for display")
    }

    func testUnsafePathsAreIgnored() {
        let hostile = [ArchiveEntry(path: "../escape.txt", isDirectory: false)]
        XCTAssertTrue(ExtractionConflicts.find(entries: hostile, in: destination).isEmpty)
    }

    func testADanglingSymlinkStillCounts() throws {
        let link = destination.appendingPathComponent("payload/readme.txt")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: URL(fileURLWithPath: "/nowhere-\(UUID().uuidString)"))
        let report = ExtractionConflicts.find(entries: entries, in: destination)
        XCTAssertEqual(report.count, 1, "extracting over a broken link would still fail")
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
