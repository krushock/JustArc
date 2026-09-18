import AppKit
import JustArcCore

/// The source list down the left of the window.
///
/// Created through `NSSplitViewItem(sidebarWithViewController:)`, which is what gives
/// it the system sidebar material. On macOS 26 and later that material is what puts
/// the window's content behind the glass of the toolbar above it.
@MainActor
final class SidebarViewController: NSViewController {
    private let tree = FolderTreeView()
    private let scrollView = NSScrollView()

    var onSelect: ((String) -> Void)?

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = tree.outlineView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        tree.scrollView = scrollView

        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        tree.onSelect = { [weak self] path in self?.onSelect?(path) }
    }

    func reload(tree treeModel: EntryTree, archiveName: String) {
        loadViewIfNeeded()
        tree.reload(tree: treeModel, archiveName: archiveName)
    }

    func select(path: String) {
        loadViewIfNeeded()
        tree.select(path: path)
    }
}
