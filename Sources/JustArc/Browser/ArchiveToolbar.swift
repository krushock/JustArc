import AppKit
import JustArcCore

/// Builds the window's toolbar out of standard AppKit items, laid out the way Disk
/// Utility lays out its own: each command a separate button with its name beneath,
/// and a single grouped plus-and-minus capsule for adding and removing.
///
/// Nothing here draws glass. A unified `NSToolbar` made of `NSToolbarItem` and
/// `NSToolbarItemGroup` is rendered by the system, which on macOS 26 and later means
/// the glass buttons, the capsule grouping and the scroll edge come from AppKit and
/// follow the system as it changes. Items carry no target, so validation and dispatch
/// go through the responder chain to the view controller in front.
@MainActor
enum ArchiveToolbar {
    /// Bumped whenever the default layout changes. The toolbar remembers the user's
    /// arrangement under this name, and a remembered arrangement would otherwise keep
    /// the old buttons and the old display mode on screen.
    static let identifier = "JustArcBrowserToolbar.v2"

    enum ID {
        static let navigation = NSToolbarItem.Identifier("navigation")
        static let back = NSToolbarItem.Identifier("back")
        static let forward = NSToolbarItem.Identifier("forward")

        static let files = NSToolbarItem.Identifier("files")
        static let add = NSToolbarItem.Identifier("add")
        static let remove = NSToolbarItem.Identifier("remove")

        static let extract = NSToolbarItem.Identifier("extract")
        static let quickLook = NSToolbarItem.Identifier("quickLook")
        static let test = NSToolbarItem.Identifier("test")
        static let password = NSToolbarItem.Identifier("password")
        static let save = NSToolbarItem.Identifier("save")
        static let info = NSToolbarItem.Identifier("info")
        static let search = NSToolbarItem.Identifier("search")
    }

    static let defaultIdentifiers: [NSToolbarItem.Identifier] = [
        .toggleSidebar,
        .sidebarTrackingSeparator,
        ID.navigation,
        .flexibleSpace,
        ID.files,
        ID.extract,
        ID.quickLook,
        ID.test,
        ID.save,
        ID.info,
        ID.search,
    ]

    static let allowedIdentifiers: [NSToolbarItem.Identifier] = [
        .toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .space,
        ID.navigation, ID.files, ID.extract, ID.quickLook, ID.test,
        ID.password, ID.save, ID.info, ID.search,
    ]

    struct Command {
        let label: String
        let symbol: String
        let action: Selector
    }

    static let commands: [NSToolbarItem.Identifier: Command] = [
        ID.back: Command(label: L("Back"), symbol: "chevron.backward",
                         action: #selector(ArchiveBrowserViewController.goBack(_:))),
        ID.forward: Command(label: L("Forward"), symbol: "chevron.forward",
                            action: #selector(ArchiveBrowserViewController.goForward(_:))),
        ID.add: Command(label: L("Add Files"), symbol: "plus",
                        action: #selector(ArchiveBrowserViewController.addFiles(_:))),
        ID.remove: Command(label: L("Delete"), symbol: "minus",
                           action: #selector(ArchiveBrowserViewController.deleteSelected(_:))),
        ID.extract: Command(label: L("Extract"), symbol: "arrow.down.document",
                            action: #selector(ArchiveBrowserViewController.extractSelected(_:))),
        ID.quickLook: Command(label: L("Quick Look"), symbol: "eye",
                              action: #selector(ArchiveBrowserViewController.toggleQuickLook(_:))),
        ID.test: Command(label: L("Test"), symbol: "checkmark.seal",
                         action: #selector(ArchiveBrowserViewController.testArchive(_:))),
        ID.password: Command(label: L("Password"), symbol: "lock",
                             action: #selector(ArchiveBrowserViewController.setPassword(_:))),
        ID.save: Command(label: L("Save"), symbol: "square.and.arrow.down",
                         action: #selector(ArchiveBrowserViewController.saveArchive(_:))),
        ID.info: Command(label: L("Info"), symbol: "info.circle",
                         action: #selector(ArchiveBrowserViewController.showArchiveInfo(_:))),
    ]

    /// Grouped only where the pair is one idea, as Disk Utility groups its volume
    /// plus and minus under the single word "Volume".
    static let groups: [NSToolbarItem.Identifier: (label: String, members: [NSToolbarItem.Identifier])] = [
        ID.navigation: (L("Back/Forward"), [ID.back, ID.forward]),
        ID.files: (L("Files"), [ID.add, ID.remove]),
    ]

    // MARK: - Building

    static func makeToolbar(delegate: NSToolbarDelegate) -> NSToolbar {
        let toolbar = NSToolbar(identifier: identifier)
        toolbar.delegate = delegate
        // Names beneath the icons, which is what Disk Utility and Finder show.
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        return toolbar
    }

    static func makeItem(for identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        guard let command = commands[identifier] else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = command.label
        item.paletteLabel = command.label
        item.toolTip = command.label
        item.image = NSImage(systemSymbolName: command.symbol, accessibilityDescription: command.label)
        item.action = command.action
        item.target = nil
        item.isBordered = true
        item.isNavigational = identifier == ID.back || identifier == ID.forward
        return item
    }

    static func makeGroup(for identifier: NSToolbarItem.Identifier) -> NSToolbarItemGroup? {
        guard let group = groups[identifier] else { return nil }
        let toolbarGroup = NSToolbarItemGroup(itemIdentifier: identifier)
        toolbarGroup.label = group.label
        toolbarGroup.paletteLabel = group.label
        toolbarGroup.subitems = group.members.compactMap { makeItem(for: $0) }
        toolbarGroup.controlRepresentation = .expanded
        toolbarGroup.selectionMode = .momentary
        toolbarGroup.isNavigational = identifier == ID.navigation
        return toolbarGroup
    }

    static func makeSearchItem(delegate: NSSearchFieldDelegate) -> NSSearchToolbarItem {
        let item = NSSearchToolbarItem(itemIdentifier: ID.search)
        item.label = L("Filter")
        item.paletteLabel = L("Filter")
        item.toolTip = L("Filter the list")
        item.searchField.delegate = delegate
        item.searchField.placeholderString = L("Filter")
        item.searchField.sendsWholeSearchString = false
        item.searchField.sendsSearchStringImmediately = true
        item.resignsFirstResponderWithCancel = true
        return item
    }
}
