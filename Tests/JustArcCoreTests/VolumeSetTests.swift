import XCTest
@testable import JustArcCore

/// An archive in volumes says which files it was read from, so that what is done to
/// "the archive", such as moving it to the Trash, can be done to all of it.
final class VolumeSetTests: XCTestCase {
    private let engine = SevenZipEngine()
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("justarc-volumes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func blob(_ bytes: Int) throws -> URL {
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, bytes) }
        let url = root.appendingPathComponent("blob.bin")
        try data.write(to: url)
        return url
    }

    func testASplitArchiveNamesItsOtherVolumes() async throws {
        let folder = root.appendingPathComponent("set")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await engine.create(archive: folder.appendingPathComponent("set.7z"), items: [try blob(300_000)],
                                options: CompressionOptions(formatKey: "7z", level: 0, volumeSize: "100k"))
        // Something beside the set that is not part of it.
        try "mine\n".write(to: folder.appendingPathComponent("set.7z.txt"), atomically: true, encoding: .utf8)

        let volumes = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("set.7z.0") }.sorted()
        XCTAssertGreaterThanOrEqual(volumes.count, 3)
        let listing = try await engine.list(archive: folder.appendingPathComponent("set.7z.001"),
                                            password: nil, encodingCodePage: nil)
        XCTAssertEqual(listing.info.otherVolumes, Array(volumes.dropFirst()))
        XCTAssertEqual(listing.info.volumeCount, volumes.count)
    }

    func testAnArchiveInOneFileHasNoOtherVolumes() async throws {
        let archive = root.appendingPathComponent("one.zip")
        try await engine.create(archive: archive, items: [try blob(1_000)], options: CompressionOptions(formatKey: "zip"))
        // A file that only looks like a second volume.
        try "x".write(to: root.appendingPathComponent("one.z01"), atomically: true, encoding: .utf8)
        let listing = try await engine.list(archive: archive, password: nil, encodingCodePage: nil)
        XCTAssertEqual(listing.info.otherVolumes, [])
        XCTAssertNil(listing.info.volumeCount)
    }

    func testARarSetNamesItsOtherParts() async throws {
        try XCTSkipIf(EngineLocator.externalRAR == nil, "rar is not installed")
        let folder = root.appendingPathComponent("rar")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await RarEngine().create(archive: folder.appendingPathComponent("set.rar"), items: [try blob(300_000)],
                                     options: CompressionOptions(formatKey: "rar", level: 0, volumeSize: "100k"))
        let parts = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        let listing = try await engine.list(archive: folder.appendingPathComponent(parts[0]),
                                            password: nil, encodingCodePage: nil)
        XCTAssertEqual(listing.info.otherVolumes.sorted(), Array(parts.dropFirst()))
    }
}
