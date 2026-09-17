import Foundation
import JustArcCore
import AppKit

enum ExtractDestination: String, CaseIterable {
    case besideArchive
    case downloads
    case desktop
    case ask

    var title: String {
        switch self {
        case .besideArchive: return L("Same folder as the archive")
        case .downloads: return L("Downloads")
        case .desktop: return L("Desktop")
        case .ask: return L("Ask every time")
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
            Key.overwriteMode: OverwriteModeSetting.ask.rawValue,
            Key.folderConflictMode: FolderConflictSetting.ask.rawValue,
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
        static let folderConflictMode = "FolderConflictMode"
        static let excludeMacMetadata = "ExcludeMacMetadata"
        static let defaultFormat = "DefaultFormat"
        static let defaultLevel = "DefaultLevel"
        static let showFolderTree = "ShowFolderTree"
        static let rememberPasswords = "RememberPasswords"
    }

    enum OverwriteModeSetting: String, CaseIterable {
        case ask, overwrite, skip, rename

        var title: String {
            switch self {
            case .ask: return L("Ask what to do")
            case .overwrite: return L("Replace the existing file")
            case .skip: return L("Skip the new file")
            case .rename: return L("Keep both")
            }
        }

        /// The engine setting this choice maps onto. Nil means there is nothing to
        /// map, because the user has to be asked first.
        var resolved: OverwriteMode? {
            switch self {
            case .ask: return nil
            case .overwrite: return .overwrite
            case .skip: return .skip
            case .rename: return .renameNew
            }
        }
    }

    /// The same question for folders, which has an extra answer: merge.
    enum FolderConflictSetting: String, CaseIterable {
        case ask, merge, replace, keepBoth, skip

        init(_ resolution: FolderConflictResolution) {
            switch resolution {
            case .merge: self = .merge
            case .replace: self = .replace
            case .keepBoth: self = .keepBoth
            case .skip: self = .skip
            }
        }

        var title: String {
            switch self {
            case .ask: return L("Ask what to do")
            case .merge: return L("Merge into it")
            case .replace: return L("Replace it")
            case .keepBoth: return L("Keep both")
            case .skip: return L("Skip it")
            }
        }

        var resolved: FolderConflictResolution? {
            switch self {
            case .ask: return nil
            case .merge: return .merge
            case .replace: return .replace
            case .keepBoth: return .keepBoth
            case .skip: return .skip
            }
        }
    }

    static var folderConflictMode: FolderConflictSetting {
        get { FolderConflictSetting(rawValue: defaults.string(forKey: Key.folderConflictMode) ?? "") ?? .ask }
        set { defaults.set(newValue.rawValue, forKey: Key.folderConflictMode) }
    }

    static var overwriteMode: OverwriteModeSetting {
        get { OverwriteModeSetting(rawValue: defaults.string(forKey: Key.overwriteMode) ?? "") ?? .ask }
        set { defaults.set(newValue.rawValue, forKey: Key.overwriteMode) }
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
