import Foundation
import CoreGraphics

/// The arithmetic behind dragging a selection rectangle across a list, kept apart
/// from the view so it can be tested.
///
/// It follows what Finder and the desktop do with the modifier held when the drag
/// starts: nothing replaces the selection with the rows touched, Shift adds them to
/// what was selected, and Command flips each touched row.
public enum RubberBandSelection {
    public enum Mode: Sendable {
        case replace
        case add
        case toggle
    }

    public static func mode(shift: Bool, command: Bool) -> Mode {
        if command { return .toggle }
        if shift { return .add }
        return .replace
    }

    /// - Parameters:
    ///   - initial: the selection when the drag began.
    ///   - touched: the rows the rectangle currently covers.
    ///   - selectable: rows that may be selected at all, such as everything but "..".
    public static func selection(initial: IndexSet,
                                 touched: IndexSet,
                                 mode: Mode,
                                 selectable: (Int) -> Bool = { _ in true }) -> IndexSet {
        var hits = IndexSet()
        for row in touched where selectable(row) { hits.insert(row) }
        switch mode {
        case .replace: return hits
        case .add: return initial.union(hits)
        case .toggle: return initial.symmetricDifference(hits)
        }
    }

    /// The rectangle between where the drag started and where the pointer is now,
    /// whichever way it went.
    public static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x),
               y: min(start.y, end.y),
               width: abs(end.x - start.x),
               height: abs(end.y - start.y))
    }

    /// Movement smaller than this is a click with a slightly unsteady hand, not a drag.
    public static let dragThreshold: CGFloat = 3

    public static func isDrag(from start: CGPoint, to end: CGPoint) -> Bool {
        hypot(end.x - start.x, end.y - start.y) >= dragThreshold
    }
}
