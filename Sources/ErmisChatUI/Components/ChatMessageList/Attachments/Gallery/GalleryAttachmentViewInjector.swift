//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// The delegate used `GalleryAttachmentViewInjector` to communicate user interactions.
public protocol GalleryContentViewDelegate: MessageContentViewDelegate {
    /// Called when the user taps on one of the attachment previews.
    func galleryMessageContentView(
        at indexPath: IndexPath?,
        didTapAttachmentPreview attachmentId: AttachmentId,
        previews: [GalleryItemPreview]
    )

    /// Called when action button is clicked for uploading attachment.
    func galleryMessageContentView(
        at indexPath: IndexPath?,
        didTakeActionOnUploadingAttachment attachmentId: AttachmentId
    )
}

/// The type used to show an media gallery in `MessageContentView`.
open class GalleryAttachmentViewInjector: CustomCellViewInjector {
    public override var customView: UIView {
        return galleryView
    }
    /// A gallery which shows attachment previews.
    open private(set) lazy var galleryView: MessageGalleryView = contentView
        .components
        .galleryView.init()
        .withoutAutoresizingMaskConstraints

    /// A gallery view width / height default ratio
    open var galleryViewDefaultAspectRatio: CGFloat {
        return 1.32
    }

    /// A min gallery aspect ratio value, nil value is same as don't set min ratio.
    open var minGalleryAspectRatio: CGFloat? {
        return 0.67
    }

    /// A gallery view width * height ratio.
    ///
    /// If `nil` is returned, aspect ratio will not be applied and gallery view will
    /// aspect ratio will depend on internal constraints.
    ///
    public private(set) var galleryViewAspectRatio: CGFloat?

    open var galleryViewSizeRatioConstraint: NSLayoutConstraint?

    open override func contentViewDidLayout(options: MessageLayoutOptions) {
        super.contentViewDidLayout(options: options)

        contentView.bubbleView?.clipsToBounds = true

        let ratio = galleryViewAspectRatio ?? galleryViewDefaultAspectRatio
        galleryViewSizeRatioConstraint = galleryView
            .widthAnchor
            .pin(equalTo: galleryView.heightAnchor, multiplier: ratio)
        galleryViewSizeRatioConstraint?.isActive = true
    }

    open override func contentViewDidcontentDidChanged() {
        super.contentViewDidcontentDidChanged()
        let videos = attachments(payloadType: VideoAttachmentPayload.self)
        let images = attachments(payloadType: ImageAttachmentPayload.self)
        if videos.count + images.count == 1, let image = images.first {
            galleryViewAspectRatio = ratioValue(for: image)
        } else {
            galleryViewAspectRatio = galleryViewDefaultAspectRatio
        }
        updateGalleryViewRatio()
        galleryView.content = videos.map(preview) + images.map(preview)
    }

    /// Is invoked when attachment preview is tapped.
    /// - Parameter id: Attachment identifier.
    open func handleTapOnAttachment(with id: AttachmentId) {
        delegate?.galleryMessageContentView(
            at: contentView.indexPath?(),
            didTapAttachmentPreview: id,
            previews: galleryView.content.compactMap { $0 as? GalleryItemPreview }
        )
    }

    /// Is invoked when action button on attachment uploading overlay is tapped.
    /// - Parameter id: Attachment identifier.
    open func handleUploadingAttachmentAction(_ attachmentId: AttachmentId) {
        delegate?.galleryMessageContentView(
            at: contentView.indexPath?(),
            didTakeActionOnUploadingAttachment: attachmentId
        )
    }

    open override func contentViewDidPrepareForReuse() {
        super.contentViewDidPrepareForReuse()
        galleryView.content = []
        contentView.content = nil
    }

    /// Get width/height ratio of image attachment.
    /// - Parameter attachment: The image message attachemnts.
    /// - Returns The width/height ratio value of input attachment.
    ///
    open func ratioValue(for attachment: MessageAttachment<ImageAttachmentPayload>) -> CGFloat {
        guard let width = attachment.originalWidth,
              width != 0,
              let height = attachment.originalHeight,
              height != 0 else {
            return galleryViewDefaultAspectRatio
        }
        let ratio = CGFloat(width) / CGFloat(height)
        if let minGalleryAspectRatio {
            return max(ratio, minGalleryAspectRatio)
        }
        return ratio
    }

    /// Update current gallery view ratio constraint.
    open func updateGalleryViewRatio() {
        if galleryViewSizeRatioConstraint?.multiplier != galleryViewAspectRatio {
            NSLayoutConstraint.deactivate([galleryViewSizeRatioConstraint!])
            galleryViewSizeRatioConstraint = galleryView
                .widthAnchor
                .pin(equalTo: galleryView.heightAnchor, multiplier: galleryViewAspectRatio ?? galleryViewDefaultAspectRatio)
            galleryViewSizeRatioConstraint?.isActive = true
        }
    }
}

private extension GalleryAttachmentViewInjector {
    var delegate: GalleryContentViewDelegate? {
        contentView.delegate as? GalleryContentViewDelegate
    }

    func preview(for videoAttachment: MessageVideoAttachment) -> UIView {
        let preview = contentView
            .components
            .videoAttachmentGalleryPreview
            .init()
            .withoutAutoresizingMaskConstraints

        preview.didTapOnAttachment = { [weak self] in
            self?.handleTapOnAttachment(with: $0.id)
        }

        preview.didTapOnUploadingActionButton = { [weak self] in
            self?.handleUploadingAttachmentAction($0.id)
        }

        preview.content = videoAttachment

        return preview
    }

    func preview(for imageAttachment: MessageImageAttachment) -> UIView {
        // Gif preview
        if imageAttachment.isGif {
            let preview = contentView
                .components
                .gifImageAttachmentGalleryPreview
                .init()
                .withoutAutoresizingMaskConstraints

            preview.didTapOnAttachment = { [weak self] in
                self?.handleTapOnAttachment(with: $0.id)
            }

            preview.didTapOnUploadingActionButton = { [weak self] in
                self?.handleUploadingAttachmentAction($0.id)
            }

            preview.content = imageAttachment
            return preview
        }
        // Image preview
        let preview = contentView
            .components
            .imageAttachmentGalleryPreview
            .init()
            .withoutAutoresizingMaskConstraints

        preview.didTapOnAttachment = { [weak self] in
            self?.handleTapOnAttachment(with: $0.id)
        }

        preview.didTapOnUploadingActionButton = { [weak self] in
            self?.handleUploadingAttachmentAction($0.id)
        }

        preview.content = imageAttachment

        return preview
    }
}
