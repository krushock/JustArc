import XCTest
@testable import JustArcCore

/// Second-pass review: engines, disk images and the extraction runner.
/// Each test asserts the behaviour a user would expect; a failure is a finding.
final class SecondPassEngineTests: XCTestCase {
    private let engine = SevenZipEngine()
    private let dmg = DMGEngine()
    private var root: URL!
    private var images: [URL] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("justarc-review2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for image in images { dmg.release(archive: image) }
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ text: String, _ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func paths(in archive: URL) async throws -> [String] {
        try await EngineFactory.engine(for: archive)
            .list(archive: archive, password: nil, encodingCodePage: nil).entries.map(\.path).sorted()
    }

    private func image(_ name: String) -> URL {
        let url = root.appendingPathComponent(name)
        images.append(url)
        return url
    }

    private func hdiutil(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = EngineLocator.hdiutil
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, text)
    }

    // MARK: - E1: adding to a large archive

    func testAddingManyFilesToALargeArchiveScales() async throws {
        func measure(existing: Int, added: Int) async throws -> Double {
            let base = root.appendingPathComponent("big-\(existing)")
            let old = base.appendingPathComponent("old")
            let new = base.appendingPathComponent("new")
            try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
            for index in 0..<existing {
                FileManager.default.createFile(atPath: old.appendingPathComponent("f\(index).txt").path, contents: Data())
            }
            for index in 0..<added {
                FileManager.default.createFile(atPath: new.appendingPathComponent("n\(index).txt").path, contents: Data())
            }
            let archive = base.appendingPathComponent("big.zip")
            try await engine.create(archive: archive, items: [old], options: CompressionOptions(formatKey: "zip", level: 0))
            let start = Date()
            try await engine.add(items: [new], to: archive, into: "", options: CompressionOptions(formatKey: "zip", level: 0),
                                 cancellation: nil, progress: nil)
            return Date().timeIntervalSince(start)
        }
        let small = try await measure(existing: 10_000, added: 1_000)
        let large = try await measure(existing: 40_000, added: 4_000)
        print(String(format: "E1 add: 1k into 10k took %.2fs; 4k into 40k took %.2fs", small, large))
        XCTAssertLessThan(large, small * 8, "four times the input took more than eight times as long")
    }

    // MARK: - E2: renaming to a name the list hides

    func testRenamingToADotUnderscoreNameDoesNotMakeTheFileVanish() async throws {
        let (fixture, archive) = try await FixtureBuilder.makeArchive(named: "hide.zip")
        defer { FixtureBuilder.cleanup(fixture) }
        let listing = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
        let readme = try XCTUnwrap(listing.entries.first { $0.path == "payload/readme.txt" })
        do {
            try await engine.rename(entry: readme, to: "payload/._readme.txt", in: archive, password: nil)
        } catch {
            print("E2 refused:", error.localizedDescription)
            return
        }
        let after = try await paths(in: archive)
        print("E2 after rename:", after)
        XCTAssertTrue(after.contains { $0.hasSuffix("readme.txt") },
                      "the renamed file is no longer listed, and so cannot be extracted or renamed back")
    }

    // MARK: - E5: the unwrapped-tar cache under concurrent use

    func testConcurrentUseOfACompressedTar() async throws {
        let (fixture, archive) = try await FixtureBuilder.makeArchive(named: "plain.tar")
        defer { FixtureBuilder.cleanup(fixture) }
        let gz = fixture.appendingPathComponent("plain.tar.gz")
        _ = try await FixtureBuilder.run(["a", gz.path, archive.path], in: fixture)
        let unwrapped = FileManager.default.temporaryDirectory.appendingPathComponent("JustArc-Unwrapped")
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: unwrapped.path)) ?? [])

        let failures = await withTaskGroup(of: String?.self) { group -> [String] in
            for index in 0..<40 {
                group.addTask { [engine, root] in
                    do {
                        switch index % 4 {
                        case 0:
                            let listing = try await engine.list(archive: gz, password: nil, encodingCodePage: nil)
                            if listing.entries.count != 5 { return "list gave \(listing.entries.count) entries" }
                        case 1:
                            try await engine.extract(archive: gz, entries: nil,
                                                     to: root!.appendingPathComponent("o\(index)"), password: nil,
                                                     overwrite: .overwrite, flattenPaths: false)
                        case 2:
                            engine.release(archive: gz)
                        default:
                            _ = try await engine.test(archive: gz, password: nil)
                        }
                        return nil
                    } catch {
                        return "task \(index): \(error.localizedDescription)"
                    }
                }
            }
            var all: [String] = []
            for await failure in group { if let failure { all.append(failure) } }
            return all
        }
        engine.release(archive: gz)
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: unwrapped.path)) ?? [])
        print("E5 failures:", failures, "leaked folders:", after.subtracting(before).count)
        XCTAssertTrue(failures.isEmpty, "\(failures)")
        XCTAssertTrue(after.subtracting(before).isEmpty, "unwrapped tars were left behind")
    }

    // MARK: - D1: an image the user already has mounted

    func testReleasingDoesNotDetachAnImageTheUserMountedThemselves() async throws {
        try write("hello\n", "src/hello.txt")
        let archive = image("mounted.dmg")
        try await dmg.create(archive: archive, items: [root.appendingPathComponent("src")],
                             options: CompressionOptions(formatKey: "dmg", level: 1))

        // The user double-clicked it in the Finder earlier.
        let theirs = root.appendingPathComponent("their-mount")
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        let attached = hdiutil(["attach", archive.path, "-plist", "-nobrowse", "-readonly", "-mountroot", theirs.path])
        XCTAssertEqual(attached.status, 0)
        let (device, mounts) = DMGEngine.parseAttachOutput(attached.output)
        defer { if let device { _ = hdiutil(["detach", device, "-force"]) } }
        let theirFile = try XCTUnwrap(mounts.first).appendingPathComponent("src/hello.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: theirFile.path))

        let listing: ArchiveListing
        do {
            listing = try await dmg.list(archive: archive, password: nil, encodingCodePage: nil)
        } catch {
            XCTFail("D1 an image that is already mounted elsewhere cannot be opened at all: \(error.localizedDescription)")
            return
        }
        let ours = DMGMountRegistry.shared.existing(for: archive)
        print("D1 their device:", device ?? "nil", "their mounts:", mounts.map(\.path))
        print("D1 JustArc registered:", ours?.devEntry ?? "nil", ours?.mountPoints.map(\.path) ?? [],
              "entries:", listing.entries.count)

        dmg.release(archive: archive)   // the window closes
        XCTAssertTrue(FileManager.default.fileExists(atPath: theirFile.path),
                      "closing the JustArc window detached the volume the user had mounted")
    }

    // MARK: - D2: two attaches at once

    func testListingTheSameImageTwiceAtOnce() async throws {
        try write("hello\n", "src/hello.txt")
        try write("more\n", "src/sub/more.txt")
        let archive = image("race.dmg")
        try await dmg.create(archive: archive, items: [root.appendingPathComponent("src")],
                             options: CompressionOptions(formatKey: "dmg", level: 1))
        dmg.release(archive: archive)

        var counts: [String] = []
        for round in 0..<3 {
            async let a = Result { try await self.dmg.list(archive: archive, password: nil, encodingCodePage: nil).entries.count }
            async let b = Result { try await self.dmg.list(archive: archive, password: nil, encodingCodePage: nil).entries.count }
            async let c = Result { try await self.dmg.list(archive: archive, password: nil, encodingCodePage: nil).entries.count }
            let results = await [a, b, c]
            counts.append("round \(round): " + results.map { result -> String in
                switch result {
                case .success(let count): return "\(count)"
                case .failure(let error): return "error(\(error.localizedDescription))"
                }
            }.joined(separator: ", "))
            let held = DMGMountRegistry.shared.existing(for: archive)
            let alive = held?.mountPoints.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } ?? false
            counts.append("  registered mount still there: \(alive)")
            dmg.release(archive: archive)
        }
        print("D2", counts.joined(separator: "\n"))
        XCTAssertFalse(counts.contains { $0.contains("error") || $0.contains(": 0") || $0.contains(", 0") || $0.contains("false") },
                       counts.joined(separator: "\n"))
    }

    // MARK: - D3: a link whose target is not there

    func testExtractingASelectionKeepsALinkWithNoTarget() async throws {
        try write("hello\n", "src/hello.txt")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("src/dangling").path,
                                                   withDestinationPath: "/Library/NoSuchThing-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("src/apps").path,
                                                   withDestinationPath: "/Applications")
        let archive = image("links.dmg")
        try await dmg.create(archive: archive, items: [root.appendingPathComponent("src")],
                             options: CompressionOptions(formatKey: "dmg", level: 1))
        let listing = try await dmg.list(archive: archive, password: nil, encodingCodePage: nil)
        print("D3 listed:", listing.entries.map(\.path).sorted())

        let out = root.appendingPathComponent("out")
        // What the window passes for a selected folder: the folder and everything in it.
        try await dmg.extract(archive: archive, entries: listing.entries, to: out, password: nil,
                              overwrite: .renameNew, flattenPaths: false, cancellation: nil, progress: nil)
        let produced = (try? FileManager.default.contentsOfDirectory(atPath: out.appendingPathComponent("src").path))?.sorted() ?? []
        print("D3 extracted:", produced)
        XCTAssertTrue(produced.contains("apps"))
        XCTAssertTrue(produced.contains("dangling"), "the link was listed but silently not extracted: \(produced)")
    }

    func testALinkWithNoTargetIsListedWhereItIs() async throws {
        try write("hello\n", "src/hello.txt")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("src/dangling").path,
                                                   withDestinationPath: "nowhere/at/all")
        let archive = image("listing.dmg")
        try await dmg.create(archive: archive, items: [root.appendingPathComponent("src")],
                             options: CompressionOptions(formatKey: "dmg", level: 1))
        let listed = try await paths(in: archive)
        print("D3b listed:", listed)
        XCTAssertEqual(listed, ["src", "src/dangling", "src/hello.txt"])

        let out = root.appendingPathComponent("whole")
        try await dmg.extract(archive: archive, entries: nil, to: out, password: nil,
                              overwrite: .renameNew, flattenPaths: false, cancellation: nil, progress: nil)
        let produced = (try? FileManager.default.contentsOfDirectory(atPath: out.appendingPathComponent("src").path))?.sorted() ?? []
        print("D3b whole-image extraction:", produced)
        XCTAssertEqual(produced, ["dangling", "hello.txt"])
    }

    // MARK: - D5: merging into a folder must not restamp it

    func testMergingADiskImageFolderLeavesTheExistingFoldersPermissionsAlone() async throws {
        try write("hello\n", "src/hello.txt")
        let archive = image("perm.dmg")
        try await dmg.create(archive: archive, items: [root.appendingPathComponent("src")],
                             options: CompressionOptions(formatKey: "dmg", level: 1))
        let out = root.appendingPathComponent("out")
        let existing = out.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: existing.path)
        try await dmg.extract(archive: archive, entries: nil, to: out, password: nil,
                              overwrite: .renameNew, flattenPaths: false, cancellation: nil, progress: nil)
        let mode = (try FileManager.default.attributesOfItem(atPath: existing.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        print(String(format: "D5 mode after merge: %o", mode))
        XCTAssertEqual(mode, 0o700, "the folder that was already there had its permissions replaced")
    }

    // MARK: - S6: converting to a disk image with a folder staged over one of the same name

    func testConvertingToADiskImageMergesAStagedFolderWithTheArchivesOwn() async throws {
        try write("old\n", "seed/docs/a.txt")
        let archive = root.appendingPathComponent("seed.zip")
        try await engine.create(archive: archive, items: [root.appendingPathComponent("seed/docs")],
                                options: CompressionOptions(formatKey: "zip"))
        try write("new\n", "drop/docs/b.txt")

        for name in ["merged.7z", "merged.dmg"] {
            let session = ArchiveSession(archiveURL: archive)
            try await session.load()
            session.stage(items: [root.appendingPathComponent("drop/docs")])
            let shown = session.visibleEntries.map(\.path).sorted()
            let destination = name.hasSuffix("dmg") ? image(name) : root.appendingPathComponent(name)
            try await session.save(to: destination,
                                   options: CompressionOptions(formatKey: name.hasSuffix("dmg") ? "dmg" : "7z", level: 1))
            let found = try await paths(in: destination)
            print("S6 \(name): shown \(shown) saved \(found)")
            XCTAssertEqual(found, shown, "\(name): the archive does not hold what the list showed")
        }
    }

    func testConvertingToADiskImageMergesAFolderStagedIntoASubfolder() async throws {
        try write("old\n", "seed/top/docs/sub/old.txt")
        let archive = root.appendingPathComponent("seed.zip")
        try await engine.create(archive: archive, items: [root.appendingPathComponent("seed/top")],
                                options: CompressionOptions(formatKey: "zip"))
        try write("new\n", "drop/sub/new.txt")

        for name in ["nested.7z", "nested.dmg"] {
            let session = ArchiveSession(archiveURL: archive)
            try await session.load()
            session.stage(items: [root.appendingPathComponent("drop/sub")], into: "top/docs")
            let shown = session.visibleEntries.map(\.path).sorted()
            let destination = name.hasSuffix("dmg") ? image(name) : root.appendingPathComponent(name)
            try await session.save(to: destination,
                                   options: CompressionOptions(formatKey: name.hasSuffix("dmg") ? "dmg" : "7z", level: 1))
            let found = try await paths(in: destination)
            print("S6b \(name): shown \(shown) saved \(found)")
            XCTAssertEqual(found, shown, "\(name): the archive does not hold what the list showed")
        }
    }

    func testConvertingToADiskImageWithAReplacedFileAndANestedAddition() async throws {
        try write("old\n", "seed/notes.txt")
        try write("d\n", "seed/docs/d.txt")
        let archive = root.appendingPathComponent("seed.zip")
        try await engine.create(archive: archive,
                                items: [root.appendingPathComponent("seed/notes.txt"), root.appendingPathComponent("seed/docs")],
                                options: CompressionOptions(formatKey: "zip"))
        let replacement = try write("new\n", "drop/notes.txt")
        let extra = try write("extra\n", "drop/extra.txt")

        let session = ArchiveSession(archiveURL: archive)
        try await session.load()
        session.stage(items: [replacement])
        session.stage(items: [extra], into: "docs")
        let destination = image("replaced.dmg")
        do {
            try await session.save(to: destination, options: CompressionOptions(formatKey: "dmg", level: 1))
        } catch {
            XCTFail("S6c the save failed: \(error.localizedDescription)")
            return
        }
        print("S6c saved:", try await paths(in: destination))
    }

    // MARK: - Saving a disk image over itself

    func testSavingADiskImageOverItself() async throws {
        try write("hello\n", "src/hello.txt")
        try write("deep\n", "src/sub/deep.txt")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/empty"), withIntermediateDirectories: true)
        let archive = image("self.dmg")
        try await dmg.create(archive: archive, items: [root.appendingPathComponent("src")],
                             options: CompressionOptions(formatKey: "dmg", level: 1))
        let extra = try write("extra\n", "extra.txt")
        let session = ArchiveSession(archiveURL: archive)
        try await session.load()
        var expected = Set(session.visibleEntries.map(\.path))
        session.stage(items: [extra], into: "src/sub")
        session.markForDeletion(["src/hello.txt"])
        expected.insert("src/sub/extra.txt")
        expected.remove("src/hello.txt")
        try await session.save(to: archive, options: CompressionOptions(formatKey: "dmg", level: 1))
        let found = Set(session.visibleEntries.map(\.path))
        print("DMGSELF missing:", expected.subtracting(found).sorted(), "unexpected:", found.subtracting(expected).sorted())
        XCTAssertEqual(found, expected)
        session.close()
        let attached = hdiutil(["info"]).output.components(separatedBy: "\n").filter { $0.contains("self.dmg") }
        print("DMGSELF still attached after close:", attached)
        XCTAssertTrue(attached.isEmpty)
        let mounts = ((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
            .filter { $0.hasPrefix("justarc-mount-") || $0.hasPrefix("justarc-dmg-") || $0.hasPrefix("justarc-save-") }
        print("DMGSELF temp leftovers:", mounts)
    }

    // MARK: - Another volume, with and without Unix semantics

    func testSavingOnOtherVolumes() async throws {
        let (fixture, seed) = try await FixtureBuilder.makeArchive(named: "seed.zip")
        defer { FixtureBuilder.cleanup(fixture) }
        var blob = Data(count: 400_000)
        blob.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, 400_000) }
        let big = root.appendingPathComponent("big.bin")
        try blob.write(to: big)

        for fileSystem in ["HFS+", "ExFAT", "MS-DOS FAT32"] {
            var report: [String] = []
            try await withScratchVolume(fileSystem: fileSystem, megabytes: 40) { volume in
                let archive = volume.appendingPathComponent("work.zip")
                try FileManager.default.copyItem(at: seed, to: archive)
                func listing() -> [String] {
                    ((try? FileManager.default.subpathsOfDirectory(atPath: volume.path)) ?? [])
                        .filter { !$0.hasPrefix(".fseventsd") && !$0.hasPrefix(".Spotlight") && !$0.hasPrefix(".Trashes") }.sorted()
                }
                do {
                    // In place: one deletion, one addition into a folder.
                    let session = ArchiveSession(archiveURL: archive)
                    try await session.load()
                    session.markForDeletion(["payload/readme.txt"])
                    session.stage(items: [big], into: "payload/docs")
                    try await session.save(to: archive, options: CompressionOptions(formatKey: "zip", level: 0))
                    report.append("in place ok: \(session.visibleEntries.map(\.path).sorted())")
                    report.append("  volume holds: \(listing())")

                    // Save As, from the boot volume's scratch onto this one, then over itself.
                    let converted = volume.appendingPathComponent("converted.7z")
                    try await session.save(to: converted, options: CompressionOptions(formatKey: "7z", level: 0))
                    try await session.save(to: converted, options: CompressionOptions(formatKey: "7z", level: 0), rebuild: true)
                    report.append("save as ok: \(session.visibleEntries.count) entries")
                    report.append("  volume holds: \(listing())")

                    // Split, twice, the second time with larger volumes so fewer are written.
                    let split = volume.appendingPathComponent("split.7z")
                    try await session.save(to: split, options: CompressionOptions(formatKey: "7z", level: 0, volumeSize: "100k"))
                    try await session.save(to: split, options: CompressionOptions(formatKey: "7z", level: 0, volumeSize: "300k"))
                    report.append("split ok: opened as \(session.archiveURL?.lastPathComponent ?? "nil"), \(session.visibleEntries.count) entries")
                    report.append("  volume holds: \(listing())")
                    session.close()
                } catch {
                    report.append("FAILED: \(error.localizedDescription)")
                    report.append("  volume holds: \(listing())")
                }
            }
            print("VOL \(fileSystem)\n  " + report.joined(separator: "\n  "))
            XCTAssertFalse(report.contains { $0.hasPrefix("FAILED") }, "\(fileSystem): \(report)")
        }
    }

    // MARK: - X1: which item was just extracted

    func testAnExistingFolderIsStillRevealedWhenTheArchiveAlsoHoldsItsNumberedTwin() async throws {
        try write("d\n", "seed/Docs/d.txt")
        try write("e\n", "seed/Docs 2/e.txt")
        let archive = root.appendingPathComponent("twins.zip")
        try await engine.create(archive: archive,
                                items: [root.appendingPathComponent("seed/Docs"), root.appendingPathComponent("seed/Docs 2")],
                                options: CompressionOptions(formatKey: "zip"))
        let listing = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
        let out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out.appendingPathComponent("Docs"), withIntermediateDirectories: true)

        let job = ExtractionJob(archive: archive, destination: out, allEntries: listing.entries,
                                roots: ["Docs", "Docs 2"], folderConflicts: ["Docs"],
                                folderResolution: .merge, fileOverwrite: .renameNew)
        let outcome = try await ExtractionRunner.run(job, engine: engine)
        let revealed = outcome.producedItems.map(\.lastPathComponent).sorted()
        print("X1 revealed:", revealed)
        XCTAssertEqual(revealed, ["Docs", "Docs 2"])
    }

    // MARK: - X2: a file in the archive, a folder of that name at the destination

    func testAFolderInTheWayOfAFileIsNotOfferedForReplacement() throws {
        let out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try "mine\n".write(to: out.appendingPathComponent("notes/mine.txt"), atomically: true, encoding: .utf8)
        // The archive holds a single FILE called "notes".
        let entries = [ArchiveEntry(path: "notes", isDirectory: false, size: 3)]
        let report = ExtractionConflicts.find(entries: entries, roots: ["notes"], in: out)
        print("X2 folders:", report.folders, "files:", report.files)
        XCTAssertTrue(report.folders.isEmpty,
                      "a folder conflict is reported for a file; answering Replace moves the whole folder to the Trash for it")
    }

    // MARK: - X4: Replace, then the extraction does not happen
    //
    // Run on a small read-write disk image of its own, so that "move to the Trash"
    // lands in that volume's Trash and nothing of the user's is touched.

    private func withScratchVolume(fileSystem: String = "HFS+", megabytes: Int = 8,
                                   _ body: (URL) async throws -> Void) async throws {
        let box = root.appendingPathComponent("box-\(UUID().uuidString.prefix(4)).dmg")
        XCTAssertEqual(hdiutil(["create", "-size", "\(megabytes)m", "-fs", fileSystem, "-volname", "Box", box.path]).status, 0)
        let mountRoot = root.appendingPathComponent("boxmount")
        try FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true)
        let attached = hdiutil(["attach", box.path, "-plist", "-nobrowse", "-mountroot", mountRoot.path])
        let (device, mounts) = DMGEngine.parseAttachOutput(attached.output)
        defer { if let device { _ = hdiutil(["detach", device, "-force"]) } }
        try await body(try XCTUnwrap(mounts.first))
    }

    private func everything(under folder: URL) -> [String] {
        ((try? FileManager.default.subpathsOfDirectory(atPath: folder.path)) ?? [])
            .filter { !$0.hasPrefix(".fseventsd") && !$0.hasPrefix(".Spotlight") && $0 != ".DS_Store" }.sorted()
    }

    func testReplaceDoesNotGiveUpTheFolderWhenNothingIsExtracted() async throws {
        let (fixture, archive) = try await FixtureBuilder.makeArchive(named: "locked.zip", extraArguments: ["-psecret"])
        defer { FixtureBuilder.cleanup(fixture) }
        let listing = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
        try await withScratchVolume { volume in
            for attempt in ["no password", "cancelled"] {
                let out = volume.appendingPathComponent("out-\(attempt.prefix(2))")
                let mine = out.appendingPathComponent("payload/mine.txt")
                try FileManager.default.createDirectory(at: mine.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "mine\n".write(to: mine, atomically: true, encoding: .utf8)
                let token = CancellationToken()
                if attempt == "cancelled" { token.cancel() }
                let job = ExtractionJob(archive: archive, destination: out,
                                        password: attempt == "cancelled" ? "secret" : nil,
                                        allEntries: listing.entries, roots: ["payload"],
                                        folderConflicts: ["payload"], folderResolution: .replace, fileOverwrite: .overwrite)
                do {
                    _ = try await ExtractionRunner.run(job, engine: self.engine, cancellation: token)
                    XCTFail("X4 \(attempt): should not have succeeded")
                } catch {
                    print("X4 \(attempt): failed with:", error.localizedDescription)
                }
                print("X4 \(attempt): destination now holds:", self.everything(under: out))
                XCTAssertTrue(FileManager.default.fileExists(atPath: mine.path),
                              "\(attempt): nothing was extracted, and the folder that was there is gone")
            }
            print("X4 volume now holds:", self.everything(under: volume).filter { $0.contains("Trash") })
        }
    }

    func testWhereTheScratchVolumesTrashIs() async throws {
        try await withScratchVolume { volume in
            let probe = volume.appendingPathComponent("justarc-review2-probe")
            try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
            var result: NSURL?
            try FileManager.default.trashItem(at: probe, resultingItemURL: &result)
            print("TRASH probe went to:", result?.path ?? "nil")
            XCTAssertTrue(result?.path?.hasPrefix(volume.path) == true || result?.path?.contains("/boxmount/") == true)
        }
    }

    func testReplaceNeverTrashesAFolderForAFile() async throws {
        let file = try write("a file\n", "seed/notes")
        let archive = root.appendingPathComponent("file.zip")
        try await engine.create(archive: archive, items: [file], options: CompressionOptions(formatKey: "zip"))
        let listing = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
        try await withScratchVolume { volume in
            let out = volume.appendingPathComponent("out")
            let mine = out.appendingPathComponent("notes/mine.txt")
            try FileManager.default.createDirectory(at: mine.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "mine\n".write(to: mine, atomically: true, encoding: .utf8)
            // What the window does: ask, then run with the answer.
            let report = ExtractionConflicts.find(entries: listing.entries, roots: ["notes"], in: out)
            let job = ExtractionJob(archive: archive, destination: out, allEntries: listing.entries, roots: ["notes"],
                                    folderConflicts: report.folders, folderResolution: .replace, fileOverwrite: .overwrite)
            let outcome = try? await ExtractionRunner.run(job, engine: self.engine)
            print("X2b conflicts:", report.folders, "trashed:", outcome?.trashedFolders ?? [],
                  "destination now holds:", self.everything(under: out))
            XCTAssertTrue(FileManager.default.fileExists(atPath: mine.path),
                          "a folder was moved to the Trash to make room for a file")
        }
    }

    // MARK: - X3: Keep Both for a folder picked from inside another

    func testKeepBothForANestedSelectionKeepsBothAtThatLevel() async throws {
        let (fixture, archive) = try await FixtureBuilder.makeArchive(named: "nested.zip")
        defer { FixtureBuilder.cleanup(fixture) }
        let listing = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
        let out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out.appendingPathComponent("payload/docs"), withIntermediateDirectories: true)
        try "mine\n".write(to: out.appendingPathComponent("payload/mine.txt"), atomically: true, encoding: .utf8)

        // The user is inside "payload" and extracts "docs".
        let selected = listing.entries.filter { $0.path == "payload/docs" || $0.path.hasPrefix("payload/docs/") }
        let job = ExtractionJob(archive: archive, destination: out, allEntries: listing.entries,
                                selectedEntries: selected, roots: ["payload/docs"],
                                folderConflicts: ["payload/docs"], folderResolution: .keepBoth,
                                fileOverwrite: .renameNew)
        let outcome = try await ExtractionRunner.run(job, engine: engine)
        let top = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
        let inside = try FileManager.default.contentsOfDirectory(atPath: out.appendingPathComponent("payload").path).sorted()
        print("X3 top level:", top, "inside payload:", inside, "revealed:", outcome.producedItems.map(\.path))
        XCTAssertEqual(top, ["payload"], "a second copy of the parent folder appeared at the top")
        XCTAssertTrue(inside.contains("docs 2"), "\(inside)")
    }

    // MARK: - W1: wording

    func testAnItemNameWithAColonIsStillTranslated() {
        let plain = BridgeError.localized("draft.txt: the data is damaged")
        let colon = BridgeError.localized("Notes: draft.txt: the data is damaged")
        let masquerade = BridgeError.localized("Cannot open the door.txt: the data is damaged")
        let whole = BridgeError.localized("The password is incorrect.: the data is damaged")
        print("W1 plain:", plain)
        print("W1 colon:", colon)
        print("W1 masquerade:", masquerade)
        print("W1 whole:", whole)
        XCTAssertTrue(colon.contains("could not be extracted"), colon)
        XCTAssertTrue(masquerade.contains("could not be extracted"), masquerade)
    }
}

private extension Result where Failure == Error {
    init(_ body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
