import AppKit

/// A plain view that takes files dropped on it.
///
/// The file list accepts drops itself, but it is not the only thing in the window:
/// the "Drop files here" message, the status bar and the sidebar sit beside it, not
/// inside it, and a drop that lands on one of them finds no taker unless something
/// behind them is listening too.
final class FileDropView: NSView {
    /// Whether these files would be accepted right now.
    var canAccept: (([URL]) -> Bool)?
    /// Takes the files. Returns false when nothing was done with them.
    var onDrop: (([URL]) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    static func fileURLs(from info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    private func operation(for info: NSDraggingInfo) -> NSDragOperation {
        let urls = Self.fileURLs(from: info)
        guard !urls.isEmpty, canAccept?(urls) ?? true else { return [] }
        return .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        operation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        operation(for: sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(from: sender)
        guard !urls.isEmpty, canAccept?(urls) ?? true else { return false }
        return onDrop?(urls) ?? false
    }
}
