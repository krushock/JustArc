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
    /// Sent by the Dock: a file dropped on JustArc's icon, or opened from a stack
    /// such as Downloads. The two cannot be told apart.
    case dock
    /// Anything else: the command line, another app, a script.
    case other
}

/// Decides between unpacking an archive and opening it in a window.
///
/// Opening an archive follows the user's setting, from the Finder and from the Dock
/// alike. The Dock sends the same request for a file dropped on JustArc's icon as for
/// one opened from its Downloads stack, and the second is plainly an ordinary open.
/// Opening one while a JustArc window is already up reads as "I want this in the
/// app", and opens a window. Holding Option does the other thing, and skips the
/// question when the setting is to ask.
public enum OpenRouting {
    public static func action(setting: ArchiveOpenAction,
                              source: OpenSource,
                              hasVisibleBrowserWindow: Bool,
                              optionHeld: Bool) -> ArchiveOpenAction {
        var action = setting
        if hasVisibleBrowserWindow { action = .browse }
        guard optionHeld else { return action }
        switch action {
        case .extract, .ask: return .browse
        case .browse: return .extract
        }
    }
}
