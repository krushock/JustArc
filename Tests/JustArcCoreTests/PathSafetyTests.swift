import XCTest
@testable import JustArcCore

final class PathSafetyTests: XCTestCase {
    func testRejectsTraversalAndAbsolutePaths() {
        XCTAssertFalse(PathSafety.isSafe(entryPath: "../escape.txt"))
        XCTAssertFalse(PathSafety.isSafe(entryPath: "a/../../escape.txt"))
        XCTAssertFalse(PathSafety.isSafe(entryPath: "/etc/passwd"))
        XCTAssertFalse(PathSafety.isSafe(entryPath: "C:/Windows/system32"))
        XCTAssertFalse(PathSafety.isSafe(entryPath: ""))
    }

    func testAcceptsOrdinaryPaths() {
        XCTAssertTrue(PathSafety.isSafe(entryPath: "payload/readme.txt"))
        XCTAssertTrue(PathSafety.isSafe(entryPath: "a.b.c"))
        XCTAssertTrue(PathSafety.isSafe(entryPath: "dir/.hidden"))
    }

    func testResolvedURLStaysInsideDestination() throws {
        let destination = URL(fileURLWithPath: "/tmp/justarc-dest")
        let resolved = try PathSafety.resolvedURL(for: "payload/readme.txt", in: destination)
        XCTAssertEqual(resolved.path, "/tmp/justarc-dest/payload/readme.txt")
        XCTAssertThrowsError(try PathSafety.resolvedURL(for: "../outside.txt", in: destination))
    }

    func testBackslashTraversalIsRejected() {
        XCTAssertFalse(PathSafety.isSafe(entryPath: "..\\escape.txt"))
    }

    func testBombHeuristicFlagsHugeExpansion() {
        let entries = [ArchiveEntry(path: "big.bin", isDirectory: false, size: 8 * 1024 * 1024 * 1024)]
        let info = ArchiveInfo(physicalSize: 1024)
        let verdict = PathSafety.evaluate(listing: ArchiveListing(info: info, entries: entries))
        XCTAssertTrue(verdict.isSuspicious)
    }

    func testOrdinaryArchiveIsNotFlagged() {
        let entries = [ArchiveEntry(path: "a.txt", isDirectory: false, size: 1_000_000)]
        let info = ArchiveInfo(physicalSize: 400_000)
        XCTAssertFalse(PathSafety.evaluate(listing: ArchiveListing(info: info, entries: entries)).isSuspicious)
    }
}
