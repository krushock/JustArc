import XCTest
@testable import JustArcCore

final class FormatRegistryTests: XCTestCase {
    func testLongestSuffixWins() {
        XCTAssertEqual(FormatRegistry.format(for: URL(fileURLWithPath: "/x/site.tar.gz"))?.key, "tgz")
        XCTAssertEqual(FormatRegistry.format(for: URL(fileURLWithPath: "/x/site.gz"))?.key, "gzip")
        XCTAssertEqual(FormatRegistry.format(for: URL(fileURLWithPath: "/x/a.tar.zst"))?.key, "tzst")
        XCTAssertEqual(FormatRegistry.format(for: URL(fileURLWithPath: "/x/App.ipa"))?.key, "zip")
        XCTAssertNil(FormatRegistry.format(for: URL(fileURLWithPath: "/x/notes.txt")))
    }

    func testBaseNameStripsCompoundExtensions() {
        XCTAssertEqual(FormatRegistry.baseName(for: URL(fileURLWithPath: "/x/site.tar.gz")), "site")
        XCTAssertEqual(FormatRegistry.baseName(for: URL(fileURLWithPath: "/x/photos.zip")), "photos")
        XCTAssertEqual(FormatRegistry.baseName(for: URL(fileURLWithPath: "/x/archive.7z")), "archive")
    }

    func testWritableFormatsAreOfferedInOrder() {
        let keys = FormatRegistry.writable.map(\.key)
        XCTAssertEqual(keys.first, "zip")
        XCTAssertTrue(keys.contains("7z"))
        XCTAssertFalse(keys.contains("iso"))
    }
}
