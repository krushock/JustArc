import Foundation

/// Works out where an archive's contents should land, including the "wrap loose files
/// in a folder" rule that stops an archive from scattering items across the destination.
public struct ExtractionPlan: Sendable {
    public let destination: URL
    /// True when a folder named after the archive was created for the contents.
    public let createdWrapperFolder: Bool
    /// The item to reveal in Finder once extraction finishes.
    public let revealTarget: URL

    public init(destination: URL, createdWrapperFolder: Bool, revealTarget: URL) {
        self.destination = destination
        self.createdWrapperFolder = createdWrapperFolder
        self.revealTarget = revealTarget
    }

    /// - Parameters:
    ///   - smartFolder: when true, a wrapper folder is only added if the archive has
    ///     more than one item at its root. When false, a wrapper is always added.
    public static func make(archive: URL,
                            into parent: URL,
                            listing: ArchiveListing,
                            smartFolder: Bool,
                            fileManager: FileManager = .default) -> ExtractionPlan {
        let tree = EntryTree(entries: listing.entries)
        let singleRoot = tree.hasSingleRootItem

        if smartFolder && singleRoot {
            let name = tree.rootItemName ?? FormatRegistry.baseName(for: archive)
            let reveal = parent.appendingPathComponent(name)
            return ExtractionPlan(destination: parent,
                                  createdWrapperFolder: false,
                                  revealTarget: reveal)
        }

        let wrapperName = FormatRegistry.baseName(for: archive)
        let wrapper = PathSafety.uniqueURL(for: parent.appendingPathComponent(wrapperName))
        return ExtractionPlan(destination: wrapper,
                              createdWrapperFolder: true,
                              revealTarget: wrapper)
    }
}
