import XCTest
@testable import JustArcCore

/// Writing through the in-process library: what the command-line tool used to do,
/// and a few things it got wrong.
final class SevenZipWriteTests: XCTestCase {
    private let engine = SevenZipEngine()

    func testTarGzIsReallyCompressedAndReadsBack() async throws {
        let root = try FixtureBuilder.makeSourceTree()
        defer { FixtureBuilder.cleanup(root) }

        let archive = root.appendingPathComponent("made.tar.gz")
        try await engine.create(archive: archive, items: [root.appendingPathComponent("payload")],
                                options: CompressionOptions(formatKey: "tgz"))

        let magic = try FileHandle(forReadingFrom: archive).read(upToCount: 2)
        XCTAssertEqual(magic.map(Array.init), [0x1F, 0x8B], "a .tar.gz must start with the gzip signature")

        let listing = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
        XCTAssertEqual(listing.info.formatName.lowercased(), "gzip / tar")
        XCTAssertTrue(listing.entries.contains { $0.path == "payload/docs/notes.txt" })
        engine.release(archive: archive)
    }

    func testEditingATarGzKeepsItCompressed() async throws {
        let root = try FixtureBuilder.makeSourceTree()
        defer { FixtureBuilder.cleanup(root) }

        let archive = root.appendingPathComponent("edit.tgz")
        try await engine.create(archive: archive, items: [root.appendingPathComponent("payload")],
                                options: CompressionOptions(formatKey: "tgz"))
        _ = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)

        let victim = ArchiveEntry(path: "payload/readme.txt", isDirectory: false)
        try await engine.delete(entries: [victim], from: archive, password: nil)

        let magic = try FileHandle(forReadingFrom: archive).read(upToCount: 2)
        XCTAssertEqual(magic.map(Array.init), [0x1F, 0x8B])
        let listing = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
        XCTAssertFalse(listing.entries.contains { $0.path == "payload/readme.txt" })
        XCTAssertTrue(listing.entries.contains { $0.path == "payload/docs/notes.txt" })
        engine.release(archive: archive)
    }

    func testZipEncryptionMethodIsTheOneChosen() async throws {
        for (method, expected) in [(CompressionOptions.ZipEncryption.aes256, "AES-256"),
                                   (.zipCrypto, "ZipCrypto")] {
            let root = try FixtureBuilder.makeSourceTree()
            defer { FixtureBuilder.cleanup(root) }

            let archive = root.appendingPathComponent("secret.zip")
            try await engine.create(archive: archive, items: [root.appendingPathComponent("payload")],
                                    options: CompressionOptions(formatKey: "zip", password: "sesame",
                                                                zipEncryption: method))
            let listing = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
            let file = try XCTUnwrap(listing.entries.first { $0.path == "payload/readme.txt" })
            XCTAssertTrue(file.isEncrypted)
            XCTAssertTrue(file.method?.contains(expected) == true, "method was \(file.method ?? "nil")")

            let out = root.appendingPathComponent("out")
            try await engine.extract(archive: archive, entries: nil, to: out, password: "sesame",
                                     overwrite: .overwrite, flattenPaths: false)
            XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("payload/readme.txt"),
                                      encoding: .utf8), "hello world\n")
        }
    }

    func testEditingAHeaderEncryptedArchiveKeepsTheHeadersEncrypted() async throws {
        let root = try FixtureBuilder.makeSourceTree()
        defer { FixtureBuilder.cleanup(root) }

        let archive = root.appendingPathComponent("hidden.7z")
        try await engine.create(archive: archive, items: [root.appendingPathComponent("payload")],
                                options: CompressionOptions(formatKey: "7z", password: "sesame",
                                                            encryptFileNames: true))
        let victim = ArchiveEntry(path: "payload/readme.txt", isDirectory: false)
        try await engine.delete(entries: [victim], from: archive, password: "sesame")

        do {
            _ = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
            XCTFail("the edited archive lost its header encryption")
        } catch let error as ArchiveError {
            XCTAssertEqual(error, .passwordRequired)
        }
        let listing = try await engine.list(archive: archive, password: "sesame", encodingCodePage: nil)
        XCTAssertFalse(listing.entries.contains { $0.path == "payload/readme.txt" })
        XCTAssertTrue(listing.entries.contains { $0.path == "payload/docs/notes.txt" })
    }

    func testRenamingAFolderMovesEverythingInside() async throws {
        let (root, archive) = try await FixtureBuilder.makeArchive(named: "folders.7z")
        defer { FixtureBuilder.cleanup(root) }

        let folder = ArchiveEntry(path: "payload/docs", isDirectory: true)
        try await engine.rename(entry: folder, to: "payload/papers", in: archive, password: nil)

        let paths = Set(try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
            .entries.map(\.path))
        XCTAssertTrue(paths.contains("payload/papers/notes.txt"), "\(paths)")
        XCTAssertFalse(paths.contains { $0.hasPrefix("payload/docs") }, "\(paths)")
    }

    func testAddingReplacesAnItemWithTheSamePath() async throws {
        let (root, archive) = try await FixtureBuilder.makeArchive(named: "update.zip")
        defer { FixtureBuilder.cleanup(root) }

        let edited = root.appendingPathComponent("edited.txt")
        try "changed\n".write(to: edited, atomically: true, encoding: .utf8)
        try await engine.update(fileAt: edited, entryPath: "payload/readme.txt", in: archive,
                                options: CompressionOptions(formatKey: "zip"))

        let listing = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
        XCTAssertEqual(listing.entries.filter { $0.path == "payload/readme.txt" }.count, 1)
        let out = root.appendingPathComponent("out")
        try await engine.extract(archive: archive, entries: nil, to: out, password: nil,
                                 overwrite: .overwrite, flattenPaths: false)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("payload/readme.txt"),
                                  encoding: .utf8), "changed\n")
    }

    func testSymbolicLinksAreStoredAsLinks() async throws {
        let root = try FixtureBuilder.makeSourceTree()
        defer { FixtureBuilder.cleanup(root) }
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("payload/link.txt").path, withDestinationPath: "readme.txt")

        for key in ["zip", "7z", "tar"] {
            let archive = root.appendingPathComponent("links.\(key)")
            try await engine.create(archive: archive, items: [root.appendingPathComponent("payload")],
                                    options: CompressionOptions(formatKey: key))
            let out = root.appendingPathComponent("out-\(key)")
            try await engine.extract(archive: archive, entries: nil, to: out, password: nil,
                                     overwrite: .overwrite, flattenPaths: false)
            let link = out.appendingPathComponent("payload/link.txt").path
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), "readme.txt",
                           "\(key) did not keep the link")
        }
    }

    func testMacMetadataIsLeftOut() async throws {
        let root = try FixtureBuilder.makeSourceTree()
        defer { FixtureBuilder.cleanup(root) }
        try Data().write(to: root.appendingPathComponent("payload/.DS_Store"))
        try Data().write(to: root.appendingPathComponent("payload/._readme.txt"))

        let archive = root.appendingPathComponent("clean.zip")
        try await engine.create(archive: archive, items: [root.appendingPathComponent("payload")],
                                options: CompressionOptions(formatKey: "zip"))
        let names = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
            .entries.map(\.name)
        XCTAssertFalse(names.contains(".DS_Store"))
        XCTAssertFalse(names.contains("._readme.txt"))
        XCTAssertTrue(names.contains("readme.txt"))
    }

    /// A zip made by the Finder: the folder, plus `__MACOSX` holding AppleDouble files.
    func testMacBookkeepingIsHiddenAndNotExtracted() async throws {
        let root = try FixtureBuilder.makeSourceTree()
        defer { FixtureBuilder.cleanup(root) }
        let shadow = root.appendingPathComponent("__MACOSX/payload")
        try FileManager.default.createDirectory(at: shadow, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: shadow.appendingPathComponent("._readme.txt"))
        try Data("x".utf8).write(to: root.appendingPathComponent("payload/._readme.txt"))

        let archive = root.appendingPathComponent("finder.zip")
        try await engine.create(archive: archive,
                                items: [root.appendingPathComponent("payload"),
                                        root.appendingPathComponent("__MACOSX")],
                                options: CompressionOptions(formatKey: "zip", excludeMacMetadata: false))

        let listing = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
        XCTAssertFalse(listing.entries.contains { $0.path.contains("__MACOSX") || $0.name.hasPrefix("._") },
                       listing.entries.map(\.path).joined(separator: ", "))
        XCTAssertTrue(EntryTree(entries: listing.entries).hasSingleRootItem,
                      "the archive holds one folder, so Quick Extract must not wrap it in another")

        let out = root.appendingPathComponent("out")
        try await engine.extract(archive: archive, entries: nil, to: out, password: nil,
                                 overwrite: .overwrite, flattenPaths: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("payload/readme.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("__MACOSX").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("payload/._readme.txt").path))

        // Picking the folder in the browser must not drag its AppleDouble files along.
        let picked = root.appendingPathComponent("out-picked")
        try await engine.extract(archive: archive,
                                 entries: [ArchiveEntry(path: "payload", isDirectory: true)],
                                 to: picked, password: nil, overwrite: .overwrite, flattenPaths: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: picked.appendingPathComponent("payload/docs/notes.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: picked.appendingPathComponent("payload/._readme.txt").path))
    }

    func testSplitVolumesReadBack() async throws {
        let root = try FixtureBuilder.makeSourceTree()
        defer { FixtureBuilder.cleanup(root) }
        let big = root.appendingPathComponent("payload/random.bin")
        var bytes = [UInt8](repeating: 0, count: 300 * 1024)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        try Data(bytes).write(to: big)

        let archive = root.appendingPathComponent("split.7z")
        try await engine.create(archive: archive, items: [root.appendingPathComponent("payload")],
                                options: CompressionOptions(formatKey: "7z", level: 0, volumeSize: "100k"))
        let first = URL(fileURLWithPath: archive.path + ".001")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path + ".003"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        let size = try FileManager.default.attributesOfItem(atPath: first.path)[.size] as? UInt64
        XCTAssertEqual(size, 100 * 1024)

        let out = root.appendingPathComponent("out")
        try await engine.extract(archive: first, entries: nil, to: out, password: nil,
                                 overwrite: .overwrite, flattenPaths: false)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("payload/random.bin")), Data(bytes))
    }

    func testBareCompressorRefusesAFolder() async throws {
        let root = try FixtureBuilder.makeSourceTree()
        defer { FixtureBuilder.cleanup(root) }
        do {
            try await engine.create(archive: root.appendingPathComponent("folder.gz"),
                                    items: [root.appendingPathComponent("payload")],
                                    options: CompressionOptions(formatKey: "gzip"))
            XCTFail("gzip cannot hold a folder")
        } catch let error as ArchiveError {
            if case .ioFailure = error {} else { XCTFail("unexpected \(error)") }
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(leftovers.contains { $0.hasPrefix(".justarc-") }, "scratch left behind: \(leftovers)")
    }

    func testCancellationStopsExtraction() async throws {
        let (root, archive) = try await FixtureBuilder.makeArchive(named: "cancel.7z")
        defer { FixtureBuilder.cleanup(root) }
        let token = CancellationToken()
        token.cancel()
        do {
            try await engine.extract(archive: archive, entries: nil,
                                     to: root.appendingPathComponent("out"), password: nil,
                                     overwrite: .overwrite, flattenPaths: false, cancellation: token)
            XCTFail("a cancelled extraction should throw")
        } catch let error as ArchiveError {
            XCTAssertEqual(error, .cancelled)
        }
    }
}
