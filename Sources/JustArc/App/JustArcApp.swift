import AppKit
import JustArcCore

@main
enum JustArcApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        // Held for the lifetime of the process; NSApplication keeps only a weak delegate.
        objc_setAssociatedObject(application, "JustArcDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
        application.run()
    }
}
