//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// A view that displays image attachment preview in composer.
open class ImageAttachmentComposerPreview: _View, UIProvider, RemoteImageDisplayable {
    open var width: CGFloat = 100
    open var height: CGFloat = 100

    /// Local URL of the image preview to show.
    public var content: URL? {
        didSet {
            updateContentIfNeeded()
        }
    }

    /// The image view that displays the image of the attachment.
    open private(set) lazy var imageView: UIImageView = UIImageView()
        .withoutAutoresizingMaskConstraints

    public weak var imageDownloadTask: (any Cancellable)?

    override open func setUpTheme() {
        super.setUpTheme()

        layer.masksToBounds = true
        layer.cornerRadius = 11

        imageView.contentMode = .scaleAspectFill
    }

    override open func setUpUI() {
        super.setUpUI()

        embed(imageView)

        widthAnchor.pin(equalToConstant: width).isActive = true
        heightAnchor.pin(equalToConstant: height).isActive = true
    }

    override open func contentDidChanged() {
        super.contentDidChanged()

        let size = CGSize(width: width, height: height)
        loadImage(from: content, with: ImageLoaderOptions(resize: ImageResize(size)))
    }
}
