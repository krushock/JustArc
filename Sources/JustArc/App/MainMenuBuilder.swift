import AppKit
import JustArcCore

/// Builds the menu bar in code, mirroring WinRAR's File / Commands split
/// while keeping the macOS-standard App, Edit, Window and Help menus.
enum MainMenuBuilder {
    static func build(recentMenu: NSMenu) -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(fileMenuItem(recentMenu: recentMenu))
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(commandsMenuItem())
        mainMenu.addItem(viewMenuItem())
        mainMenu.addItem(windowMenuItem())
        mainMenu.addItem(helpMenuItem())
        return mainMenu
    }

    private static func submenu(_ title: String, _ build: (NSMenu) -> Void) -> NSMenuItem {
        // Every menu title passes through here, so one lookup covers the whole bar.
        let item = NSMenuItem(title: L(title), action: nil, keyEquivalent: "")
        let menu = NSMenu(title: L(title))
        build(menu)
        item.submenu = menu
        return item
    }

    @discardableResult
    private static func add(_ menu: NSMenu,
                            _ title: String,
                            _ action: Selector?,
                            _ key: String = "",
                            modifiers: NSEvent.ModifierFlags = .command,
                            target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: L(title), action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        menu.addItem(item)
        return item
    }

    private static func appMenuItem() -> NSMenuItem {
        submenu("JustArc") { menu in
            add(menu, "About JustArc", #selector(AppDelegate.showAbout(_:)))
            menu.addItem(.separator())
            add(menu, "Check for Updates…", #selector(AppDelegate.checkForUpdates(_:)))
            menu.addItem(.separator())
            add(menu, "Settings…", #selector(AppDelegate.showPreferences(_:)), ",")
            menu.addItem(.separator())
            add(menu, "Hide JustArc", #selector(NSApplication.hide(_:)), "h")
            let hideOthers = add(menu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h")
            hideOthers.keyEquivalentModifierMask = [.command, .option]
            add(menu, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
            menu.addItem(.separator())
            add(menu, "Quit JustArc", #selector(NSApplication.terminate(_:)), "q")
        }
    }

    private static func fileMenuItem(recentMenu: NSMenu) -> NSMenuItem {
        submenu("File") { menu in
            add(menu, "New Archive", #selector(AppDelegate.newArchiveWindow(_:)), "n")
            add(menu, "Open…", #selector(AppDelegate.openDocument(_:)), "o")
            let recent = add(menu, "Open Recent", nil)
            recent.submenu = recentMenu
            menu.addItem(.separator())
            add(menu, "Close", #selector(NSWindow.performClose(_:)), "w")
            add(menu, "Save", #selector(ArchiveBrowserViewController.saveArchive(_:)), "s")
            add(menu, "Save As…", #selector(ArchiveBrowserViewController.saveArchiveAs(_:)), "S",
                modifiers: [.command, .shift])
            menu.addItem(.separator())
            add(menu, "Reveal Archive in Finder", #selector(ArchiveBrowserViewController.revealArchiveInFinder(_:)), "R",
                modifiers: [.command, .shift])
        }
    }

    private static func editMenuItem() -> NSMenuItem {
        submenu("Edit") { menu in
            add(menu, "Select All", #selector(NSResponder.selectAll(_:)), "a")
            add(menu, "Invert Selection", #selector(ArchiveBrowserViewController.invertSelection(_:)), "i",
                modifiers: [.command, .option])
            menu.addItem(.separator())
            add(menu, "Find…", #selector(ArchiveBrowserViewController.focusFilterField(_:)), "f")
        }
    }

    private static func commandsMenuItem() -> NSMenuItem {
        submenu("Commands") { menu in
            add(menu, "Add Files…", #selector(ArchiveBrowserViewController.addFiles(_:)), "A",
                modifiers: [.command, .shift])
            menu.addItem(.separator())
            add(menu, "Extract Selected…", #selector(ArchiveBrowserViewController.extractSelected(_:)), "e")
            add(menu, "Extract All…", #selector(ArchiveBrowserViewController.extractAll(_:)), "E",
                modifiers: [.command, .shift])
            menu.addItem(.separator())
            // These used to be bare Return and Delete, which claims those keys for the
            // whole app and stops them working in the filter field and in dialogs.
            // The list itself handles the unmodified keys; the menu follows Finder.
            add(menu, "Open Selected File", #selector(ArchiveBrowserViewController.openSelectedFile(_:)),
                String(UnicodeScalar(NSDownArrowFunctionKey)!))
            add(menu, "Quick Look", #selector(ArchiveBrowserViewController.toggleQuickLook(_:)), "y")
            menu.addItem(.separator())
            add(menu, "Delete", #selector(ArchiveBrowserViewController.deleteSelected(_:)), "\u{8}")
            add(menu, "Rename…", #selector(ArchiveBrowserViewController.renameSelected(_:)), "r")
            menu.addItem(.separator())
            add(menu, "Test Archive", #selector(ArchiveBrowserViewController.testArchive(_:)), "t")
            add(menu, "Set Password…", #selector(ArchiveBrowserViewController.setPassword(_:)), "k")
            add(menu, "Archive Information", #selector(ArchiveBrowserViewController.showArchiveInfo(_:)), "i")
        }
    }

    private static func viewMenuItem() -> NSMenuItem {
        submenu("View") { menu in
            add(menu, "Enclosing Folder", #selector(ArchiveBrowserViewController.goUp(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!))
            add(menu, "Back", #selector(ArchiveBrowserViewController.goBack(_:)), "[")
            add(menu, "Forward", #selector(ArchiveBrowserViewController.goForward(_:)), "]")
            menu.addItem(.separator())
            add(menu, "Show Sidebar", #selector(ArchiveBrowserViewController.toggleFolderTree(_:)), "s",
                modifiers: [.command, .control])
            menu.addItem(textEncodingMenuItem())
            add(menu, "Reload", #selector(ArchiveBrowserViewController.reloadArchive(_:)), "r",
                modifiers: [.command, .option])
        }
    }

    /// Filename encodings for zip archives written on systems that predate UTF-8.
    /// Each item carries its code page in `tag`, with 0 standing for automatic.
    private static func textEncodingMenuItem() -> NSMenuItem {
        submenu("Filename Encoding") { menu in
            for encoding in ArchiveTextEncoding.all {
                // Already localised by the encoding table itself.
                let item = add(menu, encoding.title,
                               #selector(ArchiveBrowserViewController.setTextEncoding(_:)))
                item.tag = encoding.codePage ?? 0
                if encoding.codePage == nil { menu.addItem(.separator()) }
            }
        }
    }

    private static func windowMenuItem() -> NSMenuItem {
        let item = submenu("Window") { menu in
            add(menu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
            add(menu, "Zoom", #selector(NSWindow.performZoom(_:)))
            menu.addItem(.separator())
            add(menu, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        }
        NSApp.windowsMenu = item.submenu
        return item
    }

    private static func helpMenuItem() -> NSMenuItem {
        submenu("Help") { menu in
            add(menu, "Supported Formats", #selector(AppDelegate.showSupportedFormats(_:)))
        }
    }
}
