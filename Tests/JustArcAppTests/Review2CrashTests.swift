import AppKit
import XCTest
@testable import JustArc
@testable import JustArcCore

/// Kept apart from the rest: if the defect is there, this one takes the test process down.
@MainActor
final class Review2CrashTests: XCTestCase {
    func testSelectingTwoEntriesWithEnormousDeclaredSizesDoesNotTrap() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        _ = NSApplication.shared
        ModalWatchdog.arm()
        let root = try Review2.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("sizes.zip")
        // Two stored, empty files whose central directory claims, through a zip64
        // field, that each expands to almost 2^64 bytes.
        let script = """
        import struct, sys
        names = [b'a.bin', b'b.bin']
        out = b''; central = b''
        data = bytes([3, 0])
        big = 0xFFFFFFFFFFFFFFF0
        for name in names:
            offset = len(out)
            lextra = struct.pack('<HHQQ', 1, 16, big, len(data))
            out += struct.pack('<IHHHHHIIIHH', 0x04034b50, 45, 0, 8, 0, 0x21, 0, 0xFFFFFFFF, 0xFFFFFFFF,
                               len(name), len(lextra)) + name + lextra + data
            extra = struct.pack('<HHQ', 1, 8, big)
            central += struct.pack('<IHHHHHHIIIHHHHHII', 0x02014b50, 45, 45, 0, 8, 0, 0x21, 0, len(data), 0xFFFFFFFF,
                                   len(name), len(extra), 0, 0, 0, 0, offset) + name + extra
        eocd = struct.pack('<IHHHHIIH', 0x06054b50, 0, 0, len(names), len(names), len(central), len(out), 0)
        open(sys.argv[1], 'wb').write(out + central + eocd)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", script, archive.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let browser = ArchiveBrowserViewController(session: ArchiveSession(archiveURL: archive))
        let window = Review2.host(browser)
        defer { window.close() }
        browser.loadArchive()
        try await Review2.waitFor("load") { browser.hasLoadedOnce }
        print("S entries:", browser.session.listing.entries.map { "\($0.path) size=\($0.size)" })
        XCTAssertEqual(browser.session.listing.entries.count, 2)

        let table = try XCTUnwrap(Review2.allSubviews(of: NSOutlineView.self, in: browser.view).first)
        print("S selecting both rows (Select All)…")
        table.selectAll(nil)
        print("S survived; selected rows:", table.selectedRowIndexes.count)
    }
}
