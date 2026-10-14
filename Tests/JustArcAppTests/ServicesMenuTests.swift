import AppKit
import XCTest
@testable import JustArc
@testable import JustArcCore

/// The entries JustArc puts in the Finder's right-click menu.
@MainActor
final class ServicesMenuTests: XCTestCase {
    private func resource(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/JustArc/Resources").appendingPathComponent(relative)
    }

    private func services() throws -> [[String: Any]] {
        let data = try Data(contentsOf: resource("Info.plist"))
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        return try XCTUnwrap(plist["NSServices"] as? [[String: Any]])
    }

    private func title(_ service: [String: Any]) -> String? {
        (service["NSMenuItem"] as? [String: String])?["default"]
    }

    func testCompressingOpensAWindowAndIsShownWithoutBeingTurnedOn() throws {
        let all = try services()
        let compress = try XCTUnwrap(all.first { title($0) == "Compress with JustArc" })
        XCTAssertEqual(compress["NSMessage"] as? String, "compressSelectionInWindow")
        XCTAssertNotNil(compress["NSRequiredContext"], "without it macOS leaves the service off and out of the menu")
        XCTAssertEqual(compress["NSSendFileTypes"] as? [String], ["public.item"])

        let quick = try XCTUnwrap(all.first { title($0) == "Quick Compress with JustArc" })
        XCTAssertEqual(quick["NSMessage"] as? String, "compressSelection")
        XCTAssertNil(quick["NSRequiredContext"], "the one that writes at once is off until asked for")

        for name in ["Extract with JustArc", "Open Archive in JustArc"] {
            let service = try XCTUnwrap(all.first { title($0) == name })
            XCTAssertNotNil(service["NSRequiredContext"], name)
        }
    }

    func testEveryServiceReachesAHandlerAndHasItsTitleTranslated() throws {
        for service in try services() {
            let name = try XCTUnwrap(title(service))
            let message = try XCTUnwrap(service["NSMessage"] as? String)
            XCTAssertTrue(ServicesProvider.instancesRespond(to: NSSelectorFromString("\(message):userData:error:")),
                          "\(name) calls \(message), which ServicesProvider does not have")
            XCTAssertEqual(service["NSPortName"] as? String, "JustArc")
            for language in ["en", "ru"] {
                let strings = try XCTUnwrap(NSDictionary(contentsOf: resource("\(language).lproj/ServicesMenu.strings")))
                XCTAssertNotNil(strings[name], "\(name) has no \(language) title")
            }
        }
    }

    func testCompressWithJustArcStagesTheSelectionInANewWindow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("justarc-services-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.txt")
        try "notes\n".write(to: file, atomically: true, encoding: .utf8)

        var staged: [URL] = []
        var jobs = 0
        let provider = ServicesProvider(quickExtract: QuickExtractCoordinator(),
                                        beginJob: { jobs += 1 }, endJob: { jobs -= 1 },
                                        openInBrowser: { _ in XCTFail("nothing is opened") },
                                        stageIntoNewWindow: { staged = $0 })
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("justarc-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([root.appendingPathComponent("folder") as NSURL, file as NSURL])
        var error: NSString = ""
        provider.compressSelectionInWindow(pasteboard, userData: nil, error: &error)

        XCTAssertEqual(error, "")
        XCTAssertEqual(staged.map(\.lastPathComponent), ["folder", "notes.txt"])
        XCTAssertEqual(jobs, 0, "the app is let go again once the window has them")
        pasteboard.releaseGlobally()
    }
}
