import XCTest
@testable import JustArcCore

/// Second-pass review: what a hostile listing costs the model layer.
final class SecondPassTreeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("justarc-review2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func python(_ script: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script]
        process.currentDirectoryURL = root
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    /// One entry, thousands of folders deep: how long the tree takes to build.
    func testADeepPathBuildsATreeInReasonableTime() {
        func time(_ depth: Int) -> Double {
            let entry = ArchiveEntry(path: String(repeating: "a/", count: depth) + "f", isDirectory: false, size: 1)
            let start = Date()
            let tree = EntryTree(entries: [entry])
            _ = tree.root.children.count
            return Date().timeIntervalSince(start)
        }
        let small = time(2_000), medium = time(4_000), large = time(8_000)
        print(String(format: "T1 tree for one path: depth 2k %.2fs, 4k %.2fs, 8k %.2fs", small, medium, large))
        XCTAssertLessThan(large, 2.0)
    }

    /// The deepest path a zip can carry (its name field is 64 KB).
    func testOpeningAZipWithVeryDeepPaths() async throws {
        try python("""
        import zipfile
        with zipfile.ZipFile('deep.zip', 'w', zipfile.ZIP_DEFLATED) as z:
            z.writestr('a/' * 32000 + 'f', 'x')
        """)
        let archive = root.appendingPathComponent("deep.zip")
        let size = (try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.intValue ?? 0
        let session = ArchiveSession(archiveURL: archive)
        let start = Date()
        FileHandle.standardError.write(Data("T2 opening a \(size)-byte zip\n".utf8))
        try await session.load()
        let took = Date().timeIntervalSince(start)
        print(String(format: "T2 a %d-byte zip took %.1fs to open; entries: %d", size, took, session.listing.entries.count))
        XCTAssertLessThan(took, 5.0)
    }

    /// A tar has no limit on the length of a name.
    func testOpeningATarWithAVeryDeepPath() async throws {
        try python("""
        import tarfile, io
        with tarfile.open('deep.tar.gz', 'w:gz', format=tarfile.PAX_FORMAT) as t:
            info = tarfile.TarInfo('a/' * 150000 + 'f')
            info.size = 1
            t.addfile(info, io.BytesIO(b'x'))
        """)
        let archive = root.appendingPathComponent("deep.tar.gz")
        let size = (try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.intValue ?? 0
        FileHandle.standardError.write(Data("T2b listing a \(size)-byte tar.gz\n".utf8))
        let listing = try await SevenZipEngine().list(archive: archive, password: nil, encodingCodePage: nil)
        FileHandle.standardError.write(Data("T2b listed \(listing.entries.count) entries, longest path \(listing.entries.map(\.path.count).max() ?? 0) characters; building what Quick Extract builds\n".utf8))
        let plan = ExtractionPlan.make(archive: archive, into: root, listing: listing, smartFolder: true)
        FileHandle.standardError.write(Data("T2b plan made: \(plan.createdWrapperFolder)\n".utf8))
    }

    /// What one edit costs in a large archive: every stage, unstage and deletion rebuilds the tree.
    func testOneEditInALargeArchive() {
        let entries = (0..<100_000).map {
            ArchiveEntry(path: "folder-\($0 / 100)/file-\($0).txt", isDirectory: false, size: 1)
        }
        var start = Date()
        let tree = EntryTree(entries: entries)
        let build = Date().timeIntervalSince(start)
        _ = tree.root.children.count

        let scanned = ArchiveSession.Scanned(url: URL(fileURLWithPath: "/nonexistent/big"),
                                             entries: [ArchiveEntry(path: "big", isDirectory: true)]
                                                + entries.map { $0.moved(into: "big") })
        let session = ArchiveSession(archiveURL: nil)
        session.stage(scanned: [scanned])
        start = Date()
        session.markForDeletion(["big/folder-1/file-100.txt"])
        let one = Date().timeIntervalSince(start)
        start = Date()
        session.markForDeletion((0..<100).map { "big/folder-2/file-\(200 + $0).txt" })
        let hundred = Date().timeIntervalSince(start)
        print(String(format: "T4 100k entries: tree build %.2fs; deleting one row %.2fs; deleting 100 rows %.2fs", build, one, hundred))
    }

    /// Recursion over the tree, at a depth a zip (32k folders), tar or 7z (unlimited) can carry.
    func testAVeryDeepTreeDoesNotOverflowTheStack() throws {
        func say(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
        let depth = Int(ProcessInfo.processInfo.environment["REVIEW_DEPTH"] ?? "") ?? 32_000
        let entry = ArchiveEntry(path: String(repeating: "a/", count: depth) + "f", isDirectory: false, size: 1)
        say("T3 depth \(depth): building")
        var tree: EntryTree? = EntryTree(entries: [entry])
        say("T3 built")
        say("T3 total size: \(tree!.root.totalSize)")
        say("T3 files: \(tree!.root.fileCount)")
        say("T3 descendants: \(tree!.root.descendantEntries().count)")
        tree = nil
        say("T3 released")
    }
}
