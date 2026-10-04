import AppKit
import UniformTypeIdentifiers
import JustArcCore

/// Reads and changes which app the Finder opens each kind of archive with.
///
/// This is the same setting as Get Info ▸ Open With ▸ Change All in the Finder, held
/// by Launch Services for the whole account, not a preference of JustArc's own.
@MainActor
enum FileAssociations {
    struct Row {
        let kind: AssociableFileType
        let type: UTType
    }

    /// One row per content type. Two extensions that macOS treats as the same type
    /// share a default app, so they share a row.
    static func rows() -> [Row] {
        var seen = Set<String>()
        return AssociableFileType.all.compactMap { kind in
            guard let type = UTType(filenameExtension: kind.extensions[0]),
                  seen.insert(type.identifier).inserted else { return nil }
            return Row(kind: kind, type: type)
        }
    }

    /// This copy of JustArc, when it is running from an app bundle. A bare executable
    /// from a build folder cannot be anything's default app.
    static var justArc: URL? {
        let bundle = Bundle.main.bundleURL
        return bundle.pathExtension == "app" ? bundle.standardizedFileURL : nil
    }

    static func defaultApp(for type: UTType) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: type)?.standardizedFileURL
    }

    /// Every app that says it opens this type, JustArc first and the rest by name,
    /// with the current default included even if it is a choice the user made by hand.
    static func candidates(for type: UTType) -> [URL] {
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: type).map(\.standardizedFileURL)
        if let current = defaultApp(for: type), !apps.contains(current) { apps.append(current) }
        if let justArc, !apps.contains(justArc) { apps.append(justArc) }

        var seen = Set<URL>()
        apps = apps.filter { seen.insert($0).inserted }
        return apps.sorted { lhs, rhs in
            if (lhs == justArc) != (rhs == justArc) { return lhs == justArc }
            return displayName(of: lhs).localizedStandardCompare(displayName(of: rhs)) == .orderedAscending
        }
    }

    /// macOS confirms the change with the user in a dialog of its own before making
    /// it, so this can take as long as they take to answer, and throws when they say no.
    static func setDefault(_ app: URL, for type: UTType) async throws {
        try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
    }

    /// True for the error macOS reports when the user declines its confirmation.
    static func isUserCancellation(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let candidate = current {
            if candidate.domain == NSCocoaErrorDomain, candidate.code == NSUserCancelledError { return true }
            if candidate.domain == NSOSStatusErrorDomain, candidate.code == Int(userCanceledErr) { return true }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    static func isJustArc(_ app: URL?) -> Bool {
        guard let app, let justArc else { return false }
        return app == justArc
    }

    static func displayName(of app: URL) -> String {
        let name = FileManager.default.displayName(atPath: app.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    static func icon(of app: URL, size: CGFloat = 16) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: size, height: size)
        return icon
    }
}
