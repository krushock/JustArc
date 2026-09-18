import AppKit
import JustArcCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let quickExtract = QuickExtractCoordinator()
    private var browserControllers: [ArchiveWindowController] = []
    private var didReceiveOpenRequest = false
    private var preferencesController: PreferencesWindowController?
    private var servicesProvider: ServicesProvider?
    private let recentMenu = RecentMenuController()
    private let updates = UpdateController()

    // MARK: - Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        Preferences.registerDefaults()
        Diagnostics.log("launch: ui language \(Bundle.main.preferredLocalizations.first ?? "?"), "
                        + "\"Extract To\" reads as \"\(L("Extract To"))\"")
        recentMenu.open = { [weak self] url in self?.openInBrowser(url) }
        NSApp.mainMenu = MainMenuBuilder.build(recentMenu: recentMenu.menu)
        quickExtract.onAllJobsFinished = { [weak self] in
            self?.terminateIfNothingLeftToShow()
        }
        registerServices()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard SevenZipLibrary.isAvailable else {
            presentMissingEngineAndQuit()
            return
        }
        // Paths on the command line behave exactly like files opened from Finder,
        // which makes the app scriptable and testable.
        let fileArguments = CommandLine.arguments.dropFirst()
            .filter { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        if !fileArguments.isEmpty {
            application(NSApp, open: fileArguments)
        }
        // The open-document event lands between will- and didFinishLaunching, but give it
        // one more turn of the run loop before deciding this was a bare launch.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.didReceiveOpenRequest, self.browserControllers.isEmpty else { return }
            self.newArchiveWindow(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        didReceiveOpenRequest = true
        let archives = urls.filter { FormatRegistry.isArchive($0) }
        let others = urls.filter { !FormatRegistry.isArchive($0) }

        // Other files dropped on the app become the contents of an archive, going into
        // the empty window when there is one rather than opening a second.
        if !others.isEmpty {
            let controller = browserControllers.first(where: \.isPristine)
                ?? makeBrowserWindow(for: nil)
            controller.session.stage(items: others)
            controller.reloadFromSession()
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        guard !archives.isEmpty else { return }

        let browse = shouldBrowseRatherThanExtract()
        Diagnostics.log("open request: \(archives.count) archive(s), "
                        + (browse ? "opening in a window" : "extracting"))
        if browse {
            for archive in archives { openInBrowser(archive) }
            NSApp.activate(ignoringOtherApps: true)
        } else {
            for archive in archives { RecentsRecorder.note(archive) }
            quickExtract.enqueue(archives)
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        recentMenu.dockMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Leaving a disk image attached after quitting would strand it in Finder.
        EngineFactory.releaseAll()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag && browserControllers.isEmpty { newArchiveWindow(nil) }
        return true
    }

    /// Double-clicking an archive while JustArc is not in use unpacks it and gets out
    /// of the way. Once a window is open, though, the user is working in the app, and
    /// an archive dropped on the Dock icon should open in it rather than be unpacked
    /// behind their back. Holding Option flips whichever of the two would happen.
    private func shouldBrowseRatherThanExtract() -> Bool {
        let workingInApp = browserControllers.contains { $0.window?.isVisible == true }
        let browse = Preferences.browseInsteadOfExtracting || workingInApp
        return browse != NSEvent.modifierFlags.contains(.option)
    }

    private func terminateIfNothingLeftToShow() {
        guard Preferences.quitAfterQuickExtract else { return }
        guard browserControllers.isEmpty, !quickExtract.hasActiveJobs else { return }
        guard preferencesController?.window?.isVisible != true else { return }
        NSApp.terminate(nil)
    }

    private func presentMissingEngineAndQuit() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L("JustArc is missing its archive engine.")
        alert.informativeText = L("The bundled 7-Zip library could not be loaded from Contents/Frameworks. Reinstall JustArc, or set JUSTARC_7Z_LIBRARY to a 7z.so when running from a build folder.")
        alert.runModal()
        NSApp.terminate(nil)
    }

    /// Publishes the Finder Services menu entries declared in Info.plist.
    private func registerServices() {
        let provider = ServicesProvider(
            quickExtract: quickExtract,
            openInBrowser: { [weak self] url in self?.openInBrowser(url) },
            stageIntoNewWindow: { [weak self] items in
                guard let self else { return }
                let controller = self.makeBrowserWindow(for: nil)
                controller.session.stage(items: items)
                controller.reloadFromSession()
                NSApp.activate(ignoringOtherApps: true)
            })
        servicesProvider = provider
        NSApp.servicesProvider = provider
        NSUpdateDynamicServices()
    }

    // MARK: - Window management

    /// - Parameter previous: an untouched window to replace. The new window takes its
    ///   exact frame and the old one closes, so the archive appears to open in place.
    @discardableResult
    func makeBrowserWindow(for archive: URL?,
                           replacing previous: ArchiveWindowController? = nil) -> ArchiveWindowController {
        let controller = ArchiveWindowController(archive: archive)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.browserControllers.removeAll { $0 === controller }
            self.terminateIfNothingLeftToShow()
        }
        browserControllers.append(controller)

        if let previous, let frame = previous.window?.frame {
            controller.window?.setFrame(frame, display: false)
        }
        controller.showWindow(nil)
        // Closing directly skips the unsaved-changes question, which is right here:
        // the window was checked to be untouched before it was chosen.
        previous?.window?.close()
        return controller
    }

    func openInBrowser(_ archive: URL) {
        let wanted = archive.standardizedFileURL
        if let existing = browserControllers.first(where: {
            $0.session.archiveURL?.standardizedFileURL == wanted }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let pristine = browserControllers.first(where: \.isPristine)
        Diagnostics.log("opening \(archive.lastPathComponent) "
                        + (pristine != nil ? "in place of the empty window" : "in a new window"))
        let controller = makeBrowserWindow(for: archive, replacing: pristine)
        controller.loadArchive()
    }

    // MARK: - Menu actions

    @objc func newArchiveWindow(_ sender: Any?) {
        makeBrowserWindow(for: nil)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = L("Choose one or more archives to open.")
        panel.prompt = L("Open")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { openInBrowser(url) }
    }

    @objc func showPreferences(_ sender: Any?) {
        if preferencesController == nil {
            preferencesController = PreferencesWindowController()
        }
        preferencesController?.showWindow(nil)
        preferencesController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updates.checkForUpdates(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates(_:)) {
            return updates.validate(menuItem)
        }
        return true
    }

    @objc func showAbout(_ sender: Any?) {
        // The standard panel already knows the app's name, icon and version; only the
        // credits are ours to supply.
        let credits = NSAttributedString(
            string: L("A fast archiver for macOS.\n\nCompression is powered by 7-Zip %@, used under the GNU LGPL. Disk images use the system hdiutil tool.", SevenZipVersion.short),
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.labelColor,
            ])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum SevenZipVersion {
    static var short: String {
        SevenZipLibrary.isAvailable ? SevenZipLibrary.version : "(not found)"
    }
}
