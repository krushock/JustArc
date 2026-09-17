import AppKit
import JustArcCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let quickExtract = QuickExtractCoordinator()
    private var browserControllers: [ArchiveWindowController] = []
    private var didReceiveOpenRequest = false
    private var preferencesController: PreferencesWindowController?

    // MARK: - Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        Preferences.registerDefaults()
        NSApp.mainMenu = MainMenuBuilder.build()
        quickExtract.onAllJobsFinished = { [weak self] in
            self?.terminateIfNothingLeftToShow()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard EngineLocator.sevenZip != nil else {
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

        // Non-archives dropped on the app icon become the contents of a new archive.
        if !others.isEmpty {
            let controller = makeBrowserWindow(for: nil)
            controller.session.stage(items: others)
            controller.reloadFromSession()
        }

        guard !archives.isEmpty else { return }

        if shouldBrowseRatherThanExtract() {
            for archive in archives { openInBrowser(archive) }
        } else {
            quickExtract.enqueue(archives)
        }
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

    /// Holding Option at launch flips whichever behaviour is configured,
    /// matching the "open in the app instead of extracting" shortcut people expect.
    private func shouldBrowseRatherThanExtract() -> Bool {
        let optionHeld = NSEvent.modifierFlags.contains(.option)
        return Preferences.browseInsteadOfExtracting != optionHeld
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
        alert.messageText = "JustArc is missing its archive engine."
        alert.informativeText = """
        The bundled 7-Zip helper could not be found in Contents/Helpers.
        Reinstall JustArc, or set JUSTARC_7ZZ to a 7zz binary when running from a build folder.
        """
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: - Window management

    @discardableResult
    func makeBrowserWindow(for archive: URL?) -> ArchiveWindowController {
        let controller = ArchiveWindowController(archive: archive)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.browserControllers.removeAll { $0 === controller }
            self.terminateIfNothingLeftToShow()
        }
        browserControllers.append(controller)
        controller.showWindow(nil)
        return controller
    }

    func openInBrowser(_ archive: URL) {
        if let existing = browserControllers.first(where: { $0.session.archiveURL == archive }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = makeBrowserWindow(for: archive)
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
        panel.message = "Choose one or more archives to open."
        panel.prompt = "Open"
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

    @objc func showAbout(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "JustArc"
        alert.informativeText = """
        A fast archiver for macOS.

        Reading and writing is powered by 7-Zip \(SevenZipVersion.short), \
        used under the GNU LGPL. Disk images use the system hdiutil tool.
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

enum SevenZipVersion {
    /// Filled in lazily the first time the About box is shown.
    static let short: String = {
        guard let tool = EngineLocator.sevenZip else { return "(not found)" }
        let process = Process()
        process.executableURL = tool
        process.arguments = ["i"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard let line = text.components(separatedBy: .newlines).first(where: { $0.contains("7-Zip") }),
              let range = line.range(of: #"\d+\.\d+"#, options: .regularExpression) else { return "" }
        return String(line[range])
    }()
}
