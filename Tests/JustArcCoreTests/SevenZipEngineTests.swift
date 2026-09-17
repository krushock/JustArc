import XCTest
@testable import JustArcCore

/// Round-trip tests that create real archives and read them back through 7zz.
final class SevenZipEngineTests: XCTestCase {
    private let engine = SevenZipEngine()

    func testEngineIsAvailable() throws {
        XCTAssertNoThrow(try EngineLocator.requireSevenZip())
    }

    func testZipRoundTrip() async throws {
        try await roundTrip(archiveName: "fixture.zip", expectedFormat: "zip")
    }

    func testSevenZipRoundTrip() async throws {
        try await roundTrip(archiveName: "fixture.7z", expectedFormat: "7z")
    }

    func testTarRoundTrip() async throws {
        try await roundTrip(archiveName: "fixture.tar", expectedFormat: "tar")
    }

    /// The interesting case: a compressed stream wrapping a tar, which needs the pipeline.
    func testTarGzIsListedThroughTheNestedPipeline() async throws {
        let (root, _) = try await FixtureBuilder.makeArchive(named: "inner.tar")
        defer { FixtureBuilder.cleanup(root) }

        let gz = root.appendingPathComponent("fixture.tar.gz")
        let result = try await FixtureBuilder.run(["a", "-tgzip", gz.path, "inner.tar"], in: root)
        XCTAssertEqual(result.exitCode, 0, result.combined)

        let listing = try await engine.list(archive: gz, password: nil, encodingCodePage: nil)
        let paths = Set(listing.entries.map(\.path))
        XCTAssertTrue(paths.contains("payload/readme.txt"),
                      "nested tar was not unwrapped, saw: \(paths)")
        XCTAssertTrue(paths.contains("payload/docs/notes.txt"))

        let destination = root.appendingPathComponent("out-tgz")
        try await engine.extract(archive: gz, entries: nil, to: destination,
                                 password: nil, overwrite: .overwrite,
                                 flattenPaths: false, cancellation: nil, progress: nil)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("payload/readme.txt").path))
    }

    func testUnicodeNamesSurviveListingAndExtraction() async throws {
        let (root, archive) = try await FixtureBuilder.makeArchive(named: "unicode.zip")
        defer { FixtureBuilder.cleanup(root) }

        let listing = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
        XCTAssertTrue(listing.entries.contains { $0.name == "ünïcode.txt" },
                      listing.entries.map(\.path).joined(separator: ", "))
    }

    func testExtractsASingleEntryOnly() async throws {
        let (root, archive) = try await FixtureBuilder.makeArchive(named: "single.zip")
        defer { FixtureBuilder.cleanup(root) }

        let listing = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
        let target = try XCTUnwrap(listing.entries.first { $0.path == "payload/docs/notes.txt" })

        let scratch = root.appendingPathComponent("scratch")
        let produced = try await engine.extractSingle(archive: archive, entry: target,
                                                      to: scratch, password: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: produced.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: scratch.appendingPathComponent("payload/readme.txt").path),
            "extractSingle pulled out more than the requested entry")
    }

    func testEncryptedArchiveReportsPasswordStateAndOpensWithPassword() async throws {
        let (root, archive) = try await FixtureBuilder.makeArchive(
            named: "secret.zip", extraArguments: ["-psesame", "-mem=AES256"])
        defer { FixtureBuilder.cleanup(root) }

        let listing = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
        XCTAssertTrue(listing.containsEncryptedEntries)

        let destination = root.appendingPathComponent("out-bad")
        do {
            try await engine.extract(archive: archive, entries: nil, to: destination,
                                     password: "not-it", overwrite: .overwrite,
                                     flattenPaths: false, cancellation: nil, progress: nil)
            XCTFail("extraction with the wrong password should fail")
        } catch let error as ArchiveError {
            XCTAssertTrue(error.isPasswordProblem, "unexpected error: \(error)")
        }

        let good = root.appendingPathComponent("out-good")
        try await engine.extract(archive: archive, entries: nil, to: good,
                                 password: "sesame", overwrite: .overwrite,
                                 flattenPaths: false, cancellation: nil, progress: nil)
        let readme = good.appendingPathComponent("payload/readme.txt")
        XCTAssertEqual(try String(contentsOf: readme, encoding: .utf8), "hello world\n")
    }

    func testHeaderEncryptedSevenZipNeedsAPasswordToList() async throws {
        let (root, archive) = try await FixtureBuilder.makeArchive(
            named: "hidden.7z", extraArguments: ["-psesame", "-mhe=on"])
        defer { FixtureBuilder.cleanup(root) }

        do {
            _ = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
            XCTFail("listing a header-encrypted archive without a password should fail")
        } catch let error as ArchiveError {
            XCTAssertEqual(error, .passwordRequired)
        }

        let listing = try await engine.list(archive: archive, password: "sesame", encodingCodePage: nil)
        XCTAssertFalse(listing.entries.isEmpty)
    }

    func testProgressReachesOneHundredPercent() async throws {
        let (root, archive) = try await FixtureBuilder.makeArchive(named: "progress.7z")
        defer { FixtureBuilder.cleanup(root) }

        let box = ProgressBox()
        try await engine.extract(archive: archive, entries: nil,
                                 to: root.appendingPathComponent("out-progress"),
                                 password: nil, overwrite: .overwrite, flattenPaths: false,
                                 cancellation: nil,
                                 progress: { box.record($0) })
        XCTAssertEqual(box.lastFraction, 1.0)
    }

    func testCreateProducesAReadableArchive() async throws {
        let root = try FixtureBuilder.makeSourceTree()
        defer { FixtureBuilder.cleanup(root) }

        let archive = root.appendingPathComponent("made.7z")
        try await engine.create(archive: archive,
                                items: [root.appendingPathComponent("payload")],
                                options: CompressionOptions(formatKey: "7z", level: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))

        let listing = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
        XCTAssertTrue(listing.entries.contains { $0.path == "payload/readme.txt" })

        let report = try await engine.test(archive: archive, password: nil, cancellation: nil, progress: nil)
        XCTAssertTrue(report.lowercased().contains("everything is ok"), report)
    }

    func testDeleteAndRenameEditTheArchiveInPlace() async throws {
        let (root, archive) = try await FixtureBuilder.makeArchive(named: "edit.zip")
        defer { FixtureBuilder.cleanup(root) }

        var listing = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
        let victim = try XCTUnwrap(listing.entries.first { $0.path == "payload/readme.txt" })
        try await engine.delete(entries: [victim], from: archive, password: nil)

        listing = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
        XCTAssertFalse(listing.entries.contains { $0.path == "payload/readme.txt" })

        let toRename = try XCTUnwrap(listing.entries.first { $0.path == "payload/docs/notes.txt" })
        try await engine.rename(entry: toRename, to: "payload/docs/renamed.txt", in: archive, password: nil)

        listing = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
        XCTAssertTrue(listing.entries.contains { $0.path == "payload/docs/renamed.txt" })
    }

    func testMissingFileSurfacesAnEngineError() async throws {
        let missing = URL(fileURLWithPath: "/tmp/justarc-does-not-exist-\(UUID().uuidString).zip")
        do {
            _ = try await engine.list(archive: missing, password: nil, encodingCodePage: nil)
            XCTFail("listing a missing archive should throw")
        } catch let error as ArchiveError {
            XCTAssertFalse(error.isPasswordProblem)
        }
    }

    // MARK: -

    private func roundTrip(archiveName: String, expectedFormat: String) async throws {
        let (root, archive) = try await FixtureBuilder.makeArchive(named: archiveName)
        defer { FixtureBuilder.cleanup(root) }

        let listing = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
        XCTAssertEqual(listing.info.formatName.lowercased(), expectedFormat)
        XCTAssertTrue(listing.entries.contains { $0.path == "payload/readme.txt" })
        XCTAssertFalse(listing.containsEncryptedEntries)

        let destination = root.appendingPathComponent("out-\(expectedFormat)")
        try await engine.extract(archive: archive, entries: nil, to: destination,
                                 password: nil, overwrite: .overwrite, flattenPaths: false,
                                 cancellation: nil, progress: nil)
        let readme = destination.appendingPathComponent("payload/readme.txt")
        XCTAssertEqual(try String(contentsOf: readme, encoding: .utf8), "hello world\n")
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = -1
    func record(_ progress: ArchiveProgress) {
        guard let fraction = progress.fraction else { return }
        lock.lock(); value = fraction; lock.unlock()
    }
    var lastFraction: Double { lock.lock(); defer { lock.unlock() }; return value }
}
