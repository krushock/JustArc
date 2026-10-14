import XCTest
@testable import JustArcCore

/// The system log keeps what JustArc did, not the names of what it did it to.
final class DiagnosticsTests: XCTestCase {
    func testInterpolatedValuesArePrivateUnlessMarkedPublic() {
        let name = "Tax Return 2025.zip"
        let message: DiagnosticsMessage = "opening \(name): \(public: 42) entries, exit \(public: Int32(0))"
        XCTAssertEqual(message.redacted, "opening <private>: 42 entries, exit 0")
        XCTAssertEqual(message.full, "opening Tax Return 2025.zip: 42 entries, exit 0")
        XCTAssertTrue(message.hasPrivateParts)
        // Written out too, so that `log show` can be seen to leave the name out.
        Diagnostics.log("diagnostics test: opening \(name), \(public: 42) entries")
    }

    func testAPlainMessageHasNothingToHide() {
        let message: DiagnosticsMessage = "updates: no SUFeedURL in the bundle"
        XCTAssertEqual(message.redacted, message.full)
        XCTAssertFalse(message.hasPrivateParts)
    }

    func testNoLogLineMarksAPathOrANamePublic() throws {
        // A path or a file name made public by mistake would put it back in the log.
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let file as URL in walker where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.components(separatedBy: "\n").enumerated() where line.contains("Diagnostics.log(") {
                // What is inside each \(public: …), up to its closing parenthesis.
                let publics = line.components(separatedBy: "\\(public: ").dropFirst()
                    .map { $0.prefix { $0 != ")" } }
                for expression in publics where expression.contains("path") || expression.contains("url")
                    || expression.contains("lastPathComponent") || expression.contains("error")
                    || expression == "archive" || expression.hasPrefix("archive.") || expression.hasPrefix("node") {
                    offenders.append("\(file.lastPathComponent):\(number + 1): \(expression)")
                }
            }
        }
        XCTAssertEqual(offenders, [])
    }
}
