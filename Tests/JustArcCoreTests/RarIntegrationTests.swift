import XCTest
@testable import JustArcCore

/// Downloads RARLAB's tools and exercises the RAR write path for real.
/// Skipped unless JUSTARC_NETWORK_TESTS=1, since it reaches the network and
/// installs into Application Support.
final class RarIntegrationTests: XCTestCase {
    private var enabled: Bool {
        ProcessInfo.processInfo.environment["JUSTARC_NETWORK_TESTS"] == "1"
    }

    func testDownloadThenWriteAndReadBackARarArchive() async throws {
        try XCTSkipUnless(enabled, "set JUSTARC_NETWORK_TESTS=1 to run")

        let installation = try await RarToolInstaller.install { _ in }
        XCTAssertTrue(installation.wasVerified, "the download was installed without matching a checksum")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installation.tool.path))
        XCTAssertFalse(installation.version.isEmpty)
        XCTAssertTrue(RarToolInstaller.isManagedInstall)
        XCTAssertNotNil(EngineLocator.externalRAR)

        // The factory must now hand out the RAR engine for .rar files.
        let engine = EngineFactory.engine(for: URL(fileURLWithPath: "/tmp/x.rar"))
        XCTAssertTrue(engine is RarEngine)

        let root = try FixtureBuilder.makeSourceTree()
        defer { FixtureBuilder.cleanup(root) }
        let archive = root.appendingPathComponent("made.rar")

        try await engine.create(archive: archive,
                                items: [root.appendingPathComponent("payload")],
                                options: CompressionOptions(formatKey: "rar", level: 3),
                                cancellation: nil, progress: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))

        // Reading goes through 7-Zip, which handles RAR5.
        var listing = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
        XCTAssertEqual(listing.info.formatName.lowercased(), "rar5")
        XCTAssertTrue(listing.entries.contains { $0.path == "payload/readme.txt" })

        let destination = root.appendingPathComponent("out-rar")
        try await engine.extract(archive: archive, entries: nil, to: destination, password: nil,
                                 overwrite: .overwrite, flattenPaths: false,
                                 cancellation: nil, progress: nil)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("payload/readme.txt"),
                                  encoding: .utf8), "hello world\n")

        // Delete and rename go through the rar tool.
        let victim = try XCTUnwrap(listing.entries.first { $0.path == "payload/readme.txt" })
        try await engine.delete(entries: [victim], from: archive, password: nil)
        listing = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
        XCTAssertFalse(listing.entries.contains { $0.path == "payload/readme.txt" })

        let toRename = try XCTUnwrap(listing.entries.first { $0.path == "payload/docs/notes.txt" })
        try await engine.rename(entry: toRename, to: "payload/docs/renamed.txt",
                                in: archive, password: nil)
        listing = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
        XCTAssertTrue(listing.entries.contains { $0.path == "payload/docs/renamed.txt" })
    }

    /// The hashes built into JustArc came from Homebrew's record. This fetches each
    /// file from rarlab.com and checks that it really has the hash on record, for
    /// the Intel build as well as the one this Mac would install.
    func testTheBuiltInChecksumsMatchWhatRarlabServes() async throws {
        try XCTSkipUnless(enabled, "set JUSTARC_NETWORK_TESTS=1 to run")
        XCTAssertFalse(RarToolInstaller.knownChecksums.isEmpty)

        for (fileName, expected) in RarToolInstaller.knownChecksums.sorted(by: { $0.key < $1.key }) {
            let url = try XCTUnwrap(URL(string: "https://www.rarlab.com/rar/\(fileName)"))
            let (data, response) = try await URLSession.shared.data(from: url)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, fileName)

            let file = FileManager.default.temporaryDirectory.appendingPathComponent("justarc-check-\(fileName)")
            try data.write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let digest = try RarToolInstaller.sha256(of: file)
            print("rarlab \(fileName): \(data.count) bytes, sha256 \(digest)")
            XCTAssertEqual(digest, expected, "\(fileName) is not what the built-in checksum says")
            XCTAssertEqual(RarToolInstaller.verdict(digest: digest, fileName: fileName, published: [:]), .verified)
        }
    }

    func testEncryptedRarRoundTrip() async throws {
        try XCTSkipUnless(enabled, "set JUSTARC_NETWORK_TESTS=1 to run")
        _ = try await RarToolInstaller.install { _ in }

        let engine = RarEngine()
        let root = try FixtureBuilder.makeSourceTree()
        defer { FixtureBuilder.cleanup(root) }
        let archive = root.appendingPathComponent("secret.rar")

        try await engine.create(archive: archive,
                                items: [root.appendingPathComponent("payload")],
                                options: CompressionOptions(formatKey: "rar", level: 1,
                                                            password: "sesame",
                                                            encryptFileNames: true),
                                cancellation: nil, progress: nil)

        do {
            _ = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
            XCTFail("header-encrypted RAR should not list without a password")
        } catch let error as ArchiveError {
            XCTAssertTrue(error.isPasswordProblem, "unexpected: \(error)")
        }

        let listing = try await engine.list(archive: archive, password: "sesame", encodingCodePage: nil)
        XCTAssertTrue(listing.entries.contains { $0.path == "payload/readme.txt" })
    }

    func testUpdatingAnEditedEntryWritesItBackAtTheSamePath() async throws {
        try XCTSkipUnless(enabled, "set JUSTARC_NETWORK_TESTS=1 to run")
        _ = try await RarToolInstaller.install { _ in }

        let engine = RarEngine()
        let root = try FixtureBuilder.makeSourceTree()
        defer { FixtureBuilder.cleanup(root) }
        let archive = root.appendingPathComponent("edit.rar")
        try await engine.create(archive: archive,
                                items: [root.appendingPathComponent("payload")],
                                options: CompressionOptions(formatKey: "rar", level: 1),
                                cancellation: nil, progress: nil)

        let scratch = root.appendingPathComponent("scratch")
        let created = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
        let entry = try XCTUnwrap(created.entries.first { $0.path == "payload/readme.txt" })
        let pulled = try await engine.extractSingle(archive: archive, entry: entry,
                                                    to: scratch, password: nil)
        try "edited on disk\n".write(to: pulled, atomically: true, encoding: .utf8)

        try await engine.update(fileAt: pulled, entryPath: entry.path, in: archive,
                                options: CompressionOptions(formatKey: "rar", level: 1),
                                cancellation: nil, progress: nil)

        let reread = root.appendingPathComponent("reread")
        try await engine.extract(archive: archive, entries: [entry], to: reread, password: nil,
                                 overwrite: .overwrite, flattenPaths: false,
                                 cancellation: nil, progress: nil)
        XCTAssertEqual(try String(contentsOf: reread.appendingPathComponent("payload/readme.txt"),
                                  encoding: .utf8), "edited on disk\n")
    }
}
