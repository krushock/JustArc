import AppKit
import JustArcCore

/// Builds the window's toolbar out of standard AppKit items.
///
/// Nothing here draws glass by hand. A unified `NSToolbar` made of `NSToolbarItem`
/// and `NSToolbarItemGroup` is rendered by the system, which on macOS 26 and later
/// means Liquid Glass, grouped capsules and the scroll-edge behaviour come for free
/// and stay correct as the system evolves. Items carry no target, so validation and
/// dispatch go through the responder chain to whichever view controller is in front.
@MainActor
enum ArchiveToolbar {
    enum ID {
        static let navigation = NSToolbarItem.Identifier("navigation")
        static let back = NSToolbarItem.Identifier("back")
        static let forward = NSToolbarItem.Identifier("forward")

        static let transfer = NSToolbarItem.Identifier("transfer")
        static let add = NSToolbarItem.Identifier("add")
        static let extract = NSToolbarItem.Identifier("extract")

        static let item = NSToolbarItem.Identifier("item")
        static let quickLook = NSToolbarItem.Identifier("quickLook")
        static let delete = NSToolbarItem.Identifier("delete")

        static let archive = NSToolbarItem.Identifier("archive")
        static let test = NSToolbarItem.Identifier("test")
        static let info = NSToolbarItem.Identifier("info")
        static let password = NSToolbarItem.Identifier("password")

        static let save = NSToolbarItem.Identifier("save")
        static let search = NSToolbarItem.Identifier("search")
    }

    /// The order items appear in by default. `sidebarTrackingSeparator` keeps the
    /// toolbar's divider lined up with the split, which is what Mail and Finder do.
    static let defaultIdentifiers: [NSToolbarItem.Identifier] = [
        .toggleSidebar,
        .sidebarTrackingSeparator,
        ID.navigation,
        .flexibleSpace,
        ID.transfer,
        ID.item,
        ID.archive,
        ID.save,
        .flexibleSpace,
        ID.search,
    ]

    static let allowedIdentifiers: [NSToolbarItem.Identifier] = [
        .toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .space,
        ID.navigation, ID.transfer, ID.item, ID.archive, ID.save, ID.search,
    ]

    /// One description per command, so the items and the menus cannot drift apart.
    struct Command {
        let identifier: NSToolbarItem.Identifier
        let label: String
        let symbol: String
        let action: Selector
    }

    static let commands: [NSToolbarItem.Identifier: Command] = [
        ID.back: Command(identifier: ID.back, label: L("Back"), symbol: "chevron.backward",
                         action: #selector(ArchiveBrowserViewController.goBack(_:))),
        ID.forward: Command(identifier: ID.forward, label: L("Forward"), symbol: "chevron.forward",
                            action: #selector(ArchiveBrowserViewController.goForward(_:))),
        ID.add: Command(identifier: ID.add, label: L("Add"), symbol: "plus",
                        action: #selector(ArchiveBrowserViewController.addFiles(_:))),
        ID.extract: Command(identifier: ID.extract, label: L("Extract To"), symbol: "arrow.down.document",
                            action: #selector(ArchiveBrowserViewController.extractSelected(_:))),
        ID.quickLook: Command(identifier: ID.quickLook, label: L("Quick Look"), symbol: "eye",
                              action: #selector(ArchiveBrowserViewController.toggleQuickLook(_:))),
        ID.delete: Command(identifier: ID.delete, label: L("Delete"), symbol: "trash",
                           action: #selector(ArchiveBrowserViewController.deleteSelected(_:))),
        ID.test: Command(identifier: ID.test, label: L("Test"), symbol: "checkmark.seal",
                         action: #selector(ArchiveBrowserViewController.testArchive(_:))),
        ID.info: Command(identifier: ID.info, label: L("Info"), symbol: "info.circle",
                         action: #selector(ArchiveBrowserViewController.showArchiveInfo(_:))),
        ID.password: Command(identifier: ID.password, label: L("Password"), symbol: "lock",
                             action: #selector(ArchiveBrowserViewController.setPassword(_:))),
        ID.save: Command(identifier: ID.save, label: L("Save"), symbol: "square.and.arrow.down",
                         action: #selector(ArchiveBrowserViewController.saveArchive(_:))),
    ]

    static let groups: [NSToolbarItem.Identifier: (label: String, members: [NSToolbarItem.Identifier])] = [
        ID.navigation: (L("Navigate"), [ID.back, ID.forward]),
        ID.transfer: (L("Transfer"), [ID.add, ID.extract]),
        ID.item: (L("Item"), [ID.quickLook, ID.delete]),
        ID.archive: (L("Archive"), [ID.test, ID.info, ID.password]),
    ]

    // MARK: - Building

    static func makeToolbar(delegate: NSToolbarDelegate) -> NSToolbar {
        let toolbar = NSToolbar(identifier: "JustArcBrowserToolbar")
        toolbar.delegate = delegate
        toolbar.displayMode = .iconOnly
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
        item.target = nil          // the responder chain finds the front view controller
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
        // Expanded keeps the members visible as one capsule rather than folding them
        // into a menu, which is the grouping Mail uses for its reply and filing rows.
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
