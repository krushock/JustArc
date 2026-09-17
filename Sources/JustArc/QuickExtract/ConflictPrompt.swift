import AppKit
import JustArcCore

/// Asks what to do when extracting would land on something that is already there.
///
/// Two separate questions, because they have different answers. A folder that already
/// exists can be merged into, which is usually what people want. A file that already
/// exists cannot. Each question is asked once for the whole operation, which keeps a
/// thousand-file archive from turning into a thousand dialogs.
@MainActor
enum ConflictPrompt {
    struct Resolution {
        var folder: FolderConflictResolution
        var file: OverwriteMode
        /// Which folders were in the way, so the runner knows what to act on.
        var folderConflicts: [String] = []
    }

    /// Returns how to extract, or nil when the user cancels.
    static func resolve(entries: [ArchiveEntry],
                        roots: [String],
                        destination: URL,
                        window: NSWindow?) -> Resolution? {
        let report = ExtractionConflicts.find(entries: entries, roots: roots, in: destination)
        let defaultFileMode = Preferences.overwriteMode.resolved ?? .renameNew

        guard !report.isEmpty else {
            return Resolution(folder: .merge, file: defaultFileMode)
        }

        // 1. The folder question, if any folder is in the way.
        var folderResolution = FolderConflictResolution.merge
        if report.hasFolderConflicts {
            if let fixed = Preferences.folderConflictMode.resolved {
                folderResolution = fixed
            } else if let chosen = askAboutFolders(report: report, destination: destination) {
                folderResolution = chosen
            } else {
                return nil
            }
        }

        // 2. The file question, over whatever collisions the folder answer left behind.
        let remaining = ExtractionConflicts.fileConflictsRemaining(after: folderResolution,
                                                                   report: report,
                                                                   entries: entries,
                                                                   in: destination)
        guard remaining.hasFileConflicts else {
            return Resolution(folder: folderResolution, file: defaultFileMode,
                              folderConflicts: report.folders)
        }
        if let fixed = Preferences.overwriteMode.resolved {
            return Resolution(folder: folderResolution, file: fixed,
                              folderConflicts: report.folders)
        }
        guard let fileMode = askAboutFiles(report: remaining, destination: destination) else {
            return nil
        }
        return Resolution(folder: folderResolution, file: fileMode,
                          folderConflicts: report.folders)
    }

    // MARK: - Folders

    static func askAboutFolders(report: ExtractionConflicts.Report,
                                destination: URL) -> FolderConflictResolution? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = report.folders.count == 1
            ? L("A folder named “%@” already exists in “%@”.",
                report.folders[0], destination.lastPathComponent)
            : L("%d folders already exist in “%@”.",
                report.folders.count, destination.lastPathComponent)

        var explanation = [L("Merging adds the archive’s files to the folder that is already there. Replacing moves it to the Trash first.")]
        if report.folders.count > 1 {
            explanation.append(report.folders.joined(separator: "\n"))
        }
        alert.informativeText = explanation.joined(separator: "\n\n")

        // Merging leads, because it is the one choice that loses nothing.
        alert.addButton(withTitle: L("Merge"))
        alert.addButton(withTitle: L("Replace"))
        alert.addButton(withTitle: L("Keep Both"))
        alert.addButton(withTitle: L("Skip"))
        alert.addButton(withTitle: L("Cancel"))

        let remember = rememberCheckbox()
        alert.accessoryView = remember

        let choice: FolderConflictResolution?
        switch alert.runModal() {
        case .alertFirstButtonReturn: choice = .merge
        case .alertSecondButtonReturn: choice = .replace
        case .alertThirdButtonReturn: choice = .keepBoth
        case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1):
            choice = .skip
        default: choice = nil
        }

        guard let choice else { return nil }
        if remember.state == .on {
            Preferences.folderConflictMode = Preferences.FolderConflictSetting(choice)
        }
        return choice
    }

    // MARK: - Files

    static func askAboutFiles(report: ExtractionConflicts.Report,
                              destination: URL) -> OverwriteMode? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = report.fileCount == 1
            ? L("One item already exists in “%@”.", destination.lastPathComponent)
            : L("%d items already exist in “%@”.", report.fileCount, destination.lastPathComponent)

        var lines = report.files.map { ($0 as NSString).lastPathComponent }
        let remaining = report.fileCount - report.files.count
        if remaining > 0 { lines.append(L("and %d more", remaining)) }
        alert.informativeText = lines.joined(separator: "\n")

        alert.addButton(withTitle: L("Keep Both"))
        alert.addButton(withTitle: L("Replace"))
        alert.addButton(withTitle: L("Skip"))
        alert.addButton(withTitle: L("Cancel"))

        let remember = rememberCheckbox()
        alert.accessoryView = remember

        let choice: (mode: OverwriteMode, setting: Preferences.OverwriteModeSetting)?
        switch alert.runModal() {
        case .alertFirstButtonReturn: choice = (.renameNew, .rename)
        case .alertSecondButtonReturn: choice = (.overwrite, .overwrite)
        case .alertThirdButtonReturn: choice = (.skip, .skip)
        default: choice = nil
        }

        guard let choice else { return nil }
        if remember.state == .on { Preferences.overwriteMode = choice.setting }
        return choice.mode
    }

    private static func rememberCheckbox() -> NSButton {
        let box = NSButton(checkboxWithTitle: L("Always do this"), target: nil, action: nil)
        box.toolTip = L("Save this choice in Settings and stop asking.")
        return box
    }
}
