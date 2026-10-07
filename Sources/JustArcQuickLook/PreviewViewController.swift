import AppKit
import JustArcPreview
import QuickLookUI

/// The Quick Look preview for archives: pressing Space on one in the Finder shows
/// what is in it.
///
/// Named for Objective-C because that is how the extension's Info.plist finds it.
@objc(JustArcPreviewViewController)
final class PreviewViewController: ArchivePreviewViewController, QLPreviewingController {
    func preparePreviewOfFile(at url: URL) async throws {
        await prepare(for: url)
    }
}
