import XCTest
@testable import JustArcCore

/// Attacks on the extraction callback, written by an independent review of it. Each
/// test asserts something README "What extraction promises" says, against an archive
/// built to break it.
final class ExtractionHardeningTests: XCTestCase {
    private let engine = SevenZipEngine()
    private var root: URL!

    override func setUpWithError() throws {
        root = try FixtureBuilder.makeSourceTree()
    }

    override func tearDown() {
        // Make everything deletable again.
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                   ofItemAtPath: root.appendingPathComponent("locked.txt").path)
        FixtureBuilder.cleanup(root)
    }

    private func python(_ script: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script]
        process.currentDirectoryURL = root
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, message)
    }

    private func everything(under folder: URL) -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: folder.path) else { return [] }
        return walker.compactMap { $0 as? String }.sorted()
    }

    private func leftovers(under folder: URL) -> [String] {
        everything(under: folder).filter { $0.contains(".justarc-") }
    }

    private func text(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    private func makeDestination(_ name: String) throws -> URL {
        let destination = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return destination
    }

    /// Extracts through the bridge directly and cancels as soon as `when` is true.
    private func extract(_ archive: URL, to destination: URL, mode: OverwriteMode,
                         cancelWhen when: @escaping () -> Bool) -> Error? {
        do {
            let bridge = try BridgeArchive.open(archive, password: nil, codePage: nil)
            let progress = BridgeProgress(handler: nil, cancellation: nil, guardian: { !when() })
            try bridge.extract(indices: nil, destination: destination, password: nil, overwrite: mode,
                               flatten: false, testOnly: false, progress: progress)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - 5. LinkStaysInside: a link checked before the step it relies on exists

    func testALinkWhoseStepBecomesALinkLaterDoesNotEscape() async throws {
        try python("""
        import tarfile
        with tarfile.open('order.tar', 'w') as t:
            l2 = tarfile.TarInfo('l2'); l2.type = tarfile.SYMTYPE; l2.linkname = 'd/..'; t.addfile(l2)
            d = tarfile.TarInfo('d'); d.type = tarfile.SYMTYPE; d.linkname = '.'; t.addfile(d)
        """)
        let outer = try makeDestination("order-outer")
        let destination = outer.appendingPathComponent("dest")
        try "secret\n".write(to: outer.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
        try await engine.extract(archive: root.appendingPathComponent("order.tar"), entries: nil, to: destination,
                                 password: nil, overwrite: .overwrite, flattenPaths: false)
        print("ORDER listing:", everything(under: destination))
        let link = destination.appendingPathComponent("l2")
        if PathSafety.itemExists(at: link) {
            let resolved = link.resolvingSymlinksInPath().path
            let inside = destination.resolvingSymlinksInPath().path
            print("ORDER l2 ->", (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) ?? "?",
                  "resolves to", resolved, "destination", inside)
            XCTAssertTrue(resolved == inside || resolved.hasPrefix(inside + "/"),
                          "l2 resolves outside the destination: \(resolved)")
            XCTAssertNil(text(link.appendingPathComponent("outside.txt")),
                         "a file outside the destination is readable through l2")
        }
    }

    func testNothingIsWrittenThroughALinkThatGotOut() async throws {
        // The same escape, then entries that try to use it: by name, by a name in
        // another case, as a hard link source, and by way of a redirected folder.
        try python("""
        import tarfile, io
        def f(t, name, data):
            i = tarfile.TarInfo(name); i.size = len(data); t.addfile(i, io.BytesIO(data))
        def attempt(name, extra):
            with tarfile.open(name, 'w') as t:
                l2 = tarfile.TarInfo('l2'); l2.type = tarfile.SYMTYPE; l2.linkname = 'd/..'; t.addfile(l2)
                d = tarfile.TarInfo('d'); d.type = tarfile.SYMTYPE; d.linkname = '.'; t.addfile(d)
                n2 = tarfile.TarInfo('name 2'); n2.type = tarfile.SYMTYPE; n2.linkname = 'e/..'; t.addfile(n2)
                e = tarfile.TarInfo('e'); e.type = tarfile.SYMTYPE; e.linkname = '.'; t.addfile(e)
                f(t, 'ok.txt', b'ok')
                extra(t)
        def redirect(t):
            f(t, 'name', b'file')
            f(t, 'name/evil-redirect.txt', b'evil')
        def hard(t):
            h = tarfile.TarInfo('h'); h.type = tarfile.LNKTYPE; h.linkname = 'l2/outside.txt'; t.addfile(h)
        def hardinto(t):
            h = tarfile.TarInfo('l2/h-evil.txt'); h.type = tarfile.LNKTYPE; h.linkname = 'ok.txt'; t.addfile(h)
        def case(t):
            f(t, 'L2/evil-case.txt', b'evil')
        def plain(t):
            f(t, 'l2/evil.txt', b'evil')
        def folder(t):
            d = tarfile.TarInfo('l2/evil-folder'); d.type = tarfile.DIRTYPE; d.mode = 0o755; t.addfile(d)
        def link(t):
            s = tarfile.TarInfo('l2/evil-link'); s.type = tarfile.SYMTYPE; s.linkname = 'x'; t.addfile(s)
        def over(t):
            f(t, 'l2', b'replaces the link itself')
            d = tarfile.TarInfo('d'); d.type = tarfile.DIRTYPE; d.mode = 0o777; t.addfile(d)
        attempt('through-redirect.tar', redirect)
        attempt('through-hard.tar', hard)
        attempt('through-hardinto.tar', hardinto)
        attempt('through-case.tar', case)
        attempt('through-plain.tar', plain)
        attempt('through-folder.tar', folder)
        attempt('through-link.tar', link)
        attempt('through-over.tar', over)
        """)
        for name in ["redirect", "hard", "hardinto", "case", "plain", "folder", "link", "over"] {
            for mode in OverwriteMode.allCases {
                for flatten in [false, true] {
                    let outer = try makeDestination("through-\(name)-\(mode)-\(flatten)")
                    let destination = outer.appendingPathComponent("dest")
                    try "secret\n".write(to: outer.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
                    let before = try FileManager.default.attributesOfItem(atPath: outer.path)[.posixPermissions] as? Int
                    var thrown: Error?
                    do {
                        try await engine.extract(archive: root.appendingPathComponent("through-\(name).tar"), entries: nil,
                                                 to: destination, password: nil, overwrite: mode, flattenPaths: flatten)
                    } catch { thrown = error }
                    let label = "\(name) \(mode) flatten=\(flatten)"
                    if mode == .overwrite {
                        print("THROUGH", label, "error:", thrown.map { "\($0)" } ?? "none", "dest:",
                              (try? FileManager.default.contentsOfDirectory(atPath: destination.path).sorted()) ?? [])
                    }
                    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outer.path).sorted(),
                                   ["dest", "outside.txt"], "\(label): something was written outside the destination")
                    XCTAssertEqual(text(outer.appendingPathComponent("outside.txt")), "secret\n", label)
                    let links = (try FileManager.default.attributesOfItem(atPath: outer.appendingPathComponent("outside.txt").path)[.referenceCount] as? Int) ?? -1
                    XCTAssertEqual(links, 1, "\(label): a hard link to a file outside was made")
                    let after = try FileManager.default.attributesOfItem(atPath: outer.path)[.posixPermissions] as? Int
                    XCTAssertEqual(before, after, "\(label): the mode of a folder outside changed")
                    XCTAssertEqual(leftovers(under: destination), [], label)
                }
            }
        }
    }

    // MARK: - 2. Backups thrown away although nothing took the file's place

    func testAReplacedFileSurvivesALinkThatCannotBeMade() async throws {
        try python("""
        import zipfile
        with zipfile.ZipFile('longlink.zip', 'w') as z:
            a = zipfile.ZipInfo('notes.txt'); a.create_system = 3; a.external_attr = 0o120777 << 16
            z.writestr(a, 'a/' * 700 + 'b')
        """)
        for mode in [OverwriteMode.overwrite, .renameExisting] {
            let destination = try makeDestination("longlink-\(mode)")
            try "mine\n".write(to: destination.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
            var thrown: Error?
            do {
                try await engine.extract(archive: root.appendingPathComponent("longlink.zip"), entries: nil,
                                         to: destination, password: nil, overwrite: mode, flattenPaths: false)
            } catch { thrown = error }
            print("LONGLINK \(mode) error:", thrown.map { "\($0)" } ?? "none", "listing:", everything(under: destination))
            XCTAssertEqual(text(destination.appendingPathComponent("notes.txt")), "mine\n",
                           "\(mode): the existing file is gone and nothing replaced it")
            XCTAssertEqual(leftovers(under: destination), [], "\(mode)")
        }
    }

    func testAHardLinkToItselfDoesNotDestroyTheFileAlreadyThere() async throws {
        try python("""
        import tarfile
        with tarfile.open('selflink.tar', 'w') as t:
            h = tarfile.TarInfo('keep.txt'); h.type = tarfile.LNKTYPE; h.linkname = 'keep.txt'; t.addfile(h)
        """)
        for mode in [OverwriteMode.overwrite, .renameExisting, .renameNew, .skip] {
            let destination = try makeDestination("selflink-\(mode)")
            try "mine\n".write(to: destination.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
            var thrown: Error?
            do {
                try await engine.extract(archive: root.appendingPathComponent("selflink.tar"), entries: nil,
                                         to: destination, password: nil, overwrite: mode, flattenPaths: false)
            } catch { thrown = error }
            print("SELFLINK \(mode) error:", thrown.map { "\($0)" } ?? "none", "listing:", everything(under: destination))
            XCTAssertEqual(text(destination.appendingPathComponent("keep.txt")), "mine\n",
                           "\(mode): the existing file is gone")
            XCTAssertEqual(leftovers(under: destination), [], "\(mode)")
        }
    }

    // MARK: - 4. Hard links

    private func hardLinkTar() throws -> URL {
        try python("""
        import tarfile, io
        with tarfile.open('hl2.tar', 'w') as t:
            i = tarfile.TarInfo('orig.txt'); data = b'from the archive'; i.size = len(data); t.addfile(i, io.BytesIO(data))
            h = tarfile.TarInfo('hard.txt'); h.type = tarfile.LNKTYPE; h.linkname = 'orig.txt'; t.addfile(h)
        """)
        return root.appendingPathComponent("hl2.tar")
    }

    private func inode(_ url: URL) -> UInt64? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? UInt64(info.st_ino) : nil
    }

    func testAHardLinkGetsTheArchivesContentsNotAnExistingFiles() async throws {
        let archive = try hardLinkTar()
        for mode in [OverwriteMode.renameNew, .skip, .renameExisting, .overwrite] {
            let destination = try makeDestination("hl-\(mode)")
            let mine = destination.appendingPathComponent("orig.txt")
            try "mine\n".write(to: mine, atomically: true, encoding: .utf8)
            let mineInode = inode(mine)
            try await engine.extract(archive: archive, entries: nil, to: destination, password: nil,
                                     overwrite: mode, flattenPaths: false)
            let hard = destination.appendingPathComponent("hard.txt")
            let listing = everything(under: destination)
            print("HL \(mode) listing:", listing, "hard.txt =", text(hard) ?? "<missing>",
                  "is another name for the user's own orig.txt:", inode(hard) != nil && inode(hard) == mineInode)
            if mode != .skip {
                XCTAssertEqual(text(hard), "from the archive", "\(mode): the link holds something else")
            }
        }
    }

    func testAHardLinkToAFileTheArchiveDoesNotHold() async throws {
        try python("""
        import tarfile
        with tarfile.open('foreign.tar', 'w') as t:
            h = tarfile.TarInfo('h.txt'); h.type = tarfile.LNKTYPE; h.linkname = 'private.txt'; t.addfile(h)
        """)
        let destination = try makeDestination("foreign")
        let mine = destination.appendingPathComponent("private.txt")
        try "mine\n".write(to: mine, atomically: true, encoding: .utf8)
        try await engine.extract(archive: root.appendingPathComponent("foreign.tar"), entries: nil, to: destination,
                                 password: nil, overwrite: .renameNew, flattenPaths: false)
        let links = (try FileManager.default.attributesOfItem(atPath: mine.path)[.referenceCount] as? Int) ?? -1
        print("FOREIGN listing:", everything(under: destination), "link count of the user's file:", links)
        XCTAssertEqual(links, 1, "the archive made a second name for a file it never held")
    }

    func testExtractingOnlyTheHardLinkStillProducesAFile() async throws {
        let archive = try hardLinkTar()
        let destination = try makeDestination("hl-only")
        var thrown: Error?
        do {
            try await engine.extract(archive: archive, entries: [ArchiveEntry(path: "hard.txt", isDirectory: false)],
                                     to: destination, password: nil, overwrite: .renameNew, flattenPaths: false)
        } catch { thrown = error }
        print("HLONLY error:", thrown.map { "\($0)" } ?? "none", "listing:", everything(under: destination))
        XCTAssertEqual(text(destination.appendingPathComponent("hard.txt")), "from the archive")
    }

    // MARK: - 2. Rollback

    func testCancelPutsBackASymlinkThatWasReplaced() throws {
        try python("""
        import zipfile
        with zipfile.ZipFile('rb1.zip', 'w') as z:
            z.writestr('thing', 'new')
            z.writestr('zz-last.txt', 'last')
        """)
        let destination = try makeDestination("rb1")
        try "target\n".write(to: destination.appendingPathComponent("target.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: destination.appendingPathComponent("thing").path,
                                                   withDestinationPath: "target.txt")
        let before = everything(under: destination)
        let sentinel = destination.appendingPathComponent("zz-last.txt").path
        let error = extract(root.appendingPathComponent("rb1.zip"), to: destination, mode: .overwrite,
                            cancelWhen: { FileManager.default.fileExists(atPath: sentinel) })
        print("RB1 error:", error.map { "\($0)" } ?? "none", "listing:", everything(under: destination))
        XCTAssertEqual(error as? ArchiveError, .cancelled)
        XCTAssertEqual(everything(under: destination), before)
        XCTAssertEqual(try? FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("thing").path),
                       "target.txt", "the link that was replaced was not put back")
        XCTAssertEqual(text(destination.appendingPathComponent("target.txt")), "target\n")
    }

    func testCancelAfterOnePathWasWrittenTwice() throws {
        try python("""
        import zipfile, warnings
        warnings.simplefilter('ignore')
        with zipfile.ZipFile('rb2.zip', 'w') as z:
            z.writestr('same.txt', 'first')
            z.writestr('same.txt', 'second')
            z.writestr('A.txt', 'upper')
            z.writestr('a.txt', 'lower')
            z.writestr('name', 'a file')
            z.writestr('name/child.txt', 'child')
            z.writestr('zz-last.txt', 'last')
        """)
        for mode in OverwriteMode.allCases {
            let destination = try makeDestination("rb2-\(mode)")
            try "mine\n".write(to: destination.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
            try "mine a\n".write(to: destination.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(at: destination.appendingPathComponent("old"), withIntermediateDirectories: true)
            let before = everything(under: destination)
            let sentinel = destination.appendingPathComponent("zz-last.txt").path
            let error = extract(root.appendingPathComponent("rb2.zip"), to: destination, mode: mode,
                                cancelWhen: { FileManager.default.fileExists(atPath: sentinel) })
            print("RB2 \(mode) error:", error.map { "\($0)" } ?? "none", "listing:", everything(under: destination))
            XCTAssertEqual(error as? ArchiveError, .cancelled, "\(mode)")
            XCTAssertEqual(everything(under: destination), before, "\(mode): the folder is not as it was")
            XCTAssertEqual(text(destination.appendingPathComponent("same.txt")), "mine\n", "\(mode)")
            XCTAssertEqual(text(destination.appendingPathComponent("a.txt")), "mine a\n", "\(mode)")
        }
    }

    func testTheSamePathTwiceWithoutCancel() async throws {
        try python("""
        import zipfile, warnings
        warnings.simplefilter('ignore')
        with zipfile.ZipFile('twice.zip', 'w') as z:
            z.writestr('same.txt', 'first')
            z.writestr('same.txt', 'second')
            z.writestr('A.txt', 'upper')
            z.writestr('a.txt', 'lower')
        """)
        for mode in OverwriteMode.allCases {
            let destination = try makeDestination("twice-\(mode)")
            try "mine\n".write(to: destination.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
            try await engine.extract(archive: root.appendingPathComponent("twice.zip"), entries: nil, to: destination,
                                     password: nil, overwrite: mode, flattenPaths: false)
            let listing = everything(under: destination)
            print("TWICE \(mode):", listing.map { "\($0)=\(text(destination.appendingPathComponent($0)) ?? "?")" })
            XCTAssertEqual(leftovers(under: destination), [], "\(mode)")
        }
    }

    // MARK: - 6. Damage against a wrong password

    private func corrupt(_ archive: URL, at range: Range<Int>) throws {
        var data = try Data(contentsOf: archive)
        for offset in range { data[offset] ^= 0xFF }
        try data.write(to: archive)
    }

    func testADamagedZipCryptoArchiveIsReportedAsDamaged() async throws {
        let big = root.appendingPathComponent("payload/big.bin")
        try Data(repeating: 0x41, count: 200_000).write(to: big)
        let archive = root.appendingPathComponent("damaged-zc.zip")
        try await engine.create(archive: archive, items: [big],
                                options: CompressionOptions(formatKey: "zip", level: 0, password: "sesame",
                                                            zipEncryption: .zipCrypto))
        try corrupt(archive, at: 100_000..<100_016)
        do {
            try await engine.extract(archive: archive, entries: nil, to: root.appendingPathComponent("zc-out"),
                                     password: "sesame", overwrite: .overwrite, flattenPaths: false)
            XCTFail("damaged data was accepted")
        } catch let error as ArchiveError {
            print("ZIPCRYPTO damaged, right password:", error)
            XCTAssertFalse(error.isPasswordProblem, "the right password was called wrong")
        }
        do {
            try await engine.extract(archive: archive, entries: nil, to: root.appendingPathComponent("zc-out"),
                                     password: "nope", overwrite: .overwrite, flattenPaths: false)
            XCTFail("wrong password accepted")
        } catch let error as ArchiveError {
            print("ZIPCRYPTO damaged, wrong password:", error)
        }
    }

    func testOneDamagedFileInAnEncrypted7zDoesNotLockTheRestAway() async throws {
        let source = root.appendingPathComponent("seven")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 300_000).write(to: source.appendingPathComponent("a-first.bin"))
        try "intact\n".write(to: source.appendingPathComponent("b-second.txt"), atomically: true, encoding: .utf8)
        let archive = root.appendingPathComponent("damaged.7z")
        let made = try await FixtureBuilder.run(["a", archive.path, "-psesame", "-ms=off", "-mx=0", "seven"], in: root)
        XCTAssertEqual(made.exitCode, 0, made.combined)
        try corrupt(archive, at: 100_000..<100_016)
        let destination = root.appendingPathComponent("seven-out")
        do {
            try await engine.extract(archive: archive, entries: nil, to: destination,
                                     password: "sesame", overwrite: .overwrite, flattenPaths: false)
            XCTFail("damaged data was accepted")
        } catch let error as ArchiveError {
            print("7Z damaged, right password:", error, "listing:", everything(under: destination))
            XCTAssertFalse(error.isPasswordProblem, "the right password was called wrong")
        }
        XCTAssertEqual(text(destination.appendingPathComponent("seven/b-second.txt")), "intact\n",
                       "the intact file was not extracted")
    }

    // MARK: - 7. Writing

    func testAnUnreadableFileAddedToAnEncryptedArchiveIsNotAPasswordProblem() async throws {
        for (format, name) in [("zip", "enc-add.zip"), ("7z", "enc-add.7z")] {
            let archive = root.appendingPathComponent(name)
            try await engine.create(archive: archive, items: [root.appendingPathComponent("payload")],
                                    options: CompressionOptions(formatKey: format, password: "sesame"))
            let locked = root.appendingPathComponent("locked.txt")
            try "locked\n".write(to: locked, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
            do {
                try await engine.add(items: [locked], to: archive, into: "",
                                     options: CompressionOptions(formatKey: format, password: "sesame"))
                XCTFail("\(format): an unreadable file was added")
            } catch let error as ArchiveError {
                print("WRITE \(format) unreadable file on encrypted archive:", error)
                XCTAssertFalse(error.isPasswordProblem, "\(format): reported as a password problem: \(error)")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path)
        }
    }

    // MARK: - 1. What the committed file looks like

    func testModeAndDateOfCommittedFiles() async throws {
        try python("""
        import zipfile
        with zipfile.ZipFile('plain.zip', 'w') as z:
            a = zipfile.ZipInfo('windows.txt', date_time=(2001, 2, 3, 4, 5, 6)); a.create_system = 0; a.external_attr = 0x20
            z.writestr(a, 'x')
            b = zipfile.ZipInfo('unix.txt', date_time=(2001, 2, 3, 4, 5, 6)); b.create_system = 3; b.external_attr = 0o100640 << 16
            z.writestr(b, 'y')
        """)
        let destination = try makeDestination("plain")
        try "mine\n".write(to: destination.appendingPathComponent("unix.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.appendingPathComponent("unix.txt").path)
        try await engine.extract(archive: root.appendingPathComponent("plain.zip"), entries: nil, to: destination,
                                 password: nil, overwrite: .overwrite, flattenPaths: false)
        for name in ["windows.txt", "unix.txt"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent(name).path)
            print("MODE", name, String((attributes[.posixPermissions] as? Int) ?? -1, radix: 8),
                  attributes[.modificationDate] ?? "?")
        }
        XCTAssertEqual(leftovers(under: destination), [])
    }
    // MARK: - More experiments

    /// The same ordering trick, aimed at an absolute path: enough ".." to reach "/" from anywhere.
    func testALinkCanBeMadeToPointAtAnyAbsolutePath() async throws {
        try python("""
        import tarfile, zipfile
        target = 'a/' * 20 + '../' * 20 + 'etc/hosts'
        with tarfile.open('anywhere.tar', 'w') as t:
            l = tarfile.TarInfo('hosts.txt'); l.type = tarfile.SYMTYPE; l.linkname = target; t.addfile(l)
            a = tarfile.TarInfo('a'); a.type = tarfile.SYMTYPE; a.linkname = '.'; t.addfile(a)
        with zipfile.ZipFile('anywhere.zip', 'w') as z:
            l = zipfile.ZipInfo('hosts.txt'); l.create_system = 3; l.external_attr = 0o120777 << 16
            z.writestr(l, target)
            a = zipfile.ZipInfo('a'); a.create_system = 3; a.external_attr = 0o120777 << 16
            z.writestr(a, '.')
        with zipfile.ZipFile('anywhere-file-first.zip', 'w') as z:
            z.writestr('a', 'an ordinary file, at first')
            l = zipfile.ZipInfo('hosts.txt'); l.create_system = 3; l.external_attr = 0o120777 << 16
            z.writestr(l, target)
            a = zipfile.ZipInfo('a'); a.create_system = 3; a.external_attr = 0o120777 << 16
            z.writestr(a, '.')
        """)
        for name in ["anywhere.tar", "anywhere.zip", "anywhere-file-first.zip"] {
            for mode in OverwriteMode.allCases {
                let destination = try makeDestination("anywhere-\(name)-\(mode)")
                var thrown: Error?
                do {
                    try await engine.extract(archive: root.appendingPathComponent(name), entries: nil, to: destination,
                                             password: nil, overwrite: mode, flattenPaths: false)
                } catch { thrown = error }
                let link = destination.appendingPathComponent("hosts.txt")
                let resolved = PathSafety.itemExists(at: link) ? link.resolvingSymlinksInPath().path : "<not created>"
                print("ANYWHERE", name, mode, "error:", thrown.map { "\($0)" } ?? "none", "hosts.txt resolves to", resolved,
                      "readable:", (try? Data(contentsOf: link).count) ?? -1)
                XCTAssertFalse(resolved.hasSuffix("/etc/hosts") && !resolved.contains("anywhere-"),
                               "\(name) \(mode): a link to \(resolved) was created")
            }
        }
    }

    func testAMissingPasswordOnAPartlyEncryptedZipDoesNotDuplicateOnRetry() async throws {
        let plain = root.appendingPathComponent("a-plain.txt")
        let secret = root.appendingPathComponent("b-secret.txt")
        try "plain\n".write(to: plain, atomically: true, encoding: .utf8)
        try "secret\n".write(to: secret, atomically: true, encoding: .utf8)
        let archive = root.appendingPathComponent("mixed.zip")
        var made = try await FixtureBuilder.run(["a", archive.path, "a-plain.txt"], in: root)
        XCTAssertEqual(made.exitCode, 0, made.combined)
        made = try await FixtureBuilder.run(["a", archive.path, "-psesame", "b-secret.txt"], in: root)
        XCTAssertEqual(made.exitCode, 0, made.combined)
        let destination = root.appendingPathComponent("mixed-out")
        do {
            try await engine.extract(archive: archive, entries: nil, to: destination, password: nil,
                                     overwrite: .renameNew, flattenPaths: false)
            XCTFail("extracted without the password")
        } catch let error as ArchiveError {
            print("MIXED first attempt:", error, everything(under: destination))
        }
        try await engine.extract(archive: archive, entries: nil, to: destination, password: "sesame",
                                 overwrite: .renameNew, flattenPaths: false)
        print("MIXED after retry:", everything(under: destination))
        XCTAssertFalse(everything(under: destination).contains { $0.contains(" 2") })
    }

    func testAMissingVolumeIsNotCalledAFullDisk() async throws {
        let source = root.appendingPathComponent("vol")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: 3 * 1024 * 1024)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        try Data(bytes).write(to: source.appendingPathComponent("big.bin"))
        for format in ["zip", "7z"] {
            let archive = root.appendingPathComponent("vol.\(format)")
            try await engine.create(archive: archive, items: [source],
                                    options: CompressionOptions(formatKey: format, level: 0, volumeSize: "1m"))
            let volumes = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("vol.\(format).") }.sorted()
            print("VOLUME", format, "volumes:", volumes)
            // Cut the last volume short, as an interrupted copy would.
            let last = root.appendingPathComponent(volumes.last!)
            let data = try Data(contentsOf: last)
            try data.prefix(data.count / 2).write(to: last)
            try FileManager.default.removeItem(at: root.appendingPathComponent(volumes[volumes.count - 2]))
            do {
                try await engine.extract(archive: root.appendingPathComponent(volumes[0]), entries: nil,
                                         to: root.appendingPathComponent("vol-out-\(format)"), password: nil,
                                         overwrite: .overwrite, flattenPaths: false)
                print("VOLUME", format, "extracted without error:", everything(under: root.appendingPathComponent("vol-out-\(format)")))
            } catch {
                print("VOLUME", format, "error:", error)
                XCTAssertFalse("\(error)".contains("disk"), "\(format): a damaged source was blamed on the destination disk")
            }
        }
    }
    func testOneNameTheDiskCannotHoldDoesNotStopTheRest() async throws {
        try python("""
        import zipfile
        with zipfile.ZipFile('longname.zip', 'w') as z:
            z.writestr('a-first.txt', 'first')
            z.writestr('x' * 300 + '.txt', 'a name of 304 characters')
            z.writestr('z-last.txt', 'last')
        """)
        let destination = try makeDestination("longname")
        var thrown: Error?
        do {
            try await engine.extract(archive: root.appendingPathComponent("longname.zip"), entries: nil, to: destination,
                                     password: nil, overwrite: .renameNew, flattenPaths: false)
        } catch { thrown = error }
        print("LONGNAME error:", thrown.map { "\($0)" } ?? "none", "listing:", everything(under: destination))
        XCTAssertEqual(text(destination.appendingPathComponent("z-last.txt")), "last",
                       "the file after the one that could not be named was never extracted")
        XCTAssertEqual(leftovers(under: destination), [])
    }
}
