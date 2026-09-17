import Foundation
import AppKit

enum ExtractDestination: String, CaseIterable {
    case besideArchive
    case downloads
    case desktop
    case ask

    var title: String {
        switch self {
        case .besideArchive: return "Same folder as the archive"
        case .downloads: return "Downloads"
        case .desktop: return "Desktop"
        case .ask: return "Ask every time"
        }
    }
}

/// Thin typed wrapper over UserDefaults.
enum Preferences {
    private static let defaults = UserDefaults.standard

    static func registerDefaults() {
        defaults.register(defaults: [
            Key.extractDestination: ExtractDestination.besideArchive.rawValue,
            Key.smartFolder: true,
            Key.revealInFinder: true,
            Key.moveArchiveToTrash: false,
            Key.quitAfterQuickExtract: true,
            Key.browseInsteadOfExtracting: false,
            Key.overwriteMode: OverwriteModeSetting.rename.rawValue,
            Key.excludeMacMetadata: true,
            Key.defaultFormat: "zip",
            Key.defaultLevel: 5,
            Key.showFolderTree: false,
            Key.rememberPasswords: false,
        ])
    }

    enum Key {
        static let extractDestination = "ExtractDestination"
        static let smartFolder = "SmartFolder"
        static let revealInFinder = "RevealInFinder"
        static let moveArchiveToTrash = "MoveArchiveToTrash"
        static let quitAfterQuickExtract = "QuitAfterQuickExtract"
        static let browseInsteadOfExtracting = "BrowseInsteadOfExtracting"
        static let overwriteMode = "OverwriteMode"
        static let excludeMacMetadata = "ExcludeMacMetadata"
        static let defaultFormat = "DefaultFormat"
        static let defaultLevel = "DefaultLevel"
        static let showFolderTree = "ShowFolderTree"
        static let rememberPasswords = "RememberPasswords"
    }

    enum OverwriteModeSetting: String {
        case ask, overwrite, skip, rename
    }

    static var extractDestination: ExtractDestination {
        get { ExtractDestination(rawValue: defaults.string(forKey: Key.extractDestination) ?? "") ?? .besideArchive }
        set { defaults.set(newValue.rawValue, forKey: Key.extractDestination) }
    }

    static var smartFolder: Bool {
        get { defaults.bool(forKey: Key.smartFolder) }
        set { defaults.set(newValue, forKey: Key.smartFolder) }
    }

    static var revealInFinder: Bool {
        get { defaults.bool(forKey: Key.revealInFinder) }
        set { defaults.set(newValue, forKey: Key.revealInFinder) }
    }

    static var moveArchiveToTrash: Bool {
        get { defaults.bool(forKey: Key.moveArchiveToTrash) }
        set { defaults.set(newValue, forKey: Key.moveArchiveToTrash) }
    }

    static var quitAfterQuickExtract: Bool {
        get { defaults.bool(forKey: Key.quitAfterQuickExtract) }
        set { defaults.set(newValue, forKey: Key.quitAfterQuickExtract) }
    }

    static var browseInsteadOfExtracting: Bool {
        get { defaults.bool(forKey: Key.browseInsteadOfExtracting) }
        set { defaults.set(newValue, forKey: Key.browseInsteadOfExtracting) }
    }

    static var excludeMacMetadata: Bool {
        get { defaults.bool(forKey: Key.excludeMacMetadata) }
        set { defaults.set(newValue, forKey: Key.excludeMacMetadata) }
    }

    static var showFolderTree: Bool {
        get { defaults.bool(forKey: Key.showFolderTree) }
        set { defaults.set(newValue, forKey: Key.showFolderTree) }
    }

    static var defaultFormatKey: String {
        get { defaults.string(forKey: Key.defaultFormat) ?? "zip" }
        set { defaults.set(newValue, forKey: Key.defaultFormat) }
    }

    static var defaultLevel: Int {
        get { defaults.integer(forKey: Key.defaultLevel) }
        set { defaults.set(newValue, forKey: Key.defaultLevel) }
    }

    /// Resolves the folder an archive should be extracted into.
    /// Returns nil when the user should be asked.
    static func destinationFolder(for archive: URL) -> URL? {
        switch extractDestination {
        case .besideArchive:
            return archive.deletingLastPathComponent()
        case .downloads:
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        case .desktop:
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        case .ask:
            return nil
        }
    }
}
