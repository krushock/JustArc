import Foundation

/// The archives the user opened recently, newest first.
///
/// Kept in our own defaults rather than read back from `NSDocumentController`, because
/// that controller only tracks types it can map to an `NSDocument` subclass and this
/// app has none, so what it returns is not dependable. The app still tells the
/// document controller about each archive, which is what puts them in the system's
/// Recent Items; this store is what the menus and the sidebar read.
public final class RecentArchives: @unchecked Sendable {
    public static let shared = RecentArchives()
    public static let didChange = Notification.Name("JustArcRecentArchivesDidChange")

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()
    public let limit: Int

    public init(defaults: UserDefaults = .standard, key: String = "RecentArchives", limit: Int = 12) {
        self.defaults = defaults
        self.key = key
        self.limit = limit
    }

    /// Recent archives that are still where they were, newest first.
    public var urls: [URL] {
        lock.lock(); defer { lock.unlock() }
        return storedPaths()
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func note(_ url: URL) {
        let path = url.standardizedFileURL.path
        lock.lock()
        var paths = storedPaths().filter { $0 != path }
        paths.insert(path, at: 0)
        if paths.count > limit { paths.removeLast(paths.count - limit) }
        defaults.set(paths, forKey: key)
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    public func remove(_ url: URL) {
        let path = url.standardizedFileURL.path
        lock.lock()
        defaults.set(storedPaths().filter { $0 != path }, forKey: key)
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    public func clear() {
        lock.lock()
        defaults.removeObject(forKey: key)
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func storedPaths() -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }
}
