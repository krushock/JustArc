import XCTest
@testable import JustArcCore

final class CloudFileTests: XCTestCase {
    func testOrdinaryFilesAreNotTreatedAsCloudPlaceholders() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-\(UUID().uuidString).txt")
        try "on disk\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let status = CloudFile.status(of: file)
        XCTAssertFalse(status.needsDownload)
        XCTAssertTrue(status.isMaterialized)
    }

    func testMaterializingAnOrdinaryFileDoesNothing() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-\(UUID().uuidString).txt")
        try "on disk\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        // Must return promptly and must not throw.
        let start = Date()
        try await CloudFile.materialize(file)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testProviderNameIsReadFromTheCloudStoragePath() {
        let drive = URL(fileURLWithPath:
            "/Users/someone/Library/CloudStorage/GoogleDrive-someone@example.com/My Drive/a.zip")
        XCTAssertEqual(CloudFile.providerName(for: drive), "Google Drive")

        let dropbox = URL(fileURLWithPath:
            "/Users/someone/Library/CloudStorage/Dropbox/a.zip")
        XCTAssertEqual(CloudFile.providerName(for: dropbox), "Dropbox")

        let oneDrive = URL(fileURLWithPath:
            "/Users/someone/Library/CloudStorage/OneDrive-Personal/a.zip")
        XCTAssertEqual(CloudFile.providerName(for: oneDrive), "One Drive")

        let iCloud = URL(fileURLWithPath:
            "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/a.zip")
        XCTAssertEqual(CloudFile.providerName(for: iCloud), "iCloud Drive")

        XCTAssertNil(CloudFile.providerName(for: URL(fileURLWithPath: "/Users/someone/Downloads/a.zip")))
    }

    func testRunTogetherVendorNamesAreSpaced() {
        XCTAssertEqual(CloudFile.spaced("GoogleDrive"), "Google Drive")
        XCTAssertEqual(CloudFile.spaced("Dropbox"), "Dropbox")
        XCTAssertEqual(CloudFile.spaced("Box"), "Box")
        XCTAssertEqual(CloudFile.spaced("pCloudDrive"), "p Cloud Drive")
    }

    func testMaterializeAllSkipsMissingItems() async throws {
        let missing = URL(fileURLWithPath: "/tmp/justarc-absent-\(UUID().uuidString)")
        try await CloudFile.materializeAll([missing])
    }

    func testCancellationTokenFiresRegisteredHandlers() {
        let token = CancellationToken()
        var fired = false
        token.onCancel { fired = true }
        XCTAssertFalse(fired)
        token.cancel()
        XCTAssertTrue(fired)
    }

    func testHandlerRegisteredAfterCancellationFiresImmediately() {
        let token = CancellationToken()
        token.cancel()
        var fired = false
        token.onCancel { fired = true }
        XCTAssertTrue(fired, "a late observer must not wait forever")
    }
}

extension CloudFileTests {
    func testTheErrorNamesTheFileAndTheProviderAndSaysWhatToDo() {
        let url = URL(fileURLWithPath:
            "/Users/someone/Library/CloudStorage/GoogleDrive-a@b.com/My Drive/report.zip")
        let status = CloudFile.status(of: url)
        let error = CloudFile.notDownloadedError(url, status: status, reason: nil)

        let message = error.localizedDescription
        XCTAssertTrue(message.contains("report.zip"), message)
        XCTAssertTrue(message.contains("Google Drive"), message)
        XCTAssertTrue(message.lowercased().contains("finder"),
                      "the message should say how to fix it: \(message)")
        // The old failure surfaced a bare errno, which told the user nothing.
        XCTAssertFalse(message.contains("errno"), message)
    }

    func testTheProviderReasonIsAppendedWhenThereIsOne() {
        let url = URL(fileURLWithPath:
            "/Users/someone/Library/CloudStorage/Dropbox/report.zip")
        let error = CloudFile.notDownloadedError(url, status: CloudFile.status(of: url),
                                                 reason: "The server is unreachable.")
        XCTAssertTrue(error.localizedDescription.contains("The server is unreachable."))
    }
}
