import XCTest
@testable import JustArcCore

final class VolumeSizeTests: XCTestCase {
    func testPresetTitlesResolve() {
        XCTAssertNil(VolumeSize.normalize("Do not split"))
        XCTAssertEqual(VolumeSize.normalize("700 MB (CD)"), "700m")
    }

    func testCommonSpellingsAreAccepted() {
        XCTAssertEqual(VolumeSize.normalize("100m"), "100m")
        XCTAssertEqual(VolumeSize.normalize("100 MB"), "100m")
        XCTAssertEqual(VolumeSize.normalize("1g"), "1g")
        XCTAssertEqual(VolumeSize.normalize("1 GiB"), "1g")
        XCTAssertEqual(VolumeSize.normalize("4480"), "4480b")
        XCTAssertEqual(VolumeSize.normalize("64k"), "64k")
    }

    func testFractionalSizesScaleDownAUnit() {
        XCTAssertEqual(VolumeSize.normalize("1.5g"), "1536m")
        XCTAssertEqual(VolumeSize.normalize("0.5 MB"), "512k")
    }

    func testEmptyAndNonsenseMeanNoSplit() {
        XCTAssertNil(VolumeSize.normalize(""))
        XCTAssertNil(VolumeSize.normalize("   "))
        XCTAssertNil(VolumeSize.normalize("none"))
        XCTAssertNil(VolumeSize.normalize("banana"))
        XCTAssertNil(VolumeSize.normalize("12x"))
        XCTAssertNil(VolumeSize.normalize("-5m"))
        XCTAssertNil(VolumeSize.normalize("m100"))
        XCTAssertNil(VolumeSize.normalize("0m"))
    }
}

final class RarEngineArgumentTests: XCTestCase {
    func testCompressionScaleMapsOntoRarLevels() {
        XCTAssertEqual(RarEngine.rarLevel(for: 0), 0)
        XCTAssertEqual(RarEngine.rarLevel(for: 1), 1)
        XCTAssertEqual(RarEngine.rarLevel(for: 5), 3)
        XCTAssertEqual(RarEngine.rarLevel(for: 9), 5)
    }

    func testAddArgumentsCarryLevelPasswordAndVolumes() {
        let options = CompressionOptions(formatKey: "rar", level: 9, password: "sesame",
                                         encryptFileNames: false, volumeSize: "100m",
                                         excludeMacMetadata: true)
        let arguments = RarEngine.addArguments(archive: URL(fileURLWithPath: "/tmp/a.rar"),
                                               names: ["payload"], options: options)
        XCTAssertEqual(arguments.first, "a")
        XCTAssertTrue(arguments.contains("-m5"))
        XCTAssertTrue(arguments.contains("-psesame"))
        XCTAssertTrue(arguments.contains("-v100m"))
        XCTAssertTrue(arguments.contains("-x*.DS_Store"))
        XCTAssertEqual(arguments.last, "payload")
        XCTAssertTrue(arguments.contains("/tmp/a.rar"))
    }

    func testEncryptingNamesUsesTheHeaderSwitch() {
        let options = CompressionOptions(formatKey: "rar", password: "s", encryptFileNames: true)
        let arguments = RarEngine.compressionArguments(options)
        XCTAssertTrue(arguments.contains("-hps"))
        XCTAssertFalse(arguments.contains("-ps"))
    }

    func testWritingWithoutTheToolReportsHowToInstallIt() async throws {
        guard EngineLocator.externalRAR == nil else {
            throw XCTSkip("rar is installed on this machine")
        }
        do {
            try await RarEngine().create(archive: URL(fileURLWithPath: "/tmp/x.rar"),
                                         items: [URL(fileURLWithPath: "/tmp")],
                                         options: CompressionOptions(formatKey: "rar"))
            XCTFail("expected the missing tool to be reported")
        } catch let error as ArchiveError {
            XCTAssertTrue(error.localizedDescription.contains("rar"), error.localizedDescription)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

final class EntryStagingTests: XCTestCase {
    func testUsesTheFileInPlaceWhenItAlreadyHasTheRightShape() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("staging-\(UUID().uuidString)")
        let file = root.appendingPathComponent("payload/docs/notes.txt")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "edited\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let staging = try EntryStaging(localURL: file, entryPath: "payload/docs/notes.txt")
        defer { staging.cleanup() }
        XCTAssertEqual(staging.relativePath, "payload/docs/notes.txt")
        XCTAssertEqual(staging.root.standardizedFileURL.path, root.standardizedFileURL.path)
    }

    func testMirrorsTheFileWhenItsLocationDoesNotMatchTheEntryPath() throws {
        let loose = FileManager.default.temporaryDirectory
            .appendingPathComponent("loose-\(UUID().uuidString).txt")
        try "edited\n".write(to: loose, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: loose) }

        let staging = try EntryStaging(localURL: loose, entryPath: "payload/docs/notes.txt")
        defer { staging.cleanup() }
        let mirrored = staging.root.appendingPathComponent(staging.relativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mirrored.path))
        XCTAssertEqual(try String(contentsOf: mirrored, encoding: .utf8), "edited\n")
    }
}

final class RarToolInstallerTests: XCTestCase {
    private let samplePage = """
    <a href="rar/rarmacos-arm-712.tar.gz">RAR 7.12 for macOS</a>
    <a href="rar/rarmacos-x64-712.tar.gz">RAR 7.12 for macOS Intel</a>
    <a href="rar/rarmacos-arm-723.tar.gz">RAR 7.23 for macOS</a>
    <a href="rar/rarlinux-x64-723.tar.gz">RAR for Linux</a>
    """

    func testPicksTheNewestBuildForTheArchitecture() {
        XCTAssertEqual(RarToolInstaller.newestVersion(onPage: samplePage, slug: "arm"), "723")
        XCTAssertEqual(RarToolInstaller.newestVersion(onPage: samplePage, slug: "x64"), "712")
        XCTAssertNil(RarToolInstaller.newestVersion(onPage: samplePage, slug: "ppc"))
    }

    func testVersionIsReadFromTheToolBanner() {
        let banner = """

        RAR 7.23   Copyright (c) 1993-2026 Alexander Roshal   27 Jun 2026
        Trial version             Type 'rar -?' for help
        """
        XCTAssertEqual(RarToolInstaller.version(fromBanner: banner), "7.23")
        XCTAssertNil(RarToolInstaller.version(fromBanner: "command not found"))
    }

    func testManagedInstallLivesOutsideTheAppBundle() {
        let directory = EngineLocator.managedRARDirectory.path
        XCTAssertTrue(directory.contains("Application Support"), directory)
        XCTAssertFalse(directory.contains(".app/"), "writing into the bundle would break its signature")
    }
}
