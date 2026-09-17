import XCTest
@testable import JustArcCore

final class EntryTreeTests: XCTestCase {
    private var entries: [ArchiveEntry] {
        [
            ArchiveEntry(path: "payload/readme.txt", isDirectory: false, size: 12, packedSize: 10),
            ArchiveEntry(path: "payload/docs/notes.txt", isDirectory: false, size: 100, packedSize: 40),
            ArchiveEntry(path: "payload/docs", isDirectory: true),
        ]
    }

    func testSynthesisesMissingParentDirectories() {
        let tree = EntryTree(entries: [ArchiveEntry(path: "a/b/c/deep.txt", isDirectory: false, size: 5)])
        XCTAssertNotNil(tree.node(at: "a"))
        XCTAssertNotNil(tree.node(at: "a/b"))
        XCTAssertEqual(tree.node(at: "a/b/c")?.children.count, 1)
    }

    func testFoldersSortBeforeFiles() {
        let tree = EntryTree(entries: entries)
        let children = tree.children(at: "payload")
        XCTAssertEqual(children.map(\.name), ["docs", "readme.txt"])
    }

    func testFolderSizesAggregate() {
        let tree = EntryTree(entries: entries)
        XCTAssertEqual(tree.node(at: "payload")?.totalSize, 112)
        XCTAssertEqual(tree.node(at: "payload")?.totalPacked, 50)
        XCTAssertEqual(tree.node(at: "payload")?.fileCount, 2)
    }

    func testDescendantEntriesExpandsAFolderSelection() {
        let tree = EntryTree(entries: entries)
        let paths = Set(tree.node(at: "payload")!.descendantEntries().map(\.path))
        XCTAssertEqual(paths, ["payload/readme.txt", "payload/docs/notes.txt", "payload/docs"])
    }

    func testSingleRootItemDetection() {
        XCTAssertTrue(EntryTree(entries: entries).hasSingleRootItem)
        let multi = EntryTree(entries: [
            ArchiveEntry(path: "a.txt", isDirectory: false),
            ArchiveEntry(path: "b.txt", isDirectory: false),
        ])
        XCTAssertFalse(multi.hasSingleRootItem)
    }
}
