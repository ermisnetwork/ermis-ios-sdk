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

    /// A gallery view width * height ratio.
    ///
    /// If `nil` is returned, aspect ratio will not be applied and gallery view will
    /// aspect ratio will depend on internal constraints.
    ///
    /// Returns `1.32` by default.
    open var galleryViewAspectRatio: CGFloat? { 1.32 }

    open override func contentViewDidLayout(options: MessageLayoutOptions) {
        super.contentViewDidLayout(options: options)

        contentView.bubbleView?.clipsToBounds = true

        // We need to apply corners to the left and right containers because the previewsContainerView
        // is applying extra layout margins and the rounded corners wouldn't match the margins.
        let leftCorners: CACornerMask = [.layerMinXMaxYCorner, .layerMinXMinYCorner]
        galleryView.leftPreviewsContainerView.layer.maskedCorners = options.roundedCorners.intersection(leftCorners)
        galleryView.leftPreviewsContainerView.layer.cornerRadius = 16
        galleryView.leftPreviewsContainerView.layer.masksToBounds = true

        let rightCorners: CACornerMask = [.layerMaxXMaxYCorner, .layerMaxXMinYCorner]
        galleryView.rightPreviewsContainerView.layer.maskedCorners = options.roundedCorners.intersection(rightCorners)
        galleryView.rightPreviewsContainerView.layer.cornerRadius = 16
        galleryView.rightPreviewsContainerView.layer.masksToBounds = true

        if let ratio = galleryViewAspectRatio {
            galleryView
                .widthAnchor
                .pin(equalTo: galleryView.heightAnchor, multiplier: ratio)
                .isActive = true
        }
    }

    open override func contentViewDidcontentDidChanged() {
        super.contentViewDidcontentDidChanged()
        let videos = attachments(payloadType: VideoAttachmentPayload.self)
        let images = attachments(payloadType: ImageAttachmentPayload.self)
        log.debug("TTTTT GALLARY ATTACHMENT VIEW INJECTOR CONTENT CHANGED \(videos.count),  \(images.count)")
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
