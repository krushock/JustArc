import XCTest
@testable import JustArcCore

/// The tests run as the website edition, unsandboxed, with everything on. The App
/// Store edition is checked by building it: `Scripts/build-app.sh --app-store`
/// refuses to finish if Sparkle is still linked.
final class DistributionTests: XCTestCase {
    func testTheWebsiteEditionHasEverything() {
        XCTAssertFalse(Distribution.isAppStoreBuild)
        XCTAssertFalse(Distribution.isSandboxed)
        XCTAssertTrue(Distribution.mountsDiskImages)
        XCTAssertTrue(Distribution.writesRAR)
        XCTAssertTrue(Distribution.updatesItself)
        XCTAssertNotNil(FormatRegistry.format(forKey: "dmg"))
        XCTAssertTrue(AssociableFileType.all.contains { $0.extensions == ["dmg"] })
    }
}
