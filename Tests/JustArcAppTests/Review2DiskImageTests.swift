import AppKit
import XCTest
@testable import JustArc
@testable import JustArcCore

@MainActor
final class Review2DiskImageTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        _ = NSApplication.shared
        ModalWatchdog.arm()
        root = try Review2.makeRoot()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("payload"),
                                                withIntermediateDirectories: true)
        try "hello\n".write(to: root.appendingPathComponent("payload/a.txt"), atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// E9: the window may be closed while the image is still being attached, and the
    /// release that closing performs runs before there is anything to release.
    func testADiskImageWindowClosedWhileStillAttachingLeavesTheImageAttached() async throws {
        let image = root.appendingPathComponent("image.dmg")
        try await DMGEngine().create(archive: image, items: [root.appendingPathComponent("payload")],
                                     options: CompressionOptions(formatKey: "dmg"),
                                     cancellation: nil, progress: nil)
        XCTAssertNil(DMGMountRegistry.shared.existing(for: image))
        defer { DMGEngine().release(archive: image) }

        var controller: ArchiveWindowController? = ArchiveWindowController(archive: image)
        let window = try XCTUnwrap(controller?.window)
        controller?.loadArchive()
        // The list still says "Reading the archive…" and the user closes the window.
        try await Task.sleep(nanoseconds: 30_000_000)
        let mayClose = controller!.windowShouldClose(window)
        print("E9 windowShouldClose while the image is attaching:", mayClose,
              "attached yet:", DMGMountRegistry.shared.existing(for: image) != nil)
        XCTAssertTrue(mayClose)
        window.close()
        controller = nil

        // Give the attach, and the background release, time to finish.
        try await Task.sleep(nanoseconds: 4_000_000_000)
        let leftover = DMGMountRegistry.shared.existing(for: image)
        let live = leftover?.mountPoints.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } ?? false
        print("E9 four seconds after the window closed: still registered =", leftover != nil,
              "mount point live =", live, leftover?.mountPoints.map(\.path) ?? [])
        XCTAssertNil(leftover, "the image is attached and no window owns it; nothing detaches it until the app quits")
    }
}
