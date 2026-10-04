import AppKit
import Carbon.HIToolbox
import JustArcCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let quickExtract = QuickExtractCoordinator()
    private var browserControllers: [ArchiveWindowController] = []
    private var didReceiveOpenRequest = false
    /// The empty window a bare launch puts up, so it can be taken away again when the
    /// launch turns out to have been for a Finder service.
    private weak var launchWindow: ArchiveWindowController?
    private let launchDate = Date()
    /// Work in progress that has no window of its own, such as compressing for a
    /// Finder service. The app does not quit underneath it.
    private var backgroundJobs = 0
    private var preferencesController: PreferencesWindowController?
    private var servicesProvider: ServicesProvider?
    private let recentMenu = RecentMenuController()
    private let updates = UpdateController()

    // MARK: - Lifecycle

    /// Where every window keeps the files it has opened or previewed out of an archive.
    private static let scratchRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("JustArc", isDirectory: true)

    func applicationWillFinishLaunching(_ notification: Notification) {
        Preferences.registerDefaults()
        // Anything here was left by a run that did not get to tidy up.
        try? FileManager.default.removeItem(at: Self.scratchRoot)
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
            self.launchWindow = self.makeBrowserWindow(for: nil)
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

        let sender = OpenRequestSender.current()
        let action = OpenRouting.action(
            setting: Preferences.archiveOpenAction,
            source: sender.source,
            hasVisibleBrowserWindow: browserControllers.contains { $0.window?.isVisible == true },
            optionHeld: NSEvent.modifierFlags.contains(.option))
        Diagnostics.log("open request: \(archives.count) archive(s) from \(sender.description), "
                        + "action \(action.rawValue)")
        perform(action, on: archives)
    }

    private func perform(_ action: ArchiveOpenAction, on archives: [URL]) {
        switch action {
        case .browse:
            for archive in archives { openInBrowser(archive) }
            NSApp.activate(ignoringOtherApps: true)
        case .extract:
            for archive in archives { RecentsRecorder.note(archive) }
            quickExtract.enqueue(archives)
        case .ask:
            // Asked on the next turn of the run loop, so the open event that brought
            // the archives is answered first rather than held up by a dialog.
            // Counted as work in hand, so that an extraction finishing meanwhile does
            // not quit the app from under the question.
            backgroundJobs += 1
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let choice = self.askWhatToDo(with: archives)
                self.backgroundJobs = max(self.backgroundJobs - 1, 0)
                if let choice {
                    self.perform(choice, on: archives)
                } else {
                    self.terminateIfNothingLeftToShow()
                }
            }
        }
    }

    private func askWhatToDo(with archives: [URL]) -> ArchiveOpenAction? {
        let alert = NSAlert()
        alert.messageText = archives.count == 1
            ? L("What would you like to do with %@?", archives[0].lastPathComponent)
            : L("What would you like to do with these %d archives?", archives.count)
        alert.informativeText = L("Settings has a choice for what double-clicking an archive does.")
        alert.addButton(withTitle: L("Extract"))
        alert.addButton(withTitle: L("Open"))
        alert.addButton(withTitle: L("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .extract
        case .alertSecondButtonReturn: return .browse
        default: return nil
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
        // Files opened out of archives, some of them decrypted, do not outlive the app.
        try? FileManager.default.removeItem(at: Self.scratchRoot)
    }

    /// Quitting asks first when it would lose something: an archive that was never
    /// saved, or work that is only half done.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let working = quickExtract.hasActiveJobs || backgroundJobs > 0
            || browserControllers.contains(where: \.isBusy)
        let unsaved = browserControllers.filter { $0.session.hasUnsavedChanges }
        guard working || !unsaved.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        if working {
            alert.messageText = L("JustArc is still working. Quit anyway?")
            alert.informativeText = L("The archive or the files being written now will be left incomplete.")
        } else if unsaved.count == 1 {
            alert.messageText = L("%@ has not been saved. Quit anyway?", unsaved[0].session.displayName)
            alert.informativeText = L("The files you added have not been written to an archive yet.")
        } else {
            alert.messageText = L("%d archives have not been saved. Quit anyway?", unsaved.count)
            alert.informativeText = L("The files you added have not been written to an archive yet.")
        }
        alert.addButton(withTitle: L("Cancel"))
        alert.addButton(withTitle: L("Quit Anyway"))
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag && browserControllers.isEmpty { newArchiveWindow(nil) }
        return true
    }

    private func terminateIfNothingLeftToShow() {
        guard Preferences.quitAfterQuickExtract else { return }
        guard browserControllers.isEmpty, !quickExtract.hasActiveJobs, backgroundJobs == 0 else { return }
        guard preferencesController?.window?.isVisible != true else { return }
        NSApp.terminate(nil)
    }

    /// Brackets work that has no window, so the app neither shows an empty one for
    /// it nor quits before it is done.
    func beginBackgroundJob() {
        backgroundJobs += 1
        didReceiveOpenRequest = true
        // Launched by the Finder to run a service: the empty window that a bare
        // launch puts up would only be in the way.
        if let launchWindow, launchWindow.isPristine, Date().timeIntervalSince(launchDate) < 5 {
            launchWindow.window?.close()
        }
    }

    func endBackgroundJob() {
        backgroundJobs = max(backgroundJobs - 1, 0)
        terminateIfNothingLeftToShow()
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
            beginJob: { [weak self] in self?.beginBackgroundJob() },
            endJob: { [weak self] in self?.endBackgroundJob() },
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

    /// An archive that could not be read at all leaves its window with nothing to
    /// show. With other windows open it simply closes; as the only one it gives way
    /// to an empty window, because closing the last window is also what ends the app
    /// after a double-click, and a failed File ▸ Open should not do that.
    func archiveFailedToOpen(_ controller: ArchiveWindowController) {
        if browserControllers.count <= 1 {
            makeBrowserWindow(for: nil, replacing: controller)
        } else {
            controller.window?.close()
        }
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

    @objc func showSupportedFormats(_ sender: Any?) {
        func extensions(_ formats: [ArchiveFormat]) -> String {
            formats.flatMap(\.extensions).map { "." + $0 }.joined(separator: "  ")
        }
        let alert = NSAlert()
        alert.messageText = L("Supported Formats")
        alert.informativeText = [
            L("Opens and extracts:"),
            extensions(FormatRegistry.all),
            "",
            L("Creates:"),
            extensions(SaveOptionsAccessory.availableFormats),
            "",
            EngineLocator.externalRAR == nil
                ? L("RAR archives can be created once RARLAB's tool is installed from Settings.")
                : "",
        ].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
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

/// Works out who sent the open-documents event being handled.
///
/// The Finder and the Dock both ask Launch Services to open the file, and the event
/// that results carries the asker's process ID. That is the only thing telling a
/// double-click from a drop on the Dock icon.
@MainActor
enum OpenRequestSender {
    static func current() -> (source: OpenSource, description: String) {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let descriptor = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr)) else {
            return (.other, "no Apple event")
        }
        let pid = descriptor.int32Value
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        let description = "\(bundleID ?? "an unbundled process") (pid \(pid))"
        switch bundleID {
        case "com.apple.dock": return (.dock, description)
        case "com.apple.finder": return (.finder, description)
        default: return (.other, description)
        }
    }
}

enum SevenZipVersion {
    static var short: String {
        SevenZipLibrary.isAvailable ? SevenZipLibrary.version : "(not found)"
    }
}
