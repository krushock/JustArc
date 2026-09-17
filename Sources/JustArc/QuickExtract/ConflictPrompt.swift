import AppKit
import JustArcCore

/// Asks what to do when extracting would land on files that are already there.
///
/// One decision covers the whole operation, which is what archivers generally do and
/// what keeps a thousand-file archive from turning into a thousand questions.
@MainActor
enum ConflictPrompt {
    /// Returns the mode to extract with, or nil when the user cancels.
    static func resolve(entries: [ArchiveEntry],
                        destination: URL,
                        window: NSWindow?) -> OverwriteMode? {
        // A fixed preference means there is nothing to ask about.
        if let fixed = Preferences.overwriteMode.resolved { return fixed }

        let report = ExtractionConflicts.find(entries: entries, in: destination)
        guard !report.isEmpty else { return .renameNew }

        return ask(report: report, destination: destination, window: window)
    }

    static func ask(report: ExtractionConflicts.Report,
                    destination: URL,
                    window: NSWindow?) -> OverwriteMode? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = report.count == 1
            ? L("One item already exists in “%@”.", destination.lastPathComponent)
            : L("%d items already exist in “%@”.", report.count, destination.lastPathComponent)

        var lines = report.paths.map { ($0 as NSString).lastPathComponent }
        let remaining = report.count - report.paths.count
        if remaining > 0 { lines.append(L("and %d more", remaining)) }
        alert.informativeText = lines.joined(separator: "\n")

        // The first button is the default, so the non-destructive choice leads.
        alert.addButton(withTitle: L("Keep Both"))
        alert.addButton(withTitle: L("Replace"))
        alert.addButton(withTitle: L("Skip"))
        alert.addButton(withTitle: L("Cancel"))

        let remember = NSButton(checkboxWithTitle: L("Always do this"), target: nil, action: nil)
        remember.toolTip = L("Save this choice in Settings and stop asking.")
        alert.accessoryView = remember

        let response = alert.runModal()
        let choice: (mode: OverwriteMode, setting: Preferences.OverwriteModeSetting)?
        switch response {
        case .alertFirstButtonReturn: choice = (.renameNew, .rename)
        case .alertSecondButtonReturn: choice = (.overwrite, .overwrite)
        case .alertThirdButtonReturn: choice = (.skip, .skip)
        default: choice = nil
        }

        guard let choice else { return nil }
        if remember.state == .on { Preferences.overwriteMode = choice.setting }
        return choice.mode
    }
}
