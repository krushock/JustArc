import AppKit
import XCTest
@testable import JustArc
@testable import JustArcCore

/// Scratch space and plumbing shared by the second-pass review experiments.
enum Review2 {
    static let scratchBase = FileManager.default.temporaryDirectory
        .appendingPathComponent("justarc-review-tests")

    static func makeRoot() throws -> URL {
        let root = scratchBase.appendingPathComponent("run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @MainActor
    static func host(_ controller: NSViewController) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 800, height: 500))
        window.layoutIfNeeded()
        return window
    }

    @MainActor
    static func waitFor(_ what: String = "condition", timeout: TimeInterval = 15,
                        _ condition: @escaping @MainActor () -> Bool,
                        file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting for \(what)", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    static func allSubviews<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { subview in
            ((subview as? T).map { [$0] } ?? []) + allSubviews(of: type, in: subview)
        }
    }

    /// Runs `body` on the main thread the way an event or a menu action arrives:
    /// from the run loop, not from inside a block of the main dispatch queue.
    @MainActor
    static func asEvent(_ body: @escaping @MainActor () -> Void) {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { body() }
        }
    }
}

/// Answers modal alerts so a test that reaches one does not block for ever.
///
/// A timer in the common modes keeps firing inside `runModal`. Each tick it hands the
/// modal window to `onModal`, which presses a button or types into a field.
@MainActor
final class ModalDriver {
    struct Seen {
        let texts: [String]
        let buttons: [String]
    }

    private var timer: Timer?
    private var answered = Set<ObjectIdentifier>()
    private(set) var seen: [Seen] = []
    /// Called once for each modal window the first time it is noticed, and again
    /// whenever it becomes the front modal window after another one closed.
    var onModal: ((ModalDriver, NSWindow, Seen) -> Void)?
    private var lastFront: ObjectIdentifier?
    private var firstSeenAt: [ObjectIdentifier: Date] = [:]

    func start() {
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let window = NSApp.modalWindow else {
            lastFront = nil
            return
        }
        let id = ObjectIdentifier(window)
        if firstSeenAt[id] == nil { firstSeenAt[id] = Date() }
        // A modal nobody answers would hang the run; give up on it after a while.
        if let since = firstSeenAt[id], Date().timeIntervalSince(since) > 20 {
            NSApp.abortModal()
            return
        }
        guard lastFront != id else { return }
        lastFront = id
        let view = window.contentView ?? NSView()
        let texts = Review2.allSubviews(of: NSTextField.self, in: view)
            .filter { !($0 is NSSecureTextField) && !$0.isEditable }.map(\.stringValue).filter { !$0.isEmpty }
        let buttons = Review2.allSubviews(of: NSButton.self, in: view).map(\.title).filter { !$0.isEmpty }
        let record = Seen(texts: texts, buttons: buttons)
        seen.append(record)
        onModal?(self, window, record)
    }

    /// Lets the same window be handed to `onModal` again on a later tick.
    func revisit() { lastFront = nil }

    func press(_ title: String, in window: NSWindow) {
        guard let view = window.contentView,
              let button = Review2.allSubviews(of: NSButton.self, in: view).first(where: { $0.title == title }) else {
            NSApp.abortModal()
            return
        }
        button.performClick(nil)
    }

    func type(_ text: String, in window: NSWindow) {
        guard let view = window.contentView else { return }
        for field in Review2.allSubviews(of: NSTextField.self, in: view) where field.isEditable {
            field.stringValue = text
        }
    }
}

/// Stops a test from waiting for ever on a dialog nobody was expected to answer.
///
/// A modal alert blocks the test that reached it, and with it the whole run. Armed in
/// every test class's setUp, this dismisses any modal window that has been up for a
/// while and records which one it was.
@MainActor
enum ModalWatchdog {
    private static var timer: Timer?
    private static var firstSeen: [ObjectIdentifier: Date] = [:]
    private(set) static var dismissed: [String] = []

    static func arm() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private static func tick() {
        guard let window = NSApp.modalWindow else { return }
        let id = ObjectIdentifier(window)
        if firstSeen[id] == nil { firstSeen[id] = Date() }
        guard let since = firstSeen[id], Date().timeIntervalSince(since) > 25 else { return }
        firstSeen[id] = nil
        let texts = Review2.allSubviews(of: NSTextField.self, in: window.contentView ?? NSView())
            .map(\.stringValue).filter { !$0.isEmpty }
        dismissed.append(texts.first ?? "a dialog")
        XCTFail("a dialog nobody answered was dismissed: \(texts)")
        NSApp.abortModal()
    }
}
