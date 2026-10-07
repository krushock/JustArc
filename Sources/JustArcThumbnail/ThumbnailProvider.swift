import AppKit
import JustArcPreview
import QuickLookThumbnailing

/// The Quick Look thumbnail for archives: in the Finder's icon and gallery views an
/// archive is shown as a page with what is inside it.
///
/// Named for Objective-C because that is how the extension's Info.plist finds it.
@objc(JustArcThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        // No reply means the archive keeps its ordinary icon.
        guard max(request.maximumSize.width, request.maximumSize.height) >= ArchiveThumbnail.minimumDimension else {
            handler(nil, nil)
            return
        }
        let url = request.fileURL
        let size = ArchiveThumbnail.pageSize(fitting: request.maximumSize, atLeast: request.minimumSize)
        Task {
            let preview = await ArchivePreview.load(url, unwrapLimit: ArchiveThumbnail.unwrapLimit,
                                                    for: "thumbnail")
            guard let thumbnail = ArchiveThumbnail(preview) else {
                handler(nil, nil)
                return
            }
            handler(QLThumbnailReply(contextSize: size, currentContextDrawing: {
                thumbnail.draw(in: CGRect(origin: .zero, size: size))
                return true
            }), nil)
        }
    }
}
