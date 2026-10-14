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
        // A volume is named for its set.
        XCTAssertEqual(FormatRegistry.baseName(for: URL(fileURLWithPath: "/x/photos.7z.001")), "photos")
        XCTAssertEqual(FormatRegistry.baseName(for: URL(fileURLWithPath: "/x/photos.zip.002")), "photos")
        XCTAssertEqual(FormatRegistry.baseName(for: URL(fileURLWithPath: "/x/photos.part1.rar")), "photos")
        XCTAssertEqual(FormatRegistry.baseName(for: URL(fileURLWithPath: "/x/photos.part01.RAR")), "photos")
        XCTAssertEqual(FormatRegistry.baseName(for: URL(fileURLWithPath: "/x/backup.001")), "backup")
    }

    func testWritableFormatsAreOfferedInOrder() {
        let keys = FormatRegistry.writable.map(\.key)
        XCTAssertEqual(keys.first, "zip")
        XCTAssertTrue(keys.contains("7z"))
        XCTAssertFalse(keys.contains("iso"))
    }

    func testOnlyFormatsThatCanBeWrittenAreOffered() {
        for format in FormatRegistry.writable {
            XCTAssertTrue(format.canWrite, "\(format.key) is offered for saving but cannot be written")
        }
        // 7-Zip reads Zstandard but has no encoder for it.
        XCTAssertFalse(FormatRegistry.writable.contains { $0.key == "zstd" || $0.key == "tzst" })
    }

    func testCompressedTarsCanBeEditedInPlace() {
        for key in ["tgz", "tbz2", "txz"] {
            XCTAssertEqual(FormatRegistry.format(forKey: key)?.canEditInPlace, true, key)
        }
    }

    func testEveryAssociableTypeIsOneJustArcReads() {
        for kind in AssociableFileType.all {
            for ext in kind.extensions {
                XCTAssertTrue(FormatRegistry.isArchive(URL(fileURLWithPath: "/x/a.\(ext)")),
                              ".\(ext) is offered in Settings but JustArc does not read it")
            }
        }
    }
}
