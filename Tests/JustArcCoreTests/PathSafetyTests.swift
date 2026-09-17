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
        let root = PathSafety.canonicalRoot(destination)
        let resolved = try PathSafety.resolvedURL(for: "payload/readme.txt", in: destination)
        XCTAssertEqual(resolved.path, root.appendingPathComponent("payload/readme.txt").path)
        XCTAssertThrowsError(try PathSafety.resolvedURL(for: "../outside.txt", in: destination))
    }

    /// Regression: extracting into a folder under /tmp used to reject every entry.
    /// `standardizedFileURL` rewrites /private/tmp to /tmp only for paths that already
    /// exist, so the existing destination and its new child disagreed on the prefix
    /// and the containment check treated ordinary names as traversal attempts.
    func testExistingDestinationUnderPrivateTmpAcceptsOrdinaryEntries() throws {
        let destination = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("justarc-prefix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        // "Applications" is the symlink every app disk image ships with.
        for name in ["Applications", "Demo.app", "Payload/readme.txt"] {
            XCTAssertNoThrow(try PathSafety.resolvedURL(for: name, in: destination),
                             "\(name) was wrongly rejected")
        }

        let resolved = try PathSafety.resolvedURL(for: "Applications", in: destination)
        XCTAssertTrue(resolved.path.hasSuffix("/Applications"))
        XCTAssertTrue(resolved.deletingLastPathComponent().path
            .hasSuffix(destination.lastPathComponent))
    }

    func testDestinationReachedThroughASymlinkStillAcceptsEntries() throws {
        let real = FileManager.default.temporaryDirectory
            .appendingPathComponent("justarc-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("justarc-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: real)
        }

        let resolved = try PathSafety.resolvedURL(for: "notes.txt", in: link)
        XCTAssertEqual(resolved.path, PathSafety.canonicalRoot(real)
            .appendingPathComponent("notes.txt").path)
    }

    func testTraversalIsStillBlockedAfterTheRootIsCanonicalised() throws {
        let destination = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("justarc-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        for hostile in ["../escape.txt", "a/../../escape.txt", "/etc/passwd", "~/secrets"] {
            XCTAssertThrowsError(try PathSafety.resolvedURL(for: hostile, in: destination),
                                 "\(hostile) should be rejected")
        }
    }

    func testDanglingSymlinkCountsAsPresent() throws {
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("justarc-dangling-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: URL(fileURLWithPath: "/nowhere-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: link) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path),
                       "fileExists follows the link, which is why it cannot be used here")
        XCTAssertTrue(PathSafety.itemExists(at: link))
        XCTAssertNotEqual(PathSafety.uniqueURL(for: link).path, link.path)
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
