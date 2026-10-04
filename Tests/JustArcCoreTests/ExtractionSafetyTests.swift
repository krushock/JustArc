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
        guard let walker = FileManager.default.enumerator(atPath: folder.path) else { return [] }
        return walker.compactMap { $0 as? String }.sorted()
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

    // MARK: - Cancelling undoes the extraction

    /// Enough files that a cancel from the progress callback lands partway through.
    private func bulkyZip() async throws -> URL {
        let bulk = root.appendingPathComponent("bulk")
        try FileManager.default.createDirectory(at: bulk.appendingPathComponent("sub"), withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: 256 * 1024)
        for index in 0..<400 {
            for offset in stride(from: 0, to: bytes.count, by: 97) { bytes[offset] = UInt8.random(in: 0...255) }
            let name = String(format: "file-%03d.bin", index)
            try Data(bytes).write(to: bulk.appendingPathComponent(index % 2 == 0 ? name : "sub/\(name)"))
        }
        let archive = root.appendingPathComponent("bulk.zip")
        try await engine.create(archive: archive, items: [bulk], options: CompressionOptions(formatKey: "zip", level: 0))
        return archive
    }

    private final class CancelAfter: @unchecked Sendable {
        let token = CancellationToken()
        private let lock = NSLock()
        private var calls = 0
        private let limit: Int
        init(_ limit: Int) { self.limit = limit }
        func note() {
            lock.lock(); calls += 1; let reached = calls >= limit; lock.unlock()
            if reached { token.cancel() }
        }
    }

    func testCancellingPartwayRemovesWhatHadBeenExtracted() async throws {
        let archive = try await bulkyZip()
        let destination = root.appendingPathComponent("cancelled")
        let canceller = CancelAfter(2)
        do {
            try await engine.extract(archive: archive, entries: nil, to: destination, password: nil,
                                     overwrite: .renameNew, flattenPaths: false,
                                     cancellation: canceller.token, progress: { _ in canceller.note() })
            XCTFail("the extraction finished before it could be cancelled; make the fixture larger")
        } catch let error as ArchiveError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertEqual(everything(under: destination), [], "files extracted before the cancel were left behind")
    }

    func testCancellingARestoresFilesThatHadAlreadyBeenReplaced() async throws {
        let archive = try await bulkyZip()
        let destination = root.appendingPathComponent("occupied")
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("bulk/sub"),
                                                withIntermediateDirectories: true)
        // The files the archive writes first, already there with other contents.
        var mine: [URL] = []
        for index in 0..<400 where index % 40 == 0 {
            let url = destination.appendingPathComponent(String(format: "bulk/file-%03d.bin", index))
            try "mine \(index)\n".write(to: url, atomically: true, encoding: .utf8)
            mine.append(url)
        }
        let before = everything(under: destination)

        for mode in [OverwriteMode.overwrite, .renameExisting] {
            let canceller = CancelAfter(2)
            do {
                try await engine.extract(archive: archive, entries: nil, to: destination, password: nil,
                                         overwrite: mode, flattenPaths: false,
                                         cancellation: canceller.token, progress: { _ in canceller.note() })
                XCTFail("\(mode): the extraction finished before it could be cancelled")
            } catch let error as ArchiveError {
                XCTAssertEqual(error, .cancelled)
            }
            XCTAssertEqual(everything(under: destination), before, "\(mode): the folder is not as it was")
            for (offset, url) in mine.enumerated() {
                XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "mine \(offset * 40)\n",
                               "\(mode): \(url.lastPathComponent) was not put back")
            }
        }
    }

    // MARK: - Names that cannot both exist on disk

    func testAFileAndAFolderOfOneNameAreBothExtracted() async throws {
        try python("""
        import zipfile
        with zipfile.ZipFile('file-first.zip', 'w') as z:
            z.writestr('name', 'the file')
            z.writestr('name/child.txt', 'the child')
        with zipfile.ZipFile('folder-first.zip', 'w') as z:
            z.writestr('name/child.txt', 'the child')
            z.writestr('name', 'the file')
        """)
        for (archive, file, child) in [("file-first.zip", "name", "name 2/child.txt"),
                                       ("folder-first.zip", "name 2", "name/child.txt")] {
            let destination = root.appendingPathComponent("out-" + archive)
            try await engine.extract(archive: root.appendingPathComponent(archive), entries: nil, to: destination,
                                     password: nil, overwrite: .overwrite, flattenPaths: false)
            XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent(file), encoding: .utf8),
                           "the file", archive)
            XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent(child), encoding: .utf8),
                           "the child", archive)
        }
    }

    func testAFileIsNeverWrittenOverAFolderThatWasAlreadyThere() async throws {
        try python("""
        import zipfile
        with zipfile.ZipFile('clash.zip', 'w') as z:
            z.writestr('docs', 'a file called docs')
        """)
        let destination = root.appendingPathComponent("has-folder")
        let kept = destination.appendingPathComponent("docs/kept.txt")
        try FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "kept\n".write(to: kept, atomically: true, encoding: .utf8)

        try await engine.extract(archive: root.appendingPathComponent("clash.zip"), entries: nil, to: destination,
                                 password: nil, overwrite: .overwrite, flattenPaths: false)
        XCTAssertEqual(try String(contentsOf: kept, encoding: .utf8), "kept\n")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("docs 2"), encoding: .utf8),
                       "a file called docs")
    }

    // MARK: - Damage is not a wrong password

    func testADamagedEncryptedZipIsReportedAsDamaged() async throws {
        let big = root.appendingPathComponent("payload/big.bin")
        try Data(repeating: 0x41, count: 200_000).write(to: big)
        let archive = root.appendingPathComponent("damaged.zip")
        try await engine.create(archive: archive, items: [big],
                                options: CompressionOptions(formatKey: "zip", level: 0, password: "sesame"))
        // Flip bytes in the middle of the stored, encrypted data.
        var data = try Data(contentsOf: archive)
        for offset in 100_000..<100_016 { data[offset] ^= 0xFF }
        try data.write(to: archive)

        do {
            try await engine.extract(archive: archive, entries: nil, to: root.appendingPathComponent("damaged-out"),
                                     password: "sesame", overwrite: .overwrite, flattenPaths: false)
            XCTFail("damaged data was accepted")
        } catch let error as ArchiveError {
            XCTAssertFalse(error.isPasswordProblem,
                           "the right password was called wrong; the user would be asked for it for ever")
        }
        // The wrong password is still called what it is.
        do {
            try await engine.extract(archive: archive, entries: nil, to: root.appendingPathComponent("damaged-out"),
                                     password: "nope", overwrite: .overwrite, flattenPaths: false)
            XCTFail("the wrong password was accepted")
        } catch let error as ArchiveError {
            XCTAssertTrue(error.isPasswordProblem, "\(error)")
        }
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
            // Refused cleanly, and before a chain of folders was started.
        }
        XCTAssertTrue(everything(under: root.appendingPathComponent("deep-out")).isEmpty)
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
