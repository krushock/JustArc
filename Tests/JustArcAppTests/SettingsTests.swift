import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import JustArc
@testable import JustArcCore

@MainActor
final class SettingsTests: XCTestCase {
    override func setUp() async throws {
        _ = NSApplication.shared
        ModalWatchdog.arm()
    }

    func testFileTypeRowsAreDistinctTypes() {
        let rows = FileAssociations.rows()
        XCTAssertGreaterThan(rows.count, 10)
        XCTAssertEqual(Set(rows.map(\.type.identifier)).count, rows.count,
                       "two rows share a type, so they would fight over one default app")
        XCTAssertEqual(rows.first { $0.kind.title == "ZIP" }?.type, .zip)
        // Disk images are listed, but "use JustArc for all" leaves them alone.
        XCTAssertEqual(rows.first { $0.kind.extensions == ["dmg"] }?.kind.isIncludedInAll, false)
    }

    func testCandidatesListTheCurrentDefault() {
        for row in FileAssociations.rows() {
            guard let current = FileAssociations.defaultApp(for: row.type) else { continue }
            XCTAssertTrue(FileAssociations.candidates(for: row.type).contains(current), row.kind.title)
        }
    }

    func testSettingsWindowBuildsEveryPane() throws {
        let controller = PreferencesWindowController()
        let tabs = try XCTUnwrap(controller.window?.contentViewController as? NSTabViewController)
        XCTAssertEqual(tabs.tabViewItems.count, 4)

        for (index, item) in tabs.tabViewItems.enumerated() {
            tabs.selectedTabViewItemIndex = index
            let view = try XCTUnwrap(item.viewController?.view)
            view.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(view.fittingSize.width, 300, item.label)
        }

        let fileTypes = try XCTUnwrap(tabs.tabViewItems.compactMap {
            $0.viewController as? FileTypesSettingsViewController }.first)
        let table = try XCTUnwrap(firstSubview(of: NSTableView.self, in: fileTypes.view))
        XCTAssertEqual(table.numberOfRows, FileAssociations.rows().count)
        // Every row has a menu of apps ending in "Other…".
        for row in 0..<table.numberOfRows {
            let popUp = try XCTUnwrap(table.view(atColumn: 1, row: row, makeIfNecessary: true) as? NSPopUpButton)
            XCTAssertEqual(popUp.lastItem?.title, L("Other…"))
            XCTAssertNotNil(popUp.selectedItem)
        }
        controller.window?.close()
    }

    func testADeclinedConfirmationIsNotAnError() {
        // What macOS returned when its "change the default app?" dialog was declined.
        let declined = NSError(domain: NSCocoaErrorDomain, code: 256, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -128),
        ])
        XCTAssertTrue(FileAssociations.isUserCancellation(declined))
        XCTAssertFalse(FileAssociations.isUserCancellation(
            NSError(domain: NSCocoaErrorDomain, code: 256, userInfo: nil)))
    }

    func testTheOldCheckboxCarriesOverToTheNewSetting() {
        let defaults = UserDefaults.standard
        let saved = (defaults.object(forKey: Preferences.Key.archiveOpenAction),
                     defaults.object(forKey: Preferences.Key.browseInsteadOfExtracting))
        defer {
            defaults.set(saved.0, forKey: Preferences.Key.archiveOpenAction)
            defaults.set(saved.1, forKey: Preferences.Key.browseInsteadOfExtracting)
        }

        defaults.removeObject(forKey: Preferences.Key.archiveOpenAction)
        defaults.removeObject(forKey: Preferences.Key.browseInsteadOfExtracting)
        XCTAssertEqual(Preferences.archiveOpenAction, .extract)

        defaults.set(true, forKey: Preferences.Key.browseInsteadOfExtracting)
        XCTAssertEqual(Preferences.archiveOpenAction, .browse)

        Preferences.archiveOpenAction = .ask
        XCTAssertEqual(Preferences.archiveOpenAction, .ask)
    }

    func testSavePanelOffersAZipEncryptionChoice() throws {
        let accessory = SaveOptionsAccessory()
        accessory.layoutSubtreeIfNeeded()
        XCTAssertFalse(SaveOptionsAccessory.availableFormats.contains { !$0.canWrite })
        XCTAssertEqual(accessory.options().zipEncryption, .aes256)
    }

    private func firstSubview<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        for subview in view.subviews {
            if let match = subview as? T { return match }
            if let match = firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }
}
