//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import ErmisSharedUI
import UIKit

/// `UICollectionViewCell` for an image item.
open class ImageAttachmentGalleryCell: GalleryCollectionViewCell, RemoteImageDisplayable {
    open class var reuseId: String { String(describing: self) }

    /// A view that displays an image.
    open private(set) lazy var imageView: UIImageView = UIImageView()
        .withoutAutoresizingMaskConstraints

    public weak var imageDownloadTask: (any Cancellable)?

    /// Resolves encrypted opaque media URLs to verified local plaintext files before the image
    /// loader sees them. Standard image URLs continue through the existing loader unchanged.
    public var imageURLResolver: ((AnyMessageAttachment, @escaping (Result<URL, Error>) -> Void) -> Void)?

    private var resolutionToken = UUID()

    override open func setUp() {
        super.setUp()

        imageView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFit
    }

    override open func setUpUI() {
        super.setUpUI()

        scrollView.addSubview(imageView)
        imageView.pin(anchors: [.height, .width], to: contentView)
    }

    override open func contentDidChanged() {
        super.contentDidChanged()

        let imageAttachment = content?.attachment(payloadType: ImageAttachmentPayload.self)
        if let thumbnailData = content?.thumbnailData ?? imageAttachment?.thumbnailData {
            imageView.image = UIImage(data: thumbnailData)
        }

        guard let imageAttachment else { return }
        let imageURL = imageAttachment.imageURL
        guard imageURL.scheme == "ermis-e2ee-attachment" else {
            displayImage(at: imageURL, attachment: imageAttachment)
            return
        }

        resolutionToken = UUID()
        let token = resolutionToken
        guard let content, let imageURLResolver else { return }
        imageURLResolver(content) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.resolutionToken == token else { return }
                guard case let .success(localURL) = result else { return }
                self.displayImage(at: localURL, attachment: imageAttachment)
            }
        }
    }

    private func displayImage(
        at url: URL,
        attachment: MessageAttachment<ImageAttachmentPayload>
    ) {
        if attachment.isGif {
            imageView.setGifFromURL(url, customLoader: nil)
            return
        }

        guard let originalWidth = attachment.payload.originalWidth,
              let originalHeight = attachment.payload.originalHeight else {
            loadImage(from: url, with: ImageLoaderOptions())
            return
        }

        let imageSizeCalculator = ImageSizeCalculator()
        let newSize = imageSizeCalculator.calculateSize(
            originalWidthInPixels: originalWidth,
            originalHeightInPixels: originalHeight,
            maxResolutionTotalPixels: components.imageAttachmentMaxPixels
        )

        loadImage(from: url, with: ImageLoaderOptions(resize: .init(newSize)))
    }

    override open func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    open override func prepareForReuse() {
        super.prepareForReuse()
        resolutionToken = UUID()
        imageView.image = nil
        imageURLResolver = nil
    }
}
