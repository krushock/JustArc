import AppKit
import XCTest
@testable import JustArc
@testable import JustArcCore

/// The App Store edition asks once for each folder it has to write in, and keeps
/// the answer. The tests run unsandboxed, so the sandbox's say is played by a
/// stand-in that refuses everything.
@MainActor
final class FolderAccessTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var asked: [String] = []
    private var refused: [String] = []

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("justarc-access-\(UUID().uuidString)")
        for folder in ["Downloads/Inner", "Elsewhere"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        suite = "justarc-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        asked = []
        refused = []
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    /// A sandboxed FolderAccess that may write nowhere by itself, and whose user
    /// answers each question with `answer`.
    private func sandboxed(answering answer: URL?) -> FolderAccess {
        let access = FolderAccess(defaults: defaults, isSandboxed: true)
        access.mayWrite = { _ in false }
        access.askForFolder = { [unowned self] folder, _ in
            asked.append(folder.lastPathComponent)
            return answer
        }
        access.refuse = { [unowned self] name in refused.append(name) }
        return access
    }

    func testAFolderIsAskedForOnceAndCoversWhatIsInside() {
        let downloads = root.appendingPathComponent("Downloads")
        let access = sandboxed(answering: downloads)
        XCTAssertTrue(access.ensure(downloads, reason: "Extracting."))
        XCTAssertTrue(access.ensure(downloads.appendingPathComponent("Inner"), reason: "Extracting."))
        XCTAssertTrue(access.ensure(downloads, reason: "Extracting."))
        XCTAssertEqual(asked, ["Downloads"], "asked again for a folder already granted")
        XCTAssertEqual(access.grantedFolders.map(\.lastPathComponent), ["Downloads"])
    }

    func testAGrantOutlastsTheAppBeingQuit() {
        let downloads = root.appendingPathComponent("Downloads")
        XCTAssertTrue(sandboxed(answering: downloads).ensure(downloads, reason: "Extracting."))
        // The next launch reads the same settings.
        let later = sandboxed(answering: nil)
        XCTAssertTrue(later.ensure(downloads.appendingPathComponent("Inner"), reason: "Extracting."))
        XCTAssertEqual(asked, ["Downloads"], "the grant was forgotten")
    }

    func testDecliningOrChoosingTheWrongFolderWritesNothing() {
        let downloads = root.appendingPathComponent("Downloads")
        XCTAssertFalse(sandboxed(answering: nil).ensure(downloads, reason: "Extracting."))
        XCTAssertFalse(sandboxed(answering: root.appendingPathComponent("Elsewhere")).ensure(downloads, reason: "Extracting."))
        XCTAssertEqual(refused, ["Downloads"], "choosing a folder that does not hold it is said to be wrong")
        XCTAssertTrue(sandboxed(answering: nil).grantedFolders.isEmpty)
    }

    func testAFolderCanBeTakenBackInSettings() {
        let downloads = root.appendingPathComponent("Downloads")
        let access = sandboxed(answering: downloads)
        access.ensure(downloads, reason: "Extracting.")
        access.revoke(downloads)
        XCTAssertTrue(access.grantedFolders.isEmpty)
        XCTAssertFalse(sandboxed(answering: nil).ensure(downloads, reason: "Extracting."))
    }

    func testOutsideTheSandboxNothingIsAsked() {
        let access = FolderAccess(defaults: defaults, isSandboxed: false)
        access.askForFolder = { [unowned self] folder, _ in asked.append(folder.lastPathComponent); return nil }
        XCTAssertTrue(access.ensure(root.appendingPathComponent("Elsewhere"), reason: "Extracting."))
        XCTAssertEqual(asked, [])
    }

    func testFoldersAreComparedWithLinksFollowed() throws {
        let real = root.appendingPathComponent("Downloads")
        let link = root.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertTrue(FolderAccess.contains(real, link.appendingPathComponent("Inner")))
        XCTAssertFalse(FolderAccess.contains(real, root.appendingPathComponent("Downloads2")))
    }

    func testVolumesAreRecognisedByTheirNames() {
        for name in ["a.7z.001", "a.zip.002", "a.part1.rar", "a.PART12.RAR", "a.r00"] {
            XCTAssertTrue(FormatRegistry.isVolumeName(URL(fileURLWithPath: "/x/" + name)), name)
        }
        for name in ["a.7z", "a.rar", "a.zip", "partial.rar", "a.r"] {
            XCTAssertFalse(FormatRegistry.isVolumeName(URL(fileURLWithPath: "/x/" + name)), name)
        }
    }
}
