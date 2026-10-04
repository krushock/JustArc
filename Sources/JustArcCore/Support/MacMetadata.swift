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
}
