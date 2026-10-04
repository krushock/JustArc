import XCTest
@testable import JustArcCore
import SevenZipBridge

final class SevenZipLibraryTests: XCTestCase {
    func testTheLibraryLoadsInProcess() throws {
        try SevenZipLibrary.ensureLoaded()
        XCTAssertEqual(SevenZipLibrary.version, "25.01")
    }

    func testTheExpectedFormatsAreAvailable() throws {
        let names = Set(SevenZipLibrary.formatNames.map { $0.lowercased() })
        for expected in ["7z", "zip", "rar", "rar5", "tar", "gzip", "bzip2", "xz", "iso", "cab"] {
            XCTAssertTrue(names.contains(expected), "missing \(expected); have \(names.sorted())")
        }
        let writable = Set(SevenZipLibrary.writableFormatNames.map { $0.lowercased() })
        for expected in ["7z", "zip", "tar", "gzip", "bzip2", "xz"] {
            XCTAssertTrue(writable.contains(expected), "cannot write \(expected); can write \(writable.sorted())")
        }
    }

    func testABridgeOpenListsARealArchive() async throws {
        try SevenZipLibrary.ensureLoaded()
        let (root, archive) = try await FixtureBuilder.makeArchive(named: "bridge.zip")
        defer { FixtureBuilder.cleanup(root) }

        var error = SZError()
        var options = SZOpenOptions(password: nil, extensionHint: nil, codePage: -1, fallbackCodePage: 0)
        guard let handle = archive.path.withCString({ sz_open($0, &options, &error) }) else {
            return XCTFail("open failed: \(BridgeError.message(from: &error))")
        }
        defer { sz_close(handle) }

        var info = SZArchiveInfo()
        sz_archive_info(handle, &info)
        XCTAssertEqual(String(cString: info.formatName), "zip")

        var paths: [String] = []
        for index in 0..<sz_item_count(handle) {
            var item = SZItem()
            XCTAssertTrue(sz_item(handle, index, &item))
            paths.append(String(cString: item.path))
        }
        XCTAssertTrue(paths.contains("payload/readme.txt"), "\(paths)")
    }
}
