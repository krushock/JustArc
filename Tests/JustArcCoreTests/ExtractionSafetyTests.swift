import XCTest
@testable import JustArcCore

/// What extraction does to the destination when things go wrong, and what it refuses
/// to do for an archive built to cause harm.
final class ExtractionSafetyTests: XCTestCase {
    private let engine = SevenZipEngine()
    private var root: URL!

    override func setUpWithError() throws {
        root = try FixtureBuilder.makeSourceTree()
    }

    override func tearDown() {
        FixtureBuilder.cleanup(root)
    }

    /// Builds an archive with Python, for the shapes no ordinary tool will write.
    private func python(_ script: String) throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python.path), "python3 is not installed")
        let process = Process()
        process.executableURL = python
        process.arguments = ["-c", script]
        process.currentDirectoryURL = root
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, message)
    }

    private func encryptedZip() async throws -> URL {
        let archive = root.appendingPathComponent("secret.zip")
        try await engine.create(archive: archive, items: [root.appendingPathComponent("payload")],
                                options: CompressionOptions(formatKey: "zip", password: "sesame"))
        return archive
    }

    /// A destination that already holds the files the archive would write.
    private func occupiedDestination() throws -> URL {
        let destination = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("payload/docs"),
                                                withIntermediateDirectories: true)
        try "mine\n".write(to: destination.appendingPathComponent("payload/readme.txt"),
                           atomically: true, encoding: .utf8)
        try "mine too\n".write(to: destination.appendingPathComponent("payload/docs/notes.txt"),
                               atomically: true, encoding: .utf8)
        return destination
    }

    private func everything(under folder: URL) -> [String] {
        let prefix = folder.path + "/"
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        var names: [String] = []
        for case let url as URL in walker! { names.append(String(url.path.dropFirst(prefix.count))) }
        return names.sorted()
    }

    // MARK: - Failure leaves the destination alone

    func testAWrongPasswordLeavesExistingFilesUntouchedInEveryMode() async throws {
        let archive = try await encryptedZip()
        for mode in OverwriteMode.allCases {
            let destination = try occupiedDestination()
            defer { try? FileManager.default.removeItem(at: destination) }
            let before = everything(under: destination)

            do {
                try await engine.extract(archive: archive, entries: nil, to: destination, password: "wrong",
                                         overwrite: mode, flattenPaths: false)
                XCTFail("\(mode): the wrong password was accepted")
            } catch let error as ArchiveError {
                XCTAssertTrue(error.isPasswordProblem, "\(mode): \(error)")
            }

            XCTAssertEqual(everything(under: destination), before, "\(mode): files appeared or vanished")
            XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("payload/readme.txt"),
                                      encoding: .utf8), "mine\n", "\(mode): the existing file was replaced")
            XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("payload/docs/notes.txt"),
                                      encoding: .utf8), "mine too\n", "\(mode)")
        }
    }

    func testAMissingPasswordLeavesNoEmptyFilesBehindForTheRetry() async throws {
        let archive = try await encryptedZip()
        let destination = root.appendingPathComponent("fresh")

        do {
            try await engine.extract(archive: archive, entries: nil, to: destination, password: nil,
                                     overwrite: .renameNew, flattenPaths: false)
            XCTFail("an encrypted archive extracted without its password")
        } catch let error as ArchiveError {
            XCTAssertEqual(error, .passwordRequired)
        }
        XCTAssertFalse(everything(under: destination).contains { !$0.hasSuffix("payload") && !$0.hasSuffix("docs") },
                       "left behind: \(everything(under: destination))")

        // The retry with the right password must produce the files under their own names.
        try await engine.extract(archive: archive, entries: nil, to: destination, password: "sesame",
                                 overwrite: .renameNew, flattenPaths: false)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("payload/readme.txt"),
                                  encoding: .utf8), "hello world\n")
        XCTAssertFalse(everything(under: destination).contains { $0.contains(" 2") },
                       "\(everything(under: destination))")
    }

    func testReplaceStillReplacesWhenAllIsWell() async throws {
        let archive = try await encryptedZip()
        let destination = try occupiedDestination()
        try await engine.extract(archive: archive, entries: nil, to: destination, password: "sesame",
                                 overwrite: .overwrite, flattenPaths: false)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("payload/readme.txt"),
                                  encoding: .utf8), "hello world\n")
        XCTAssertFalse(everything(under: destination).contains { $0.contains(".justarc-") })
    }

    func testEachOverwriteModeDoesWhatItSays() async throws {
        let (fixture, archive) = try await FixtureBuilder.makeArchive(named: "plain.zip")
        defer { FixtureBuilder.cleanup(fixture) }

        var destination = try occupiedDestination()
        try await engine.extract(archive: archive, entries: nil, to: destination, password: nil,
                                 overwrite: .skip, flattenPaths: false)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("payload/readme.txt"),
                                  encoding: .utf8), "mine\n")
        try FileManager.default.removeItem(at: destination)

        destination = try occupiedDestination()
        try await engine.extract(archive: archive, entries: nil, to: destination, password: nil,
                                 overwrite: .renameNew, flattenPaths: false)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("payload/readme.txt"),
                                  encoding: .utf8), "mine\n")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("payload/readme 2.txt"),
                                  encoding: .utf8), "hello world\n")
        try FileManager.default.removeItem(at: destination)

        destination = try occupiedDestination()
        try await engine.extract(archive: archive, entries: nil, to: destination, password: nil,
                                 overwrite: .renameExisting, flattenPaths: false)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("payload/readme.txt"),
                                  encoding: .utf8), "hello world\n")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("payload/readme 2.txt"),
                                  encoding: .utf8), "mine\n")
    }

    func testACancelledExtractionLeavesNothingHalfWritten() async throws {
        let (fixture, archive) = try await FixtureBuilder.makeArchive(named: "cancel.7z")
        defer { FixtureBuilder.cleanup(fixture) }
        let destination = try occupiedDestination()
        let before = everything(under: destination)
        let token = CancellationToken()
        token.cancel()
        do {
            try await engine.extract(archive: archive, entries: nil, to: destination, password: nil,
                                     overwrite: .overwrite, flattenPaths: false, cancellation: token)
            XCTFail("a cancelled extraction should throw")
        } catch let error as ArchiveError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertEqual(everything(under: destination), before)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("payload/readme.txt"),
                                  encoding: .utf8), "mine\n")
    }

    // MARK: - Hostile archives

    func testAPathThousandsOfFoldersDeepFailsWithoutCrashing() async throws {
        try python("""
        import zipfile
        with zipfile.ZipFile('deep.zip', 'w') as z:
            z.writestr('a/' * 3000 + 'f', 'x')
        """)
        do {
            try await engine.extract(archive: root.appendingPathComponent("deep.zip"), entries: nil,
                                     to: root.appendingPathComponent("deep-out"), password: nil,
                                     overwrite: .overwrite, flattenPaths: false)
            XCTFail("a path longer than the system allows cannot have been created")
        } catch is ArchiveError {
            // Refused cleanly, which is all that is asked.
        }
    }

    func testSetuidBitsAreNotRestoredAndAModeOfZeroIsIgnored() async throws {
        try python("""
        import zipfile
        with zipfile.ZipFile('modes.zip', 'w') as z:
            a = zipfile.ZipInfo('setuid'); a.create_system = 3; a.external_attr = 0o104777 << 16
            z.writestr(a, 'x')
            b = zipfile.ZipInfo('nomode'); b.create_system = 3; b.external_attr = 0
            z.writestr(b, 'y')
            c = zipfile.ZipInfo('script.sh'); c.create_system = 3; c.external_attr = 0o100755 << 16
            z.writestr(c, 'z')
        """)
        let destination = root.appendingPathComponent("modes-out")
        try await engine.extract(archive: root.appendingPathComponent("modes.zip"), entries: nil, to: destination,
                                 password: nil, overwrite: .overwrite, flattenPaths: false)

        func mode(_ name: String) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent(name).path)
            return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
        XCTAssertEqual(try mode("setuid") & 0o7000, 0, "setuid survived extraction")
        XCTAssertEqual(try mode("setuid") & 0o002, 0, "world-writable despite the umask")
        XCTAssertNotEqual(try mode("nomode") & 0o400, 0, "the owner cannot read a file claiming mode 0")
        XCTAssertNotEqual(try mode("script.sh") & 0o100, 0, "the executable bit was lost")
    }

    func testALinkThatEscapesThroughAnotherLinkIsRefused() async throws {
        try python("""
        import tarfile, io
        with tarfile.open('chain.tar', 'w') as t:
            d = tarfile.TarInfo('d'); d.type = tarfile.DIRTYPE; d.mode = 0o755; t.addfile(d)
            l1 = tarfile.TarInfo('d/l1'); l1.type = tarfile.SYMTYPE; l1.linkname = '..'; t.addfile(l1)
            l2 = tarfile.TarInfo('l2'); l2.type = tarfile.SYMTYPE; l2.linkname = 'd/l1/../..'; t.addfile(l2)
            ok = tarfile.TarInfo('ok'); ok.type = tarfile.SYMTYPE; ok.linkname = 'd'; t.addfile(ok)
        """)
        let destination = root.appendingPathComponent("chain-out")
        try await engine.extract(archive: root.appendingPathComponent("chain.tar"), entries: nil, to: destination,
                                 password: nil, overwrite: .overwrite, flattenPaths: false)
        XCTAssertFalse(PathSafety.itemExists(at: destination.appendingPathComponent("l2")),
                       "a link resolving above the destination was created")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: destination.appendingPathComponent("ok").path), "d", "an innocent link was refused")
    }

    func testTarHardLinksGetTheirContents() async throws {
        let source = root.appendingPathComponent("links")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "shared\n".write(to: source.appendingPathComponent("orig.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(at: source.appendingPathComponent("orig.txt"),
                                         to: source.appendingPathComponent("hard.txt"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        tar.arguments = ["-cf", root.appendingPathComponent("hl.tar").path, "-C", source.path, "orig.txt", "hard.txt"]
        try tar.run()
        tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)

        let destination = root.appendingPathComponent("hl-out")
        try await engine.extract(archive: root.appendingPathComponent("hl.tar"), entries: nil, to: destination,
                                 password: nil, overwrite: .overwrite, flattenPaths: false)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("orig.txt"), encoding: .utf8), "shared\n")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("hard.txt"), encoding: .utf8), "shared\n",
                       "the hard link came out empty")
    }

    // MARK: - Editing an encrypted archive

    /// 7-Zip has to decode an encrypted solid block to take a file out of it.
    func testDeletingFromAnEncryptedSolidArchiveNeedsAndUsesThePassword() async throws {
        let (fixture, archive) = try await FixtureBuilder.makeArchive(named: "enc.7z",
                                                                     extraArguments: ["-psesame", "-ms=on"])
        defer { FixtureBuilder.cleanup(fixture) }
        let victim = ArchiveEntry(path: "payload/readme.txt", isDirectory: false)

        do {
            try await engine.delete(entries: [victim], from: archive, password: nil)
            XCTFail("deleting without the password should have been refused")
        } catch let error as ArchiveError {
            XCTAssertTrue(error.isPasswordProblem, "\(error) does not ask for a password")
        }
        do {
            try await engine.delete(entries: [victim], from: archive, password: "wrong")
            XCTFail("deleting with the wrong password should have been refused")
        } catch let error as ArchiveError {
            XCTAssertTrue(error.isPasswordProblem, "\(error) does not ask for a password")
        }

        try await engine.delete(entries: [victim], from: archive, password: "sesame")
        let listing = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
        XCTAssertFalse(listing.entries.contains { $0.path == "payload/readme.txt" })
        let out = fixture.appendingPathComponent("after")
        try await engine.extract(archive: archive, entries: nil, to: out, password: "sesame",
                                 overwrite: .overwrite, flattenPaths: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("payload/docs/notes.txt").path))
    }
}
