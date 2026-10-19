import XCTest
@testable import JustArcCore

final class OpenRoutingTests: XCTestCase {
    private func action(_ setting: ArchiveOpenAction, from source: OpenSource = .finder,
                        window: Bool = false, option: Bool = false) -> ArchiveOpenAction {
        OpenRouting.action(setting: setting, source: source,
                           hasVisibleBrowserWindow: window, optionHeld: option)
    }

    func testDoubleClickFollowsTheSetting() {
        XCTAssertEqual(action(.extract), .extract)
        XCTAssertEqual(action(.browse), .browse)
        XCTAssertEqual(action(.ask), .ask)
    }

    /// The Dock sends one request for a drop on JustArc's icon and for a click in its
    /// Downloads stack, and the click is an ordinary open, so both follow the setting.
    func testOpeningFromTheDockFollowsTheSetting() {
        for setting in ArchiveOpenAction.allCases {
            XCTAssertEqual(action(setting, from: .dock), setting, "\(setting)")
        }
    }

    func testAnOpenWindowMeansTheUserIsWorkingInTheApp() {
        for setting in ArchiveOpenAction.allCases {
            XCTAssertEqual(action(setting, window: true), .browse, "\(setting)")
        }
    }

    func testOptionDoesTheOtherThing() {
        XCTAssertEqual(action(.extract, option: true), .browse)
        XCTAssertEqual(action(.browse, option: true), .extract)
        XCTAssertEqual(action(.ask, option: true), .browse, "Option answers the question")
        XCTAssertEqual(action(.extract, from: .dock, option: true), .browse)
    }

    func testOtherSourcesBehaveLikeADoubleClick() {
        XCTAssertEqual(action(.extract, from: .other), .extract)
        XCTAssertEqual(action(.browse, from: .other), .browse)
    }
}

final class MacMetadataTests: XCTestCase {
    func testRecognisesWhatMacOSAdds() {
        XCTAssertTrue(MacMetadata.isMetadata(path: "__MACOSX"))
        XCTAssertTrue(MacMetadata.isMetadata(path: "__MACOSX/Project/._readme.txt"))
        XCTAssertTrue(MacMetadata.isMetadata(path: "Project/__MACOSX/x"))
        XCTAssertTrue(MacMetadata.isMetadata(path: "Project/._readme.txt"))
        XCTAssertTrue(MacMetadata.isMetadata(path: "._Project"))
    }

    func testLeavesOrdinaryFilesAlone() {
        XCTAssertFalse(MacMetadata.isMetadata(path: "Project/readme.txt"))
        XCTAssertFalse(MacMetadata.isMetadata(path: "Project/.gitignore"))
        XCTAssertFalse(MacMetadata.isMetadata(path: "Project/.DS_Store"))
        XCTAssertFalse(MacMetadata.isMetadata(path: "._hidden/notes.txt"), "only a file is AppleDouble")
        XCTAssertFalse(MacMetadata.isMetadata(path: "MACOSX/readme.txt"))
    }
}
