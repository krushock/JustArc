import Foundation

/// Folder-by-folder view of a flat entry list, which is how WinRAR presents an archive.
/// Directories implied only by file paths are synthesised, since many archives omit them.
public final class EntryTree {
    public final class Node {
        public let path: String
        public let name: String
        public let isDirectory: Bool
        public fileprivate(set) var entry: ArchiveEntry?
        public fileprivate(set) var children: [Node] = []
        public fileprivate(set) weak var parent: Node?

        init(path: String, name: String, isDirectory: Bool, entry: ArchiveEntry?) {
            self.path = path
            self.name = name
            self.isDirectory = isDirectory
            self.entry = entry
        }

        /// Recursive size of a folder, or the entry size for a file.
        public private(set) lazy var totalSize: UInt64 = {
            if !isDirectory { return entry?.size ?? 0 }
            return children.reduce(0) { $0.addingSaturating($1.totalSize) }
        }()

        public private(set) lazy var totalPacked: UInt64 = {
            if !isDirectory { return entry?.packedSize ?? 0 }
            return children.reduce(0) { $0.addingSaturating($1.totalPacked) }
        }()

        public private(set) lazy var fileCount: Int = {
            if !isDirectory { return 1 }
            return children.reduce(0) { $0 + $1.fileCount }
        }()

        /// Every file at or below this node, used when extracting a folder selection.
        public func descendantEntries() -> [ArchiveEntry] {
            var out: [ArchiveEntry] = []
            if let entry { out.append(entry) }
            for child in children { out.append(contentsOf: child.descendantEntries()) }
            return out
        }
    }

    public let root: Node
    private var index: [String: Node] = [:]

    public init(entries: [ArchiveEntry]) {
        root = Node(path: "", name: "", isDirectory: true, entry: nil)
        index[""] = root

        // Directories first so real directory entries win over synthesised ones.
        for entry in entries.sorted(by: { $0.isDirectory && !$1.isDirectory }) {
            insert(entry)
        }
        sortRecursively(root)
    }

    private func insert(_ entry: ArchiveEntry) {
        guard !entry.path.isEmpty, !ArchivePath.isTooDeep(entry.path) else { return }
        let components = entry.path.split(separator: "/").map(String.init)
        var currentPath = ""
        var parent = root

        for (offset, component) in components.enumerated() {
            let isLast = offset == components.count - 1
            currentPath = ArchivePath.join(currentPath, component)

            if let existing = index[currentPath] {
                if isLast, existing.isDirectory == entry.isDirectory, existing.entry == nil {
                    existing.entry = entry
                }
                parent = existing
                continue
            }

            let isDir = isLast ? entry.isDirectory : true
            let node = Node(path: currentPath,
                            name: component,
                            isDirectory: isDir,
                            entry: isLast ? entry : nil)
            node.parent = parent
            parent.children.append(node)
            index[currentPath] = node
            parent = node
        }
    }

    private func sortRecursively(_ node: Node) {
        node.children.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        for child in node.children { sortRecursively(child) }
    }

    public func node(at path: String) -> Node? {
        index[ArchivePath.normalize(path)]
    }

    public func children(at path: String) -> [Node] {
        node(at: path)?.children ?? []
    }

    /// True when the archive holds a single top-level item, which decides
    /// whether Quick Extract wraps the result in a folder.
    public var hasSingleRootItem: Bool {
        root.children.count == 1
    }

    public var rootItemName: String? {
        root.children.first?.name
    }
}
