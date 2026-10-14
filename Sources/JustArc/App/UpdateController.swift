import AppKit
import Sparkle
import JustArcCore

/// Wraps Sparkle so the rest of the app does not need to know about it.
///
/// The updater only starts when the bundle declares a feed. A build without one,
/// such as a local debug build, simply has no Check for Updates item rather than
/// showing a command that always fails.
@MainActor
final class UpdateController: NSObject {
    private var updaterController: SPUStandardUpdaterController?

    static var feedURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    /// Sparkle refuses to install an update that is not signed with the matching key,
    /// so a build without the public key can check but never apply.
    static var hasUpdateSigningKey: Bool {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        return !(key ?? "").isEmpty
    }

    var isAvailable: Bool { updaterController != nil }

    /// The one the app made, for Settings to reach.
    static private(set) weak var shared: UpdateController?

    /// Whether JustArc looks for a newer version once a day by itself. Off until the
    /// user says yes, to Sparkle's question or in Settings.
    var checksAutomatically: Bool {
        get { updaterController?.updater.automaticallyChecksForUpdates ?? false }
        set { updaterController?.updater.automaticallyChecksForUpdates = newValue }
    }

    override init() {
        super.init()
        Self.shared = self
        guard let feed = Self.feedURL else {
            Diagnostics.log("updates: no SUFeedURL in the bundle, updater not started")
            return
        }
        updaterController = SPUStandardUpdaterController(startingUpdater: true,
                                                         updaterDelegate: nil,
                                                         userDriverDelegate: nil)
        Diagnostics.log("updates: feed \(public: feed.absoluteString), signing key \(public: Self.hasUpdateSigningKey ? "present" : "missing")")
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard let updaterController else { return }
        updaterController.checkForUpdates(sender)
    }

    /// Lets the menu item disappear in builds that cannot update.
    func validate(_ item: NSMenuItem) -> Bool {
        item.isHidden = !isAvailable
        return isAvailable
    }
}
