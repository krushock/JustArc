import AppKit
import XCTest
@testable import JustArc
@testable import JustArcCore

/// Settings ▸ Extraction ▸ "Move the archive to the Trash after extracting".
@MainActor
final class QuickExtractTrashTests: XCTestCase {
    private var root: URL!
    private var trashed: [String] = []
    private var saved: (trash: Bool, reveal: Bool, quit: Bool)!
    private var realTrash: ((URL) throws -> Void)!

    override func setUp() async throws {
        _ = NSApplication.shared
        ModalWatchdog.arm()
        Preferences.registerDefaults()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("justarc-trash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        saved = (Preferences.moveArchiveToTrash, Preferences.revealInFinder, Preferences.quitAfterQuickExtract)
        Preferences.revealInFinder = false
        Preferences.quitAfterQuickExtract = false
        // Not the real Trash.
        realTrash = QuickExtractCoordinator.trash
        trashed = []
        QuickExtractCoordinator.trash = { [unowned self] url in
            trashed.append(url.lastPathComponent)
            try FileManager.default.removeItem(at: url)
        }
    }

    override func tearDown() async throws {
        QuickExtractCoordinator.trash = realTrash
        Preferences.moveArchiveToTrash = saved.trash
        Preferences.revealInFinder = saved.reveal
        Preferences.quitAfterQuickExtract = saved.quit
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSplitArchive() async throws -> URL {
        let payload = root.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        var data = Data(count: 250_000)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, 250_000) }
        try data.write(to: payload.appendingPathComponent("photo.raw"))
        try "notes\n".write(to: payload.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let folder = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await SevenZipEngine().create(archive: folder.appendingPathComponent("photos.7z"), items: [payload],
                                          options: CompressionOptions(formatKey: "7z", level: 0, volumeSize: "100k"))
        return folder.appendingPathComponent("photos.7z.001")
    }

    private func extract(_ archive: URL) async throws {
        let coordinator = QuickExtractCoordinator()
        coordinator.enqueue([archive])
        let deadline = Date().addingTimeInterval(30)
        while coordinator.hasActiveJobs {
            guard Date() < deadline else { return XCTFail("the extraction did not finish") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func testEveryVolumeOfASplitArchiveGoesToTheTrash() async throws {
        Preferences.moveArchiveToTrash = true
        let archive = try await makeSplitArchive()
        let folder = archive.deletingLastPathComponent()
        try await extract(archive)

        let volumes = trashed.filter { $0.hasPrefix("photos.7z.0") }
        XCTAssertEqual(trashed, volumes)
        XCTAssertGreaterThanOrEqual(volumes.count, 3)
        XCTAssertEqual(volumes.first, "photos.7z.001")
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(left, ["payload"], "the extracted folder is all that is left")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("payload/notes.txt").path))
    }

    func testWithTheSettingOffNothingGoes() async throws {
        Preferences.moveArchiveToTrash = false
        let archive = try await makeSplitArchive()
        try await extract(archive)
        XCTAssertEqual(trashed, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
    }
}
