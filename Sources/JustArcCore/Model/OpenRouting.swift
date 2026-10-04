import Foundation

/// What happens to an archive that arrives from outside the app.
public enum ArchiveOpenAction: String, Sendable, CaseIterable {
    /// Unpack it and get out of the way.
    case extract
    /// Show its contents in a window.
    case browse
    /// Ask which of the two.
    case ask
}

/// Where an open request came from, as far as the app can tell.
public enum OpenSource: String, Sendable {
    /// A double-click, or Open With, in the Finder.
    case finder
    /// Dropped on the Dock icon.
    case dock
    /// Anything else: the command line, another app, a script.
    case other
}

/// Decides between unpacking an archive and opening it in a window.
///
/// Double-clicking in the Finder follows the user's setting. Everything that reads as
/// "I want this in the app" opens a window whatever the setting says: dropping the
/// archive on the Dock icon, or opening it while a JustArc window is already up.
/// Holding Option does the other thing, and skips the question when the setting is to
/// ask.
public enum OpenRouting {
    public static func action(setting: ArchiveOpenAction,
                              source: OpenSource,
                              hasVisibleBrowserWindow: Bool,
                              optionHeld: Bool) -> ArchiveOpenAction {
        var action = setting
        if hasVisibleBrowserWindow || source == .dock { action = .browse }
        guard optionHeld else { return action }
        switch action {
        case .extract, .ask: return .browse
        case .browse: return .extract
        }
    }
}
