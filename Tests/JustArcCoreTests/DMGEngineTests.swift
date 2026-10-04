import XCTest
@testable import JustArcCore

/// Pure logic, no disk images involved.
final class DMGEngineParsingTests: XCTestCase {
    func testAttachPlistYieldsTheWholeDiskAndItsMountPoints() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>system-entities</key>
            <array>
                <dict>
                    <key>dev-entry</key><string>/dev/disk4s1</string>
                    <key>mount-point</key><string>/tmp/mnt/TestVol</string>
                </dict>
                <dict>
                    <key>dev-entry</key><string>/dev/disk4</string>
                </dict>
            </array>
        </dict>
        </plist>
        """
        let (devEntry, mountPoints) = DMGEngine.parseAttachOutput(plist)
        XCTAssertEqual(devEntry, "/dev/disk4", "detaching a slice instead of the whole disk leaks the mount")
        XCTAssertEqual(mountPoints.map(\.path), ["/tmp/mnt/TestVol"])
    }

    func testAttachOutputThatIsNotAPlistIsRejectedCleanly() {
        let (devEntry, mountPoints) = DMGEngine.parseAttachOutput("hdiutil: attach failed")
        XCTAssertNil(devEntry)
        XCTAssertTrue(mountPoints.isEmpty)
    }

    func testCompressionLevelsMapOntoImageFormats() {
        XCTAssertEqual(DMGEngine.imageFormatArguments(level: 0), ["-format", "UDRO"])
        XCTAssertEqual(DMGEngine.imageFormatArguments(level: 5),
                       ["-format", "UDZO", "-imagekey", "zlib-level=5"])
        XCTAssertEqual(DMGEngine.imageFormatArguments(level: 9), ["-format", "ULFO"])
    }

    func testVolumeNamesAreSanitisedAndTruncated() {
        XCTAssertEqual(DMGEngine.volumeName(for: URL(fileURLWithPath: "/tmp/My Project.dmg")), "My Project")
        XCTAssertEqual(DMGEngine.volumeName(for: URL(fileURLWithPath: "/tmp/a:b.dmg")), "a-b")
        let long = DMGEngine.volumeName(for: URL(fileURLWithPath: "/tmp/\(String(repeating: "x", count: 60)).dmg"))
        XCTAssertEqual(long.count, 27, "HFS+ rejects volume names longer than 27 characters")
    }

    func testEachFormatRoutesToItsOwnEngine() {
        XCTAssertTrue(EngineFactory.engine(for: URL(fileURLWithPath: "/tmp/a.dmg")) is DMGEngine)
        XCTAssertTrue(EngineFactory.engine(for: URL(fileURLWithPath: "/tmp/a.zip")) is SevenZipEngine)
        XCTAssertTrue(EngineFactory.engine(for: URL(fileURLWithPath: "/tmp/a.tar.gz")) is SevenZipEngine)
        // RAR has its own engine because writing needs RARLAB's tool, even though
        // reading is delegated straight back to 7-Zip.
        XCTAssertTrue(EngineFactory.engine(for: URL(fileURLWithPath: "/tmp/a.rar")) is RarEngine)
        XCTAssertTrue(EngineFactory.engine(for: URL(fileURLWithPath: "/tmp/notes.txt")) is SevenZipEngine)
    }

    func testRarEngineReadsThroughSevenZip() async throws {
        let (root, archive) = try await FixtureBuilder.makeArchive(named: "readable.zip")
        defer { FixtureBuilder.cleanup(root) }
        // A zip handed to the RAR engine still lists, because reading is delegated.
        let listing = try await RarEngine().list(archive: archive, password: nil, encodingCodePage: nil)
        XCTAssertTrue(listing.entries.contains { $0.path == "payload/readme.txt" })
    }

    func testReadOnlyEngineRefusesToWrite() async {
        struct ReadOnlyEngine: ArchiveEngine {
            func list(archive: URL, password: String?, encodingCodePage: Int?) async throws -> ArchiveListing {
                ArchiveListing(info: ArchiveInfo(), entries: [])
            }
            func extract(archive: URL, entries: [ArchiveEntry]?, to destination: URL, password: String?,
                         overwrite: OverwriteMode, flattenPaths: Bool,
                         cancellation: CancellationToken?, progress: ProgressHandler?) async throws {}
            func test(archive: URL, password: String?, cancellation: CancellationToken?,
                      progress: ProgressHandler?) async throws -> String { "" }
        }
        do {
            try await ReadOnlyEngine().delete(entries: [], from: URL(fileURLWithPath: "/tmp/a.iso"),
                                              password: nil)
            XCTFail("the default implementation should refuse")
        } catch let error as ArchiveError {
            XCTAssertFalse(error.isPasswordProblem)
        } catch {
            XCTFail("unexpected error type")
        }
    }
}

/// Creates and mounts real disk images.
final class DMGEngineTests: XCTestCase {
    private let engine = DMGEngine()

    override func tearDown() {
        super.tearDown()
        DMGMountRegistry.shared.unmountAll()
    }

    /// Source tree including a symlink, which disk images carry and archives often do not.
    private func makeSourceTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("justarc-dmg-tests-\(UUID().uuidString)")
        let docs = root.appendingPathComponent("Payload/docs")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try "hello from a disk image\n".write(to: root.appendingPathComponent("Payload/readme.txt"),
                                              atomically: true, encoding: .utf8)
        try String(repeating: "content ", count: 2000)
            .write(to: docs.appendingPathComponent("manual.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Applications"),
            withDestinationURL: URL(fileURLWithPath: "/Applications"))
        return root
    }

    private func makeImage(named name: String, password: String? = nil, level: Int = 1) async throws -> (URL, URL) {
        let root = try makeSourceTree()
        let image = root.deletingLastPathComponent().appendingPathComponent(name)
        // Each item keeps its own name at the top of the image, as in any other format.
        let items = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        try await engine.create(archive: image,
                                items: items,
                                options: CompressionOptions(formatKey: "dmg", level: level,
                                                            password: password))
        return (root, image)
    }

    func testCreateThenListShowsTheContents() async throws {
        let (root, image) = try await makeImage(named: "listing-\(UUID().uuidString).dmg")
        defer {
            engine.release(archive: image)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: image)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))

        let listing = try await engine.list(archive: image, password: nil, encodingCodePage: nil)
        let paths = Set(listing.entries.map(\.path))
        XCTAssertTrue(paths.contains("Payload/readme.txt"), "saw: \(paths.sorted())")
        XCTAssertTrue(paths.contains("Payload/docs/manual.txt"))
        XCTAssertTrue(paths.contains("Applications"), "the symlink should be listed")
        XCTAssertTrue(listing.info.formatName.contains("UDIF"), listing.info.formatName)
        XCTAssertGreaterThan(listing.info.physicalSize, 0)
        XCTAssertFalse(listing.containsEncryptedEntries)
    }

    func testVolumeHousekeepingIsHiddenFromTheListing() async throws {
        let (root, image) = try await makeImage(named: "hidden-\(UUID().uuidString).dmg")
        defer {
            engine.release(archive: image)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: image)
        }

        let listing = try await engine.list(archive: image, password: nil, encodingCodePage: nil)
        for entry in listing.entries {
            XCTAssertFalse(entry.path.hasPrefix(".Trashes"), "volume metadata leaked into the listing")
            XCTAssertFalse(entry.path.hasPrefix(".fseventsd"))
            XCTAssertFalse(entry.path.hasPrefix(".Spotlight-V100"))
        }
    }

    func testExtractAllReproducesTheTreeIncludingTheSymlink() async throws {
        let (root, image) = try await makeImage(named: "extract-\(UUID().uuidString).dmg")
        let destination = root.deletingLastPathComponent()
            .appendingPathComponent("dmg-out-\(UUID().uuidString)")
        defer {
            engine.release(archive: image)
            for url in [root, image, destination] { try? FileManager.default.removeItem(at: url) }
        }

        try await engine.extract(archive: image, entries: nil, to: destination, password: nil,
                                 overwrite: .overwrite, flattenPaths: false,
                                 cancellation: nil, progress: nil)

        let readme = destination.appendingPathComponent("Payload/readme.txt")
        XCTAssertEqual(try String(contentsOf: readme, encoding: .utf8), "hello from a disk image\n")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("Payload/docs/manual.txt").path))

        let link = destination.appendingPathComponent("Applications")
        let linkTarget = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        XCTAssertEqual(linkTarget, "/Applications", "the symlink was followed instead of copied")
    }

    func testExtractingOneEntryLeavesTheRestBehind() async throws {
        let (root, image) = try await makeImage(named: "single-\(UUID().uuidString).dmg")
        let scratch = root.deletingLastPathComponent()
            .appendingPathComponent("dmg-single-\(UUID().uuidString)")
        defer {
            engine.release(archive: image)
            for url in [root, image, scratch] { try? FileManager.default.removeItem(at: url) }
        }

        let listing = try await engine.list(archive: image, password: nil, encodingCodePage: nil)
        let target = try XCTUnwrap(listing.entries.first { $0.path == "Payload/docs/manual.txt" })

        let produced = try await engine.extractSingle(archive: image, entry: target,
                                                      to: scratch, password: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: produced.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: scratch.appendingPathComponent("Payload/readme.txt").path),
            "extracting one entry pulled out more than it should")
    }

    func testProgressReachesOneHundredPercent() async throws {
        let (root, image) = try await makeImage(named: "progress-\(UUID().uuidString).dmg")
        let destination = root.deletingLastPathComponent()
            .appendingPathComponent("dmg-progress-\(UUID().uuidString)")
        defer {
            engine.release(archive: image)
            for url in [root, image, destination] { try? FileManager.default.removeItem(at: url) }
        }

        let box = FractionBox()
        try await engine.extract(archive: image, entries: nil, to: destination, password: nil,
                                 overwrite: .overwrite, flattenPaths: false,
                                 cancellation: nil, progress: { box.record($0) })
        XCTAssertEqual(box.value, 1.0)
    }

    func testVerifyPassesOnAFreshImage() async throws {
        let (root, image) = try await makeImage(named: "verify-\(UUID().uuidString).dmg")
        defer {
            engine.release(archive: image)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: image)
        }

        let report = try await engine.test(archive: image, password: nil, cancellation: nil, progress: nil)
        XCTAssertFalse(report.lowercased().contains("error"), report)
    }

    func testEncryptedImageNeedsTheRightPassword() async throws {
        let (root, image) = try await makeImage(named: "secret-\(UUID().uuidString).dmg",
                                                password: "sesame")
        defer {
            engine.release(archive: image)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: image)
        }

        let encrypted = try await DMGEngine.isEncrypted(archive: image)
        XCTAssertTrue(encrypted)

        do {
            _ = try await engine.list(archive: image, password: nil, encodingCodePage: nil)
            XCTFail("listing an encrypted image without a password should fail")
        } catch let error as ArchiveError {
            XCTAssertEqual(error.localizedDescription, ArchiveError.passwordRequired.localizedDescription)
        }

        do {
            _ = try await engine.list(archive: image, password: "not-it", encodingCodePage: nil)
            XCTFail("the wrong password should fail")
        } catch let error as ArchiveError {
            XCTAssertTrue(error.isPasswordProblem, "unexpected error: \(error)")
        }

        let listing = try await engine.list(archive: image, password: "sesame", encodingCodePage: nil)
        XCTAssertTrue(listing.entries.contains { $0.path == "Payload/readme.txt" })
        XCTAssertTrue(listing.info.hasEncryptedHeader)
    }

    func testMountIsReusedAcrossCallsAndReleasedOnce() async throws {
        let (root, image) = try await makeImage(named: "mount-\(UUID().uuidString).dmg")
        defer {
            engine.release(archive: image)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: image)
        }

        _ = try await engine.list(archive: image, password: nil, encodingCodePage: nil)
        let first = try XCTUnwrap(DMGMountRegistry.shared.existing(for: image))

        _ = try await engine.list(archive: image, password: nil, encodingCodePage: nil)
        let second = try XCTUnwrap(DMGMountRegistry.shared.existing(for: image))
        XCTAssertEqual(first.devEntry, second.devEntry, "the image was remounted instead of reused")

        engine.release(archive: image)
        XCTAssertNil(DMGMountRegistry.shared.existing(for: image))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.mountRoot.path),
                       "the mount point was left behind")
        // Releasing an archive that is not mounted must not blow up.
        engine.release(archive: image)
    }

    func testListingAFileThatIsNotADiskImageFails() async throws {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-an-image-\(UUID().uuidString).dmg")
        try "this is not a disk image".write(to: bogus, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: bogus) }

        do {
            _ = try await engine.list(archive: bogus, password: nil, encodingCodePage: nil)
            XCTFail("a text file should not mount")
        } catch let error as ArchiveError {
            XCTAssertFalse(error.isPasswordProblem)
        }
    }
}

private final class FractionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Double = -1
    func record(_ progress: ArchiveProgress) {
        guard let fraction = progress.fraction else { return }
        lock.lock(); stored = fraction; lock.unlock()
    }
    var value: Double { lock.lock(); defer { lock.unlock() }; return stored }
}
