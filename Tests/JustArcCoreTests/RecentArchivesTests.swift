import XCTest
@testable import JustArcCore

final class RecentArchivesTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var folder: URL!

    override func setUpWithError() throws {
        suite = "justarc-recents-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("recents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    private func archive(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    func testNewestComesFirst() throws {
        let store = RecentArchives(defaults: defaults)
        let first = try archive("a.zip")
        let second = try archive("b.7z")
        store.note(first)
        store.note(second)
        XCTAssertEqual(store.urls.map(\.lastPathComponent), ["b.7z", "a.zip"])
    }

    func testReopeningMovesAnArchiveToTheTopWithoutDuplicating() throws {
        let store = RecentArchives(defaults: defaults)
        let first = try archive("a.zip")
        let second = try archive("b.7z")
        store.note(first)
        store.note(second)
        store.note(first)
        XCTAssertEqual(store.urls.map(\.lastPathComponent), ["a.zip", "b.7z"])
    }

    func testTheListIsCapped() throws {
        let store = RecentArchives(defaults: defaults, limit: 3)
        for index in 0..<5 { store.note(try archive("\(index).zip")) }
        XCTAssertEqual(store.urls.map(\.lastPathComponent), ["4.zip", "3.zip", "2.zip"])
    }

    func testArchivesThatWereMovedAwayAreNotOffered() throws {
        let store = RecentArchives(defaults: defaults)
        let gone = try archive("gone.zip")
        store.note(gone)
        try FileManager.default.removeItem(at: gone)
        XCTAssertTrue(store.urls.isEmpty, "a menu item that fails to open is worse than none")
    }

    func testClearAndRemove() throws {
        let store = RecentArchives(defaults: defaults)
        let first = try archive("a.zip")
        let second = try archive("b.zip")
        store.note(first)
        store.note(second)
        store.remove(second)
        XCTAssertEqual(store.urls.map(\.lastPathComponent), ["a.zip"])
        store.clear()
        XCTAssertTrue(store.urls.isEmpty)
    }

    func testChangesAreAnnounced() throws {
        let store = RecentArchives(defaults: defaults)
        let expectation = expectation(forNotification: RecentArchives.didChange, object: store)
        store.note(try archive("a.zip"))
        wait(for: [expectation], timeout: 1)
    }
}
