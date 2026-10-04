import XCTest
@testable import JustArcCore

/// How extraction behaves on volumes other than the startup disk: one that fills up,
/// and one with no hard links or symbolic links. Two small disk images are made and
/// mounted for the run, and detached after it.
final class OtherVolumeTests: XCTestCase {
    private let engine = SevenZipEngine()
    private var root: URL!
    private static var scratch = URL(fileURLWithPath: "/nonexistent")
    private var scratch: URL { Self.scratch }
    private var small: URL { Self.scratch.appendingPathComponent("mnt-small") }
    private var fat: URL { Self.scratch.appendingPathComponent("mnt-fat") }

    @discardableResult
    private static func hdiutil(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    override class func setUp() {
        // /private/tmp, not the temp folder under /var: a mount point's path has to
        // be the one the system reports back for it.
        scratch = URL(fileURLWithPath: "/private/tmp/justarc-volumes-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        for (name, size, system) in [("small", "6m", "HFS+"), ("fat", "40m", "ExFAT")] {
            let image = scratch.appendingPathComponent("\(name).dmg")
            let mount = scratch.appendingPathComponent("mnt-\(name)")
            try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            hdiutil(["create", "-size", size, "-fs", system, "-volname", "justarc-\(name)", "-quiet", image.path])
            hdiutil(["attach", image.path, "-mountpoint", mount.path, "-nobrowse", "-quiet"])
        }
    }

    override class func tearDown() {
        for name in ["small", "fat"] {
            hdiutil(["detach", scratch.appendingPathComponent("mnt-\(name)").path, "-force", "-quiet"])
        }
        try? FileManager.default.removeItem(at: scratch)
    }

    override func setUpWithError() throws {
        root = try FixtureBuilder.makeSourceTree()
    }

    override func tearDown() {
        FixtureBuilder.cleanup(root)
        for volume in [small, fat] {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: volume.path)) ?? []
            where name.hasPrefix("r2-") {
                try? FileManager.default.removeItem(at: volume.appendingPathComponent(name))
            }
        }
    }

    private func isMounted(_ url: URL) -> Bool {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return false }
        let mounted = withUnsafePointer(to: &info.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return mounted == url.path
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

    private func text(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    private func randomFile(_ url: URL, megabytes: Int) throws {
        var bytes = [UInt8](repeating: 0, count: megabytes * 1024 * 1024)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        try Data(bytes).write(to: url)
    }

    // MARK: - A full disk while extracting

    func testAFullDiskLeavesExistingFilesAloneAndIsCalledWhatItIs() async throws {
        try XCTSkipUnless(isMounted(small), "the small volume is not mounted")
        let source = root.appendingPathComponent("fill")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try randomFile(source.appendingPathComponent("a.bin"), megabytes: 1)
        try randomFile(source.appendingPathComponent("b.bin"), megabytes: 10)
        for password in [nil, "sesame"] as [String?] {
            for format in ["zip", "7z"] {
                let archive = root.appendingPathComponent("fill-\(password ?? "plain").\(format)")
                try await engine.create(archive: archive, items: [source],
                                        options: CompressionOptions(formatKey: format, level: 0, password: password, solid: false))
                for mode in [OverwriteMode.overwrite, .renameExisting, .renameNew] {
                    let destination = small.appendingPathComponent("r2-full")
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.createDirectory(at: destination.appendingPathComponent("fill"), withIntermediateDirectories: true)
                    try "mine a\n".write(to: destination.appendingPathComponent("fill/a.bin"), atomically: true, encoding: .utf8)
                    try "mine b\n".write(to: destination.appendingPathComponent("fill/b.bin"), atomically: true, encoding: .utf8)
                    var thrown: Error?
                    do {
                        try await engine.extract(archive: archive, entries: nil, to: destination, password: password,
                                                 overwrite: mode, flattenPaths: false)
                    } catch { thrown = error }
                    let label = "\(format) \(password == nil ? "plain" : "encrypted") \(mode)"
                    print("FULL", label, "error:", thrown.map { "\($0)" } ?? "none", "listing:", everything(under: destination))
                    XCTAssertNotNil(thrown, label)
                    if let error = thrown as? ArchiveError {
                        XCTAssertFalse(error.isPasswordProblem, "\(label): a full disk was called a password problem")
                    }
                    XCTAssertEqual(text(destination.appendingPathComponent("fill/b.bin")), "mine b\n", label)
                    XCTAssertFalse(everything(under: destination).contains { $0.contains(".justarc-") }, label)
                    try? FileManager.default.removeItem(at: destination)
                }
            }
        }
    }

    // MARK: - A full disk while writing an encrypted archive

    func testAFullDiskWhileAddingToAnEncryptedArchiveIsNotAPasswordProblem() async throws {
        try XCTSkipUnless(isMounted(small), "the small volume is not mounted")
        let folder = small.appendingPathComponent("r2-write")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let big = root.appendingPathComponent("big.bin")
        try randomFile(big, megabytes: 10)
        for format in ["zip", "7z"] {
            let archive = folder.appendingPathComponent("enc.\(format)")
            try await engine.create(archive: archive, items: [root.appendingPathComponent("payload")],
                                    options: CompressionOptions(formatKey: format, password: "sesame"))
            for password in ["sesame", nil] as [String?] {
                do {
                    try await engine.add(items: [big], to: archive, into: "",
                                         options: CompressionOptions(formatKey: format, level: 0, password: password))
                    XCTFail("\(format): ten megabytes fitted on a six megabyte disk")
                } catch let error as ArchiveError {
                    print("WRITEFULL \(format) password=\(password ?? "nil"):", error)
                    XCTAssertFalse(error.isPasswordProblem, "\(format): a full disk was called \(error)")
                }
            }
            // The archive itself must have survived.
            let listing = try await engine.list(archive: archive, password: "sesame")
            XCTAssertTrue(listing.entries.contains { $0.path == "payload/readme.txt" }, format)
            print("WRITEFULL \(format) leftovers:", everything(under: small).filter { !$0.hasPrefix(".") })
        }
    }

    // MARK: - A volume without links

    func testAnArchiveWithALinkOnAVolumeThatHasNone() async throws {
        try XCTSkipUnless(isMounted(fat), "the exFAT volume is not mounted")
        try python("""
        import zipfile
        with zipfile.ZipFile('withlink.zip', 'w') as z:
            z.writestr('a-first.txt', 'first')
            a = zipfile.ZipInfo('b-link'); a.create_system = 3; a.external_attr = 0o120777 << 16
            z.writestr(a, 'a-first.txt')
            z.writestr('c-last.txt', 'last')
        """)
        for mode in OverwriteMode.allCases {
            let destination = fat.appendingPathComponent("r2-link")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try "mine\n".write(to: destination.appendingPathComponent("b-link"), atomically: true, encoding: .utf8)
            var thrown: Error?
            do {
                try await engine.extract(archive: root.appendingPathComponent("withlink.zip"), entries: nil,
                                         to: destination, password: nil, overwrite: mode, flattenPaths: false)
            } catch { thrown = error }
            print("FATLINK \(mode) error:", thrown.map { "\($0)" } ?? "none", "listing:", everything(under: destination),
                  "b-link =", text(destination.appendingPathComponent("b-link")) ?? "<missing>")
            XCTAssertNotNil(text(destination.appendingPathComponent("b-link")), "\(mode): the existing file is gone")
            XCTAssertEqual(text(destination.appendingPathComponent("c-last.txt")), "last",
                           "\(mode): the file after the link was never extracted")
            try? FileManager.default.removeItem(at: destination)
        }
    }

    func testReplaceAndHardLinksOnAVolumeWithoutHardLinks() async throws {
        try XCTSkipUnless(isMounted(fat), "the exFAT volume is not mounted")
        try python("""
        import tarfile, io
        with tarfile.open('fat.tar', 'w') as t:
            i = tarfile.TarInfo('orig.txt'); data = b'from the archive'; i.size = len(data); t.addfile(i, io.BytesIO(data))
            h = tarfile.TarInfo('hard.txt'); h.type = tarfile.LNKTYPE; h.linkname = 'orig.txt'; t.addfile(h)
            i = tarfile.TarInfo('zz-last.txt'); data = b'last'; i.size = len(data); t.addfile(i, io.BytesIO(data))
        """)
        for mode in OverwriteMode.allCases {
            let destination = fat.appendingPathComponent("r2-hl")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try "mine\n".write(to: destination.appendingPathComponent("orig.txt"), atomically: true, encoding: .utf8)
            try "mine hard\n".write(to: destination.appendingPathComponent("hard.txt"), atomically: true, encoding: .utf8)
            var thrown: Error?
            do {
                try await engine.extract(archive: root.appendingPathComponent("fat.tar"), entries: nil,
                                         to: destination, password: nil, overwrite: mode, flattenPaths: false)
            } catch { thrown = error }
            let listing = everything(under: destination)
            print("FATHL \(mode) error:", thrown.map { "\($0)" } ?? "none",
                  listing.map { "\($0)=\(text(destination.appendingPathComponent($0)) ?? "?")" })
            XCTAssertFalse(listing.contains { $0.contains(".justarc-") }, "\(mode)")

            // And cancelled at the very end.
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try "mine\n".write(to: destination.appendingPathComponent("orig.txt"), atomically: true, encoding: .utf8)
            let sentinel = destination.appendingPathComponent("zz-last.txt").path
            var cancelError: Error?
            do {
                let bridge = try BridgeArchive.open(root.appendingPathComponent("fat.tar"), password: nil, codePage: nil)
                let progress = BridgeProgress(handler: nil, cancellation: nil,
                                              guardian: { !FileManager.default.fileExists(atPath: sentinel) })
                try bridge.extract(indices: nil, destination: destination, password: nil, overwrite: mode,
                                   flatten: false, testOnly: false, progress: progress)
            } catch { cancelError = error }
            let after = everything(under: destination)
            print("FATHL cancel \(mode) error:", cancelError.map { "\($0)" } ?? "none",
                  after.map { "\($0)=\(text(destination.appendingPathComponent($0)) ?? "?")" })
            XCTAssertFalse(after.contains { $0.contains(".justarc-") }, "\(mode)")
            XCTAssertNotNil(text(destination.appendingPathComponent("orig.txt")), "\(mode): orig.txt is gone altogether")
            try? FileManager.default.removeItem(at: destination)
        }
    }

    // MARK: - A mount point inside the destination

    func testAMountPointInsideTheDestination() async throws {
        try XCTSkipUnless(isMounted(fat) && isMounted(small), "the volumes are not mounted")
        try python("""
        import tarfile, io
        def f(t, name, data):
            i = tarfile.TarInfo(name); i.size = len(data); t.addfile(i, io.BytesIO(data))
        with tarfile.open('mount.tar', 'w') as t:
            f(t, 'r2-top.txt', b'top')
            f(t, 'mnt-fat/r2-inside.txt', b'inside')
            f(t, 'mnt-small/r2-inside.txt', b'inside small')
            h = tarfile.TarInfo('mnt-small/r2-hard.txt'); h.type = tarfile.LNKTYPE; h.linkname = 'r2-top.txt'; t.addfile(h)
            f(t, 'mnt-fat', b'a file named like the mount point')
        """)
        for mode in OverwriteMode.allCases {
            var thrown: Error?
            do {
                try await engine.extract(archive: root.appendingPathComponent("mount.tar"), entries: nil,
                                         to: scratch, password: nil, overwrite: mode, flattenPaths: false)
            } catch { thrown = error }
            let top = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path).sorted()) ?? []
            print("MOUNT \(mode) error:", thrown.map { "\($0)" } ?? "none", "top:", top,
                  "fat:", text(fat.appendingPathComponent("r2-inside.txt")) ?? "<missing>",
                  "small:", text(small.appendingPathComponent("r2-inside.txt")) ?? "<missing>",
                  "hard:", text(small.appendingPathComponent("r2-hard.txt")) ?? "<missing>")
            XCTAssertTrue(isMounted(fat) && isMounted(small), "\(mode): a mount point was moved")
            XCTAssertFalse(top.contains { $0.contains(".justarc-") }, "\(mode)")
            for name in top where name.hasPrefix("r2-top") || name.hasPrefix("mnt-fat ") {
                try? FileManager.default.removeItem(at: scratch.appendingPathComponent(name))
            }
            for volume in [small, fat] {
                for name in (try? FileManager.default.contentsOfDirectory(atPath: volume.path)) ?? [] where name.hasPrefix("r2-") {
                    try? FileManager.default.removeItem(at: volume.appendingPathComponent(name))
                }
            }
        }
    }

    // MARK: - Folders that were already there, after a failure

    func testAWrongPasswordLeavesExistingFoldersAsTheyWere() async throws {
        let archive = root.appendingPathComponent("secret-dirs.zip")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("payload").path)
        try await engine.create(archive: archive, items: [root.appendingPathComponent("payload")],
                                options: CompressionOptions(formatKey: "zip", password: "sesame"))
        let destination = root.appendingPathComponent("dirs-out")
        let folder = destination.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o700, .modificationDate: stamp], ofItemAtPath: folder.path)
        do {
            try await engine.extract(archive: archive, entries: nil, to: destination, password: "wrong",
                                     overwrite: .renameNew, flattenPaths: false)
            XCTFail("wrong password accepted")
        } catch let error as ArchiveError {
            XCTAssertTrue(error.isPasswordProblem)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        print("DIRS mode:", String((attributes[.posixPermissions] as? Int) ?? -1, radix: 8),
              "modified:", attributes[.modificationDate] ?? "?", "listing:", everything(under: destination))
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o700, "the folder's permissions changed")
        XCTAssertEqual(attributes[.modificationDate] as? Date, stamp, "the folder's date changed")
    }
}
