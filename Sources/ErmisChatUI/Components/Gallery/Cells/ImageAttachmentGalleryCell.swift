//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// `UICollectionViewCell` for an image item.
open class ImageAttachmentGalleryCell: GalleryCollectionViewCell, RemoteImageDisplayable {
    open class var reuseId: String { String(describing: self) }

    /// A view that displays an image.
    open private(set) lazy var imageView: UIImageView = UIImageView()
        .withoutAutoresizingMaskConstraints

    public weak var imageDownloadTask: (any Cancellable)?

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
        if imageAttachment?.isGif ?? false {
            if let url = imageAttachment?.imageURL {
                imageView.setGifFromURL(url, customLoader: nil)
            }
            return
        } else {
            guard let originalWidth = imageAttachment?.payload.originalWidth,
                  let originalHeight = imageAttachment?.payload.originalHeight else {
                loadImage(
                    from: imageAttachment?.payload.imageURL,
                    with: ImageLoaderOptions()
                )
                return
            }

            let imageSizeCalculator = ImageSizeCalculator()
            let newSize = imageSizeCalculator.calculateSize(
                originalWidthInPixels: originalWidth,
                originalHeightInPixels: originalHeight,
                maxResolutionTotalPixels: components.imageAttachmentMaxPixels
            )

            loadImage(
                from: imageAttachment?.payload.imageURL,
                with: ImageLoaderOptions(resize: .init(newSize))
            )
        }
    }

    override open func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    open override func prepareForReuse() {
        super.prepareForReuse()
        cancelImageLoading()
        imageView.image = nil
    }
}
