import XCTest
@testable import JustArcCore

/// Second-pass review: RarEngine against RARLAB's real tool. Skipped when it is not installed.
final class SecondPassRarTests: XCTestCase {
    private let rar = RarEngine()
    private let reader = SevenZipEngine()
    private var root: URL!
    private let options = CompressionOptions(formatKey: "rar", level: 0)

    override func setUpWithError() throws {
        try XCTSkipIf(EngineLocator.externalRAR == nil, "rar is not installed")
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("justarc-review2-rar")
        root = scratch.appendingPathComponent("rar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let root {
            // Unreadable fixtures must be made removable again.
            _ = try? FileManager.default.subpathsOfDirectory(atPath: root.path).map {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent($0).path)
            }
            try? FileManager.default.removeItem(at: root)
        }
    }

    @discardableResult
    private func write(_ text: String, _ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @discardableResult
    private func random(_ bytes: Int, _ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, bytes) }
        try data.write(to: url)
        return url
    }

    private func paths(in archive: URL) async throws -> [String] {
        try await reader.list(archive: archive, password: nil, encodingCodePage: nil).entries.map(\.path).sorted()
    }

    private func text(of entry: String, in archive: URL) async throws -> String {
        let out = root.appendingPathComponent("x-\(UUID().uuidString)")
        try await reader.extract(archive: archive, entries: nil, to: out, password: nil,
                                 overwrite: .overwrite, flattenPaths: false)
        return try String(contentsOf: out.appendingPathComponent(entry), encoding: .utf8)
    }

    // MARK: R-a: a name is a name, not a pattern

    func testAddingAFileWhoseNameHasAWildcardAddsOnlyThatFile() async throws {
        let wanted = try write("wanted\n", "in/a?.txt")
        try write("sibling\n", "in/ab.txt")
        try write("sibling\n", "in/ac.txt")
        let star = try write("star\n", "in2/*")
        try write("other\n", "in2/other.txt")
        try write("deep\n", "in2/sub/deep.txt")

        let archive = root.appendingPathComponent("wild.rar")
        try await rar.create(archive: archive, items: [wanted], options: options)
        let found = try await paths(in: archive)
        print("R-a '?' added:", found)
        XCTAssertEqual(found, ["a?.txt"], "siblings matching the name as a pattern were added too")

        let second = root.appendingPathComponent("star.rar")
        try await rar.create(archive: second, items: [star], options: options)
        let foundStar = try await paths(in: second)
        print("R-a '*' added:", foundStar)
        XCTAssertEqual(foundStar, ["*"], "a file named * took its whole folder along")
    }

    // MARK: R-b: which of two same-named items wins

    func testTheLaterOfTwoItemsWithOneNameWins() async throws {
        var winners: [String] = []
        for round in 0..<6 {
            let first = try write("first\n", "r\(round)/one-\(UUID().uuidString.prefix(6))/notes.txt")
            let second = try write("second\n", "r\(round)/two-\(UUID().uuidString.prefix(6))/notes.txt")
            let archive = root.appendingPathComponent("order-\(round).rar")
            try await rar.create(archive: archive, items: [first, second], options: options)
            winners.append(try await text(of: "notes.txt", in: archive).trimmingCharacters(in: .newlines))
        }
        print("R-b winners:", winners)
        XCTAssertEqual(Set(winners), ["second"], "the earlier item sometimes wins: \(winners)")
    }

    // MARK: R-c: volumes, with items from more than one folder

    func testSplitVolumesHoldItemsFromEveryFolder() async throws {
        let one = try random(250_000, "p1/one.bin")
        let two = try random(250_000, "p2/two.bin")
        let folder = root.appendingPathComponent("vol")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let archive = folder.appendingPathComponent("set.rar")
        var split = options
        split.volumeSize = "100k"
        do {
            try await rar.create(archive: archive, items: [one, two], options: split)
        } catch {
            print("R-c create failed:", error.localizedDescription)
            let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
            XCTFail("R-c: saving two files from two folders as volumes failed: \(error.localizedDescription); left behind: \(files)")
            return
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        print("R-c files:", files)
        let first = folder.appendingPathComponent(files.first { $0.contains("part1") || $0.contains("part01") } ?? "set.rar")
        let found = try await paths(in: first)
        print("R-c entries via \(first.lastPathComponent):", found)
        XCTAssertEqual(found, ["one.bin", "two.bin"])
    }

    func testASessionSavedAsRarVolumesHoldsEverythingThatWasStaged() async throws {
        let one = try random(250_000, "q1/one.bin")
        let two = try random(250_000, "q2/two.bin")
        let folder = root.appendingPathComponent("vol2")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = ArchiveSession(archiveURL: nil)
        session.stage(items: [one, two])
        var split = options
        split.volumeSize = "100k"
        try await session.save(to: folder.appendingPathComponent("set.rar"), options: split)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        let shown = session.visibleEntries.map(\.path).sorted()
        print("R-c2 files:", files, "session shows after save:", shown)
        XCTAssertEqual(shown, ["one.bin", "two.bin"], "the save reported success and one of the files is not in the archive")
    }

    // MARK: R-d: deleting a name with a wildcard in it

    func testDeletingAnEntryWhoseNameHasAWildcardDeletesOnlyThatEntry() async throws {
        let a = try write("a\n", "d/what?.txt")
        let b = try write("b\n", "d/whats.txt")
        let c = try write("c\n", "d/whatx.txt")
        let keep = try write("k\n", "d2/keep.txt")
        let archive = root.appendingPathComponent("del.rar")
        try await rar.create(archive: archive, items: [b, c], options: options)
        try await rar.add(items: [keep], to: archive, options: options)
        try await rar.add(items: [a], to: archive, options: options)
        let before = try await paths(in: archive)
        try await rar.delete(entries: [ArchiveEntry(path: "what?.txt", isDirectory: false)], from: archive, password: nil)
        let after = try await paths(in: archive)
        print("R-d before:", before, "after deleting what?.txt:", after)
        XCTAssertEqual(after, before.filter { $0 != "what?.txt" }, "other entries were deleted with it")

        // The same through rename.
        try await rar.create(archive: archive, items: [b, c], options: options)
        try await rar.add(items: [keep], to: archive, options: options)
        try await rar.add(items: [a], to: archive, options: options)
        do {
            try await rar.rename(entry: ArchiveEntry(path: "what?.txt", isDirectory: false), to: "renamed.txt",
                                 in: archive, password: nil)
        } catch { print("R-d rename threw:", error.localizedDescription) }
        print("R-d after renaming what?.txt to renamed.txt:", try await paths(in: archive))
    }

    // MARK: R-e: a file that cannot be read

    func testAFileThatCannotBeReadFailsTheSave() async throws {
        let good = try write("good\n", "u/good.txt")
        let locked = try write("locked\n", "u/locked.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let archive = root.appendingPathComponent("unreadable.rar")
        do {
            try await rar.create(archive: archive, items: [good, locked], options: options)
            let found = try await paths(in: archive)
            XCTFail("R-e: reported success, archive holds \(found)")
        } catch {
            print("R-e failed properly:", error.localizedDescription)
        }
    }

    // MARK: R-f: deleting everything

    func testDeletingTheOnlyEntryLeavesAnArchiveThatOpens() async throws {
        let only = try write("only\n", "f/only.txt")
        let archive = root.appendingPathComponent("last.rar")
        try await rar.create(archive: archive, items: [only], options: options)
        let session = ArchiveSession(archiveURL: archive)
        try await session.load()
        session.markForDeletion(["only.txt"])
        do {
            try await session.save(to: archive, options: options)
            print("R-f saved; file exists:", FileManager.default.fileExists(atPath: archive.path),
                  "entries:", session.visibleEntries.map(\.path))
        } catch {
            XCTFail("R-f: the save threw after rar had already deleted: \(error.localizedDescription); archive exists: \(FileManager.default.fileExists(atPath: archive.path))")
        }
    }

    // MARK: R-g: odd names

    func testOddNamesGoInUnderTheirOwnNames() async throws {
        let names = [" lead.txt", "trail .txt", "trailing space ", "@at.txt", "-dash.txt", "Привет мир.txt",
                     "cafe\u{301}.txt", "\"quoted\".txt", "semi;colon.txt", "  two  spaces.txt", "tab\there.txt",
                     "#hash.txt", "back`tick.txt", "[bracket].txt", "dollar$HOME.txt", "a  //  b.txt".replacingOccurrences(of: "/", with: ":"),
                     "ends with dot.", "100%.txt", "new\nline.txt"]
        var problems: [String] = []
        for (index, name) in names.enumerated() {
            let item = try write("x\n", "odd\(index)/\(name)")
            let archive = root.appendingPathComponent("odd-\(index).rar")
            do {
                try await rar.create(archive: archive, items: [item], options: options)
                let found = try await paths(in: archive)
                if found != [name] { problems.append("\(name.debugDescription) stored as \(found)") ; continue }
                // A second entry, so deleting the first leaves the archive in place.
                let keep = try write("k\n", "oddkeep\(index)/keep.txt")
                try await rar.add(items: [keep], to: archive, options: options)
                try await rar.delete(entries: [ArchiveEntry(path: name, isDirectory: false)], from: archive, password: nil)
                let left = try await paths(in: archive)
                if left != ["keep.txt"] { problems.append("deleting \(name.debugDescription) left \(left)") }
            } catch {
                problems.append("\(name.debugDescription): \(error.localizedDescription)")
            }
        }
        print("R-g problems:\n  " + problems.joined(separator: "\n  "))
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "; "))
    }

    // MARK: R-h: renaming a folder

    func testRenamingAFolderMovesWhatIsInside() async throws {
        try write("a\n", "h/dir/a.txt")
        try write("b\n", "h/dir/sub/b.txt")
        try write("c\n", "h/dir2/c.txt")
        let archive = root.appendingPathComponent("ren.rar")
        try await rar.create(archive: archive, items: [root.appendingPathComponent("h/dir"), root.appendingPathComponent("h/dir2")],
                             options: options)
        try await rar.rename(entry: ArchiveEntry(path: "dir", isDirectory: true), to: "moved", in: archive, password: nil)
        let found = try await paths(in: archive)
        print("R-h after rename:", found)
        XCTAssertEqual(found, ["dir2", "dir2/c.txt", "moved", "moved/a.txt", "moved/sub", "moved/sub/b.txt"])
    }

    // MARK: R-i: what the metadata filter takes

    func testOnlyMacBookkeepingIsLeftOut() async throws {
        try write("1\n", "i/tree/notes.DS_Store")
        try write("2\n", "i/tree/my__MACOSX_backup.txt")
        try write("3\n", "i/tree/keep.txt")
        try write("4\n", "i/tree/.DS_Store")
        let archive = root.appendingPathComponent("meta.rar")
        var filtered = options
        filtered.excludeMacMetadata = true
        try await rar.create(archive: archive, items: [root.appendingPathComponent("i/tree")], options: filtered)
        let found = try await paths(in: archive)
        print("R-i found:", found)
        XCTAssertEqual(found, ["tree", "tree/keep.txt", "tree/my__MACOSX_backup.txt", "tree/notes.DS_Store"])
    }

    // MARK: R-j: the session, nested additions and volumes

    func testASessionSavedAsRarVolumesWithANestedAdditionIsARarSet() async throws {
        let big = try random(250_000, "j/big.bin")
        try write("d\n", "j/docs/d.txt")
        let extra = try write("extra\n", "j/elsewhere/extra.txt")
        let folder = root.appendingPathComponent("jout")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let session = ArchiveSession(archiveURL: nil)
        session.stage(items: [big, root.appendingPathComponent("j/docs")])
        session.stage(items: [extra], into: "docs")
        var split = options
        split.volumeSize = "100k"
        do {
            try await session.save(to: folder.appendingPathComponent("set.rar"), options: split)
        } catch {
            let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
            XCTFail("R-j save failed: \(error.localizedDescription); folder: \(files)")
            return
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        print("R-j files:", files, "opened as:", session.archiveURL?.lastPathComponent ?? "nil",
              "entries:", session.visibleEntries.map(\.path).sorted())
        XCTAssertTrue(files.allSatisfy { $0.hasSuffix(".rar") },
                      "these are not RAR volumes, and RAR tools will not read them: \(files)")
        let tool = try XCTUnwrap(EngineLocator.externalRAR)
        let test = try await ProcessRunner.run(executable: tool, arguments: ["t", "--", folder.appendingPathComponent(files[0]).path])
        print("R-j rar t exit:", test.exitCode, test.combined.split(separator: "\n").suffix(2).joined(separator: " | "))
        XCTAssertEqual(test.exitCode, 0)
    }

    // MARK: R-l: adding into folders with awkward names, in place

    func testSavingInPlaceIntoAwkwardlyNamedFolders() async throws {
        let folders = ["my docs/-dash dir/@at dir", "Папка/cafe\u{301}", "-top", "@top", "a b  c"]
        for folder in folders { try write("keep\n", "l/\(folder)/keep.txt") }
        let tops = Set(folders.map { String($0.split(separator: "/")[0]) }).sorted()
        let archive = root.appendingPathComponent("awkward.rar")
        try await rar.create(archive: archive, items: tops.map { root.appendingPathComponent("l/\($0)") }, options: options)
        let extra = try write("extra\n", "l2/extra.txt")
        let other = try write("other\n", "l3/-other.txt")

        let session = ArchiveSession(archiveURL: archive)
        try await session.load()
        var expected = Set(session.visibleEntries.map(\.path))
        for folder in folders {
            // The same file cannot be staged twice, so a copy per folder.
            let copy = try write("extra\n", "l4/\(folder.replacingOccurrences(of: "/", with: "_"))/extra.txt")
            session.stage(items: [copy], into: folder)
            expected.insert(folder + "/extra.txt")
        }
        session.stage(items: [other])
        expected.insert("-other.txt")
        session.markForDeletion(["-top/keep.txt"])
        expected.remove("-top/keep.txt")
        try await session.save(to: archive, options: options)
        let found = Set(session.visibleEntries.map(\.path))
        print("R-l missing:", expected.subtracting(found).sorted(), "unexpected:", found.subtracting(expected).sorted())
        XCTAssertEqual(found, expected)
        _ = extra
    }

    // MARK: R-m: a file name is not a diagnosis

    func testAFailureIsNotCalledAPasswordProblemBecauseOfAFileName() async throws {
        let innocent = try write("x\n", "m/my wrong password list.txt")
        let unreadable = try write("y\n", "m/locked.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        let archive = root.appendingPathComponent("names.rar")
        do {
            try await rar.create(archive: archive, items: [innocent, unreadable], options: options)
            XCTFail("expected the unreadable file to fail the save")
        } catch let error as ArchiveError {
            print("R-m reported:", error, "-", error.localizedDescription)
            XCTAssertFalse(error.isPasswordProblem, "a file that could not be read was reported as a password problem")
        }
    }

    // MARK: R-n: links

    func testLinksAreStoredAsLinksNotFollowed() async throws {
        try write("target file\n", "n/outside/file.txt")
        try write("inside the linked folder\n", "n/outside/folder/deep.txt")
        try write("plain\n", "n/tree/plain.txt")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("n/tree/to-file").path,
                                                   withDestinationPath: "../outside/file.txt")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("n/tree/to-folder").path,
                                                   withDestinationPath: "../outside/folder")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("n/top-link").path,
                                                   withDestinationPath: "outside/folder")
        let archive = root.appendingPathComponent("links.rar")
        try await rar.create(archive: archive,
                             items: [root.appendingPathComponent("n/tree"), root.appendingPathComponent("n/top-link")],
                             options: options)
        let listing = try await reader.list(archive: archive, password: nil, encodingCodePage: nil)
        let described = listing.entries.map { "\($0.path) [\($0.attributes ?? "?") dir=\($0.isDirectory) size=\($0.size)]" }.sorted()
        print("R-n stored:\n  " + described.joined(separator: "\n  "))
        XCTAssertFalse(listing.entries.contains { $0.path.hasSuffix("deep.txt") },
                       "the contents of a linked folder were archived")
        // The same input through the 7-Zip engine, for comparison.
        let zip = root.appendingPathComponent("links.zip")
        try await reader.create(archive: zip,
                                items: [root.appendingPathComponent("n/tree"), root.appendingPathComponent("n/top-link")],
                                options: CompressionOptions(formatKey: "zip"))
        let zipped = try await reader.list(archive: zip, password: nil, encodingCodePage: nil)
        print("R-n zip stores:\n  " + zipped.entries.map { "\($0.path) [\($0.attributes ?? "?") dir=\($0.isDirectory) size=\($0.size)]" }.sorted().joined(separator: "\n  "))
    }

    func testALinkToItsOwnParentDoesNotMultiplyTheFolder() async throws {
        try write("plain\n", "o/tree/plain.txt")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("o/tree/loop").path,
                                                   withDestinationPath: ".")
        let archive = root.appendingPathComponent("loop.rar")
        let token = CancellationToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { token.cancel() }
        let start = Date()
        do {
            try await rar.create(archive: archive, items: [root.appendingPathComponent("o/tree")], options: options,
                                 cancellation: token)
        } catch {
            print("R-o create ended with:", error.localizedDescription.prefix(200))
        }
        let took = Date().timeIntervalSince(start)
        let entries = (try? await reader.list(archive: archive, password: nil, encodingCodePage: nil).entries) ?? []
        let deepest = entries.map { $0.path.split(separator: "/").count }.max() ?? 0
        print(String(format: "R-o took %.1fs; %d entries; deepest path has %d components", took, entries.count, deepest))
        XCTAssertLessThanOrEqual(entries.count, 3, "one file and one link became \(entries.count) entries")
    }

    // MARK: R-k: converting with a replaced file

    func testConvertingToRarKeepsTheReplacementNotTheOriginal() async throws {
        let original = try write("original\n", "k/seed/notes.txt")
        let zip = root.appendingPathComponent("seed.zip")
        try await reader.create(archive: zip, items: [original], options: CompressionOptions(formatKey: "zip"))
        let replacement = try write("replacement\n", "k/drop/notes.txt")
        var results: [String] = []
        for round in 0..<4 {
            let session = ArchiveSession(archiveURL: zip)
            try await session.load()
            session.stage(items: [replacement])
            let destination = root.appendingPathComponent("converted-\(round).rar")
            try await session.save(to: destination, options: options)
            results.append(try await text(of: "notes.txt", in: destination).trimmingCharacters(in: .newlines))
        }
        print("R-k results:", results)
        XCTAssertEqual(Set(results), ["replacement"], "\(results)")
    }
}
