import XCTest
@testable import JustArcCore

final class RubberBandSelectionTests: XCTestCase {
    func testAPlainDragReplacesTheSelection() {
        let result = RubberBandSelection.selection(initial: [0, 9], touched: [2, 3, 4], mode: .replace)
        XCTAssertEqual(result, [2, 3, 4])
    }

    func testShiftAddsToWhatWasSelected() {
        let result = RubberBandSelection.selection(initial: [0, 9], touched: [2, 3], mode: .add)
        XCTAssertEqual(result, [0, 2, 3, 9])
    }

    func testCommandFlipsEachTouchedRow() {
        let result = RubberBandSelection.selection(initial: [2, 3, 9], touched: [3, 4], mode: .toggle)
        XCTAssertEqual(result, [2, 4, 9])
    }

    func testShrinkingTheRectangleDropsRowsAgain() {
        // Each update starts from the selection at the start of the drag, so pulling
        // back deselects rather than leaving a trail.
        let initial: IndexSet = []
        _ = RubberBandSelection.selection(initial: initial, touched: [1, 2, 3, 4], mode: .replace)
        let later = RubberBandSelection.selection(initial: initial, touched: [1, 2], mode: .replace)
        XCTAssertEqual(later, [1, 2])
    }

    func testRowsThatCannotBeSelectedAreSkipped() {
        // Row 0 stands for the ".." row, which is not a file.
        let result = RubberBandSelection.selection(initial: [], touched: [0, 1, 2], mode: .replace,
                                                   selectable: { $0 != 0 })
        XCTAssertEqual(result, [1, 2])
    }

    func testModifierPrecedenceMatchesFinder() {
        XCTAssertEqual(RubberBandSelection.mode(shift: false, command: false), .replace)
        XCTAssertEqual(RubberBandSelection.mode(shift: true, command: false), .add)
        XCTAssertEqual(RubberBandSelection.mode(shift: false, command: true), .toggle)
        XCTAssertEqual(RubberBandSelection.mode(shift: true, command: true), .toggle)
    }

    func testTheRectangleIsTheSameWhicheverWayTheDragGoes() {
        let down = RubberBandSelection.rect(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 80))
        let up = RubberBandSelection.rect(from: CGPoint(x: 50, y: 80), to: CGPoint(x: 10, y: 10))
        XCTAssertEqual(down, up)
        XCTAssertEqual(down, CGRect(x: 10, y: 10, width: 40, height: 70))
    }

    func testSmallMovementsAreClicks() {
        XCTAssertFalse(RubberBandSelection.isDrag(from: .zero, to: CGPoint(x: 1, y: 1)))
        XCTAssertTrue(RubberBandSelection.isDrag(from: .zero, to: CGPoint(x: 0, y: 4)))
    }
}
