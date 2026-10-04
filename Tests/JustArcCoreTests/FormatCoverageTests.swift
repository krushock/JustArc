import XCTest
@testable import JustArcCore

/// Opens and extracts one archive of every kind that can be made on this Mac with
/// the system's own tools, so the list of supported formats is a tested claim.
final class FormatCoverageTests: XCTestCase {
    private var root: URL!
    private var source: URL { root.appendingPathComponent("Project") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("justarc-formats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("docs"),
                                                withIntermediateDirectories: true)
        try "hello\n".write(to: source.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        try String(repeating: "notes ", count: 2000)
            .write(to: source.appendingPathComponent("docs/notes.txt"), atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String], in directory: URL? = nil,
                     stdin: Data? = nil, stdout: URL? = nil) throws -> Int32 {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: tool), "\(tool) is not installed")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = directory ?? root
        let input = Pipe()
        if stdin != nil { process.standardInput = input }
        if let stdout {
            FileManager.default.createFile(atPath: stdout.path, contents: nil)
            process.standardOutput = try FileHandle(forWritingTo: stdout)
        } else {
            process.standardOutput = Pipe()
        }
        process.standardError = Pipe()
        try process.run()
        if let stdin {
            input.fileHandleForWriting.write(stdin)
            try input.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Lists and extracts `archive`, and checks that the two files came through.
    /// - Parameter prefix: the folder the files sit in inside the archive.
    private func check(_ archive: URL, prefix: String = "Project/", password: String? = nil,
                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let name = archive.lastPathComponent
        XCTAssertNotNil(FormatRegistry.format(for: archive), "\(name) is not a format the app claims",
                        file: file, line: line)
        let engine = EngineFactory.engine(for: archive)
        defer { engine.release(archive: archive) }

        let listing = try await engine.list(archive: archive, password: password, encodingCodePage: nil)
        let paths = Set(listing.entries.map(\.path))
        XCTAssertTrue(paths.contains(prefix + "readme.txt"), "\(name) lists \(paths.sorted())", file: file, line: line)
        XCTAssertTrue(paths.contains(prefix + "docs/notes.txt"), "\(name) lists \(paths.sorted())", file: file, line: line)

        let destination = root.appendingPathComponent("out-\(name)")
        try await engine.extract(archive: archive, entries: nil, to: destination, password: password,
                                 overwrite: .overwrite, flattenPaths: false, cancellation: nil, progress: nil)
        XCTAssertEqual(try? String(contentsOf: destination.appendingPathComponent(prefix + "readme.txt"), encoding: .utf8),
                       "hello\n", "\(name) extracted wrongly", file: file, line: line)
        XCTAssertEqual((try? Data(contentsOf: destination.appendingPathComponent(prefix + "docs/notes.txt")))?.count,
                       12_000, "\(name) extracted wrongly", file: file, line: line)

        // One entry on its own, which is what opening or previewing a file does.
        let entry = try XCTUnwrap(listing.entries.first { $0.path == prefix + "docs/notes.txt" }, file: file, line: line)
        let single = try await engine.extractSingle(archive: archive, entry: entry,
                                                    to: root.appendingPathComponent("single-\(name)"),
                                                    password: password, cancellation: nil)
        XCTAssertEqual((try? Data(contentsOf: single))?.count, 12_000, "\(name): single entry", file: file, line: line)
    }

    private func path(_ name: String) -> URL { root.appendingPathComponent(name) }

    // MARK: - What the system's own tools write

    func testZipFromTheZipTool() async throws {
        try run("/usr/bin/zip", ["-r", "-q", "plain.zip", "Project"])
        try await check(path("plain.zip"))
    }

    func testZipFromTheFinder() async throws {
        // ditto is what the Finder's Compress uses, __MACOSX and all.
        try run("/usr/bin/xattr", ["-w", "com.example.note", "x", source.appendingPathComponent("readme.txt").path])
        try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", "Project", "finder.zip"])
        try await check(path("finder.zip"))
    }

    func testEncryptedZipFromTheZipTool() async throws {
        try run("/usr/bin/zip", ["-r", "-q", "-P", "sesame", "secret.zip", "Project"])
        let engine = SevenZipEngine()
        let listing = try await engine.list(archive: path("secret.zip"), password: nil, encodingCodePage: nil)
        XCTAssertTrue(listing.containsEncryptedEntries)
        do {
            try await engine.extract(archive: path("secret.zip"), entries: nil, to: path("nope"), password: nil,
                                     overwrite: .overwrite, flattenPaths: false)
            XCTFail("extracted without the password")
        } catch let error as ArchiveError {
            XCTAssertEqual(error, .passwordRequired)
        }
        try await check(path("secret.zip"), password: "sesame")
    }

    func testSplitZipOpensThroughItsLastPart() async throws {
        var bytes = [UInt8](repeating: 0, count: 300 * 1024)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        try Data(bytes).write(to: source.appendingPathComponent("random.bin"))
        // zip writes split.z01, split.z02, … and split.zip last.
        try run("/usr/bin/zip", ["-r", "-q", "-s", "100k", "split.zip", "Project"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("split.z01").path))
        try await check(path("split.zip"))
        XCTAssertEqual(try Data(contentsOf: path("out-split.zip/Project/random.bin")), Data(bytes))
    }

    func testTarAndItsCompressedForms() async throws {
        for (name, flag) in [("plain.tar", "-cf"), ("gz.tar.gz", "-czf"), ("short.tgz", "-czf"),
                             ("bz.tar.bz2", "-cjf"), ("xz.tar.xz", "-cJf")] {
            try run("/usr/bin/bsdtar", [flag, name, "Project"])
            try await check(path(name))
        }
    }

    func testTarZstandard() async throws {
        try run("/usr/bin/bsdtar", ["-cf", "plain.tar", "Project"])
        try run("/opt/homebrew/bin/zstd", ["-q", "plain.tar", "-o", "z.tar.zst"])
        try await check(path("z.tar.zst"))
    }

    func testSingleFileCompressors() async throws {
        let notes = source.appendingPathComponent("docs/notes.txt")
        func verify(_ archive: URL, file: StaticString = #filePath, line: UInt = #line) async throws {
            let engine = EngineFactory.engine(for: archive)
            defer { engine.release(archive: archive) }
            let listing = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
            XCTAssertEqual(listing.entries.count, 1, archive.lastPathComponent, file: file, line: line)
            let out = root.appendingPathComponent("out-\(archive.lastPathComponent)")
            try await engine.extract(archive: archive, entries: nil, to: out, password: nil,
                                     overwrite: .overwrite, flattenPaths: false, cancellation: nil, progress: nil)
            let produced = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil).first)
            XCTAssertEqual(try Data(contentsOf: produced).count, 12_000, archive.lastPathComponent, file: file, line: line)
        }

        try run("/usr/bin/gzip", ["-k", "-c", notes.path], stdout: path("notes.txt.gz"))
        try await verify(path("notes.txt.gz"))
        try run("/usr/bin/bzip2", ["-k", "-c", notes.path], stdout: path("notes.txt.bz2"))
        try await verify(path("notes.txt.bz2"))
        try run("/usr/bin/compress", ["-c", notes.path], stdout: path("notes.txt.Z"))
        try await verify(path("notes.txt.Z"))
        _ = try await FixtureBuilder.run(["a", path("notes.txt.xz").path, notes.path], in: root)
        try await verify(path("notes.txt.xz"))
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/zstd") {
            try run("/opt/homebrew/bin/zstd", ["-q", notes.path, "-o", path("notes.txt.zst").path])
            try await verify(path("notes.txt.zst"))
        }
    }

    func testSevenZipAndWim() async throws {
        _ = try await FixtureBuilder.run(["a", path("made.7z").path, "Project"], in: root)
        try await check(path("made.7z"))
        _ = try await FixtureBuilder.run(["a", path("made.wim").path, "Project"], in: root)
        try await check(path("made.wim"))
    }

    func testRar() async throws {
        let rar = try XCTUnwrap(EngineLocator.externalRAR.map(\.path) ?? "/nonexistent")
        try run(rar, ["a", "-r", "-inul", "made.rar", "Project"])
        try await check(path("made.rar"))
        // And split across volumes, opened through the first.
        var bytes = [UInt8](repeating: 0, count: 300 * 1024)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        try Data(bytes).write(to: source.appendingPathComponent("random.bin"))
        try run(rar, ["a", "-r", "-inul", "-m0", "-v100k", "vol.rar", "Project"])
        try await check(path("vol.part1.rar"))
        XCTAssertEqual(try Data(contentsOf: path("out-vol.part1.rar/Project/random.bin")), Data(bytes))
    }

    func testCpio() async throws {
        let names = "Project\nProject/readme.txt\nProject/docs\nProject/docs/notes.txt\n"
        try run("/usr/bin/cpio", ["-o", "--quiet"], stdin: Data(names.utf8), stdout: path("made.cpio"))
        try await check(path("made.cpio"))
    }

    func testXarAndInstallerPackages() async throws {
        try run("/usr/bin/xar", ["-cf", "made.xar", "Project"])
        try await check(path("made.xar"))

        try run("/usr/bin/pkgbuild", ["--root", "Project", "--identifier", "com.example.test",
                                      "--install-location", "/tmp/nowhere", "--quiet", "made.pkg"])
        // A package is a xar holding a payload, not the files themselves; it should
        // open and show what is in it.
        let engine = EngineFactory.engine(for: path("made.pkg"))
        let listing = try await engine.list(archive: path("made.pkg"), password: nil, encodingCodePage: nil)
        XCTAssertTrue(listing.entries.contains { $0.name == "Payload" }, "\(listing.entries.map(\.path))")
    }

    func testIsoImage() async throws {
        try run("/usr/bin/hdiutil", ["makehybrid", "-quiet", "-iso", "-joliet", "-o", "made.iso", "Project"])
        // hdiutil puts the folder's contents at the top of the disc.
        try await check(path("made.iso"), prefix: "")
    }

    /// Writes an ar archive the way GNU ar does, which is what .deb packages and
    /// static libraries from Linux are. (macOS's own ar writes the BSD variant, with
    /// names moved into the data, which 7-Zip does not read: such a library opens as
    /// a single symbol listing.)
    private func writeAr(_ name: String, members: [(String, Data)]) throws {
        var data = Data("!<arch>\n".utf8)
        for (member, contents) in members {
            let header = (member + "/").padding(toLength: 16, withPad: " ", startingAt: 0)
                + "0".padding(toLength: 12, withPad: " ", startingAt: 0)
                + "0".padding(toLength: 6, withPad: " ", startingAt: 0)
                + "0".padding(toLength: 6, withPad: " ", startingAt: 0)
                + "100644".padding(toLength: 8, withPad: " ", startingAt: 0)
                + String(contents.count).padding(toLength: 10, withPad: " ", startingAt: 0)
                + "`\n"
            data.append(Data(header.utf8))
            data.append(contents)
            if contents.count % 2 == 1 { data.append(0x0A) }
        }
        try data.write(to: path(name))
    }

    func testUnixArchivesAndDebianPackages() async throws {
        try writeAr("made.a", members: [("readme.txt", Data("hello\n".utf8)), ("notes.txt", Data("notes".utf8))])
        let engine = EngineFactory.engine(for: path("made.a"))
        let listing = try await engine.list(archive: path("made.a"), password: nil, encodingCodePage: nil)
        XCTAssertTrue(listing.entries.contains { $0.name == "readme.txt" }, "\(listing.entries.map(\.path))")
        let out = path("out-a")
        try await engine.extract(archive: path("made.a"), entries: nil, to: out, password: nil,
                                 overwrite: .overwrite, flattenPaths: false, cancellation: nil, progress: nil)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("readme.txt"), encoding: .utf8), "hello\n")

        // A .deb is an ar archive of a version file and two tarballs.
        try run("/usr/bin/bsdtar", ["-czf", "control.tar.gz", "Project/readme.txt"])
        try run("/usr/bin/bsdtar", ["-czf", "data.tar.gz", "Project"])
        try writeAr("made.deb", members: [("debian-binary", Data("2.0\n".utf8)),
                                          ("control.tar.gz", try Data(contentsOf: path("control.tar.gz"))),
                                          ("data.tar.gz", try Data(contentsOf: path("data.tar.gz")))])
        let deb = EngineFactory.engine(for: path("made.deb"))
        let parts = try await deb.list(archive: path("made.deb"), password: nil, encodingCodePage: nil)
        XCTAssertEqual(Set(parts.entries.map(\.name)), ["debian-binary", "control.tar.gz", "data.tar.gz"])
    }

    // MARK: - Names

    /// Writes a zip whose one entry has `name` as raw bytes, made on "MS-DOS" and
    /// without the flag that says a name is UTF-8.
    private func writeLegacyZip(_ archive: String, nameHex: String) throws {
        try run("/usr/bin/python3", ["-c", """
        import zipfile
        raw = bytes.fromhex('\(nameHex)')
        placeholder = 'X' * len(raw)
        z = zipfile.ZipFile('\(archive)', 'w')
        info = zipfile.ZipInfo(placeholder)
        info.create_system = 0
        z.writestr(info, 'contents')
        z.close()
        data = open('\(archive)', 'rb').read().replace(placeholder.encode(), raw)
        open('\(archive)', 'wb').write(data)
        """])
    }

    private func hex(_ text: String, _ encoding: String.Encoding) -> String {
        (text.data(using: encoding) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }

    /// A zip from an old DOS or Windows tool: names in a code page, with nothing in
    /// the archive saying which. The Filename Encoding menu is for these.
    func testNamesInAnOldCodePageAreReadWithTheChosenEncoding() async throws {
        let cyrillic = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosRussian.rawValue))
        try writeLegacyZip("dos.zip", nameHex: hex("Привет.txt", String.Encoding(rawValue: cyrillic)))
        let engine = SevenZipEngine()
        let archive = path("dos.zip")

        let chosen = try await engine.list(archive: archive, password: nil, encodingCodePage: 866)
        XCTAssertEqual(chosen.entries.map(\.name), ["Привет.txt"])

        // Extraction has to read the names the way the list did.
        let out = path("out-dos")
        try await engine.extract(archive: archive, entries: chosen.entries, to: out, password: nil,
                                 overwrite: .overwrite, flattenPaths: false)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), ["Привет.txt"])
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("Привет.txt"), encoding: .utf8), "contents")

        // Read another way, the same bytes are other letters: the menu does something.
        let western = try await engine.list(archive: archive, password: nil, encodingCodePage: 437)
        XCTAssertNotEqual(western.entries.map(\.name), ["Привет.txt"])
        XCTAssertEqual(western.entries.first?.name.count, "Привет.txt".count)
        engine.release(archive: archive)
    }

    /// Left on Automatic, a name that is not UTF-8 is still turned into letters, and
    /// still extracts: macOS refuses to create a file whose name is not valid UTF-8.
    func testUndecodableNamesAreReadableAndExtractOnAutomatic() async throws {
        let western = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue))
        try writeLegacyZip("western.zip", nameHex: hex("café.txt", String.Encoding(rawValue: western)))
        let engine = SevenZipEngine()
        let listing = try await engine.list(archive: path("western.zip"), password: nil, encodingCodePage: nil)
        let name = try XCTUnwrap(listing.entries.first?.name)
        XCTAssertFalse(name.unicodeScalars.contains { (0xEF80...0xEFFF).contains($0.value) },
                       "the name still holds 7-Zip's markers for bytes it could not read")
        XCTAssertEqual(name.count, "café.txt".count)

        let out = path("out-western")
        try await engine.extract(archive: path("western.zip"), entries: nil, to: out, password: nil,
                                 overwrite: .overwrite, flattenPaths: false)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path).count, 1)
    }

    func testTheLikelyCodePageFollowsTheLanguage() {
        XCTAssertEqual(ArchiveTextEncoding.legacyCodePage(forLanguage: "ru-RU"), 866)
        XCTAssertEqual(ArchiveTextEncoding.legacyCodePage(forLanguage: "ja"), 932)
        XCTAssertEqual(ArchiveTextEncoding.legacyCodePage(forLanguage: "zh-Hant-TW"), 950)
        XCTAssertEqual(ArchiveTextEncoding.legacyCodePage(forLanguage: "zh-Hans-CN"), 936)
        XCTAssertEqual(ArchiveTextEncoding.legacyCodePage(forLanguage: "en-US"), 437)
    }

    /// The macOS zip tool, and most on Linux, write UTF-8 names without setting the
    /// flag that says so.
    func testUnflaggedUTF8NamesAreReadAsUTF8() async throws {
        let composed = "caf\u{00E9} Привет 日本.txt"
        try "x".write(to: source.appendingPathComponent(composed), atomically: true, encoding: .utf8)
        try run("/usr/bin/zip", ["-r", "-q", "accents.zip", "Project"])
        let engine = SevenZipEngine()
        let listing = try await engine.list(archive: path("accents.zip"), password: nil, encodingCodePage: nil)
        // Swift compares strings by canonical equivalence, so the decomposed form
        // the file system hands back counts as the same name.
        let entry = try XCTUnwrap(listing.entries.first { $0.name == composed },
                                  "\(listing.entries.map(\.name))")
        let single = try await engine.extractSingle(archive: path("accents.zip"), entry: entry,
                                                    to: path("out-accents"), password: nil)
        XCTAssertEqual(try String(contentsOf: single, encoding: .utf8), "x")
    }

    func testEveryFormatOfferedForSavingRoundTrips() async throws {
        for format in FormatRegistry.writable where format.engine == .sevenZip {
            let archive = path("saved.\(format.extensions[0])")
            let engine = EngineFactory.engine(for: archive)
            let single = ["gzip", "bzip2", "xz"].contains(format.key)
            let items = single ? [source.appendingPathComponent("docs/notes.txt")] : [source]
            try await engine.create(archive: archive, items: items,
                                    options: CompressionOptions(formatKey: format.key), cancellation: nil, progress: nil)
            if single {
                let listing = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
                XCTAssertEqual(listing.entries.count, 1, format.key)
            } else {
                try await check(archive)
            }
        }
    }
}
