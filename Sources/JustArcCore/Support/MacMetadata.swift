import Foundation

/// The bookkeeping macOS adds to archives it creates: a `__MACOSX` folder in zips and
/// `._name` AppleDouble files beside the real ones in tars. They hold extended
/// attributes and resource forks, and are noise to anyone looking at the archive.
///
/// They also change what an archive looks like it holds: a zip of one folder has two
/// items at its root once `__MACOSX` is counted, which would make Quick Extract wrap
/// it in a second folder.
public enum MacMetadata {
    public static func isMetadata(path: String) -> Bool {
        var isLast = true
        for component in path.split(separator: "/").reversed() {
            if component == "__MACOSX" { return true }
            if isLast, component.hasPrefix("._") { return true }
            isLast = false
        }
        return false
    }

    /// The item a piece of metadata belongs to: "Docs/._a.txt" and
    /// "__MACOSX/Docs/._a.txt" both describe "Docs/a.txt". Nil for something that is
    /// not metadata, or is the `__MACOSX` folder itself.
    public static func itemDescribed(by path: String) -> String? {
        guard isMetadata(path: path) else { return nil }
        var components = path.split(separator: "/").map(String.init)
        components.removeAll { $0 == "__MACOSX" }
        guard var last = components.popLast() else { return nil }
        if last.hasPrefix("._") { last.removeFirst(2) }
        guard !last.isEmpty else { return nil }
        return (components + [last]).joined(separator: "/")
    }

    /// The metadata path `path`, rewritten to describe `item` instead of whatever it
    /// described: "__MACOSX/Docs/._a.txt" redescribing "Docs/b.txt" is
    /// "__MACOSX/Docs/._b.txt".
    public static func path(_ path: String, redescribing item: String) -> String? {
        guard isMetadata(path: path) else { return nil }
        let original = path.split(separator: "/").map(String.init)
        var components = item.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return nil }
        if original.last?.hasPrefix("._") == true {
            components[components.count - 1] = "._" + components[components.count - 1]
        }
        if original.first == "__MACOSX" { components.insert("__MACOSX", at: 0) }
        return components.joined(separator: "/")
    }
}
