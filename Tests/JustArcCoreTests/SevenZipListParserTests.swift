import XCTest
@testable import JustArcCore

final class SevenZipListParserTests: XCTestCase {
    func testParsesArchivePropertiesAndEntries() {
        let sample = """
        7-Zip (z) 25.01 (arm64)

        Listing archive: demo.zip

        --
        Path = demo.zip
        Type = zip
        Physical Size = 4096

        ----------
        Path = payload
        Folder = +
        Size = 0
        Packed Size = 0
        Modified = 2026-09-17 19:00:00
        Attributes = D_ drwxr-xr-x
        CRC =
        Encrypted = -

        Path = payload/readme.txt
        Folder = -
        Size = 12
        Packed Size = 14
        Modified = 2026-09-17 19:01:30
        Attributes = A_ -rw-r--r--
        CRC = 3610A686
        Encrypted = +
        Method = Deflate

        """

        let listing = SevenZipListParser.parse(sample)
        XCTAssertEqual(listing.info.formatName, "zip")
        XCTAssertEqual(listing.info.physicalSize, 4096)
        XCTAssertEqual(listing.entries.count, 2)

        let folder = listing.entries[0]
        XCTAssertTrue(folder.isDirectory)
        XCTAssertEqual(folder.path, "payload")

        let file = listing.entries[1]
        XCTAssertFalse(file.isDirectory)
        XCTAssertEqual(file.size, 12)
        XCTAssertEqual(file.packedSize, 14)
        XCTAssertEqual(file.crc, "3610A686")
        XCTAssertEqual(file.method, "Deflate")
        XCTAssertTrue(file.isEncrypted)
        XCTAssertEqual(file.name, "readme.txt")
        XCTAssertEqual(file.parentPath, "payload")
        XCTAssertNotNil(file.modified)
        XCTAssertTrue(listing.containsEncryptedEntries)
    }

    func testHandlesValuesContainingEqualsSign() {
        let sample = """
        --
        Path = a.7z
        Type = 7z

        ----------
        Path = weird = name.txt
        Folder = -
        Size = 1

        """
        let listing = SevenZipListParser.parse(sample)
        XCTAssertEqual(listing.entries.first?.path, "weird = name.txt")
    }

    func testEmptyOutputProducesEmptyListing() {
        let listing = SevenZipListParser.parse("")
        XCTAssertTrue(listing.entries.isEmpty)
        XCTAssertEqual(listing.info.physicalSize, 0)
    }
}
