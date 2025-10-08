//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// The type preview should conform to in order the gallery can be shown from it.
public protocol GalleryItemPreview {
    /// Attachment identifier.
    var attachmentId: AttachmentId? { get }

    /// `UIImageView` that is displayed the attachment preview.
    var imageView: UIImageView { get }
}

extension MessageGalleryView {
    @objc(MessageGalleryViewImagePreview)
    open class ImagePreview: _View, UIProvider, GalleryItemPreview {
        public var content: MessageImageAttachment? {
            didSet { updateContentIfNeeded() }
        }

        public var attachmentId: AttachmentId? {
            content?.id
        }

        private lazy var gifLoadingHandler = SwiftyGifLoadingHandler()

        public var didTapOnAttachment: ((MessageImageAttachment) -> Void)?
        public var didTapOnUploadingActionButton: ((MessageImageAttachment) -> Void)?

        private weak var imageTask: Cancellable? {
            didSet { oldValue?.cancel() }
        }

        // MARK: - Subviews

        public private(set) lazy var imageView: UIImageView = {
            let imageView = UIImageView()
            imageView.contentMode = .scaleAspectFill
            imageView.layer.masksToBounds = true
            imageView.clipsToBounds = true
            return imageView
                .withoutAutoresizingMaskConstraints
                .withAccessibilityIdentifier(identifier: "imageView")
        }()

        public private(set) lazy var loadingIndicator = components
            .loadingIndicator
            .init()
            .withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "loadingIndicator")

        public private(set) lazy var uploadingOverlay = components
            .uploadingOverlayView
            .init()
            .withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "uploadingOverlay")

        // MARK: - Overrides

        override open func setUpTheme() {
            super.setUpTheme()
            imageView.backgroundColor = theme.colors.surface
        }

        override open func setUp() {
            super.setUp()
            let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(didTapOnAttachment(_:)))
            addGestureRecognizer(tapRecognizer)

            uploadingOverlay.didTapActionButton = { [weak self] in
                guard let self = self, let attachment = self.content else { return }

                self.didTapOnUploadingActionButton?(attachment)
            }
        }

        override open func setUpUI() {
            embed(imageView)
            embed(uploadingOverlay)

            addSubview(loadingIndicator)
            loadingIndicator.centerYAnchor.pin(equalTo: centerYAnchor).isActive = true
            loadingIndicator.centerXAnchor.pin(equalTo: centerXAnchor).isActive = true
        }

        override open func contentDidChanged() {
            super.contentDidChanged()
            let attachment = content

            if let uploadingState = attachment?.uploadingState,
               uploadingState.state != .uploaded,
               let thumbData = attachment?.thumbnailData, let thumbImage = UIImage(data: thumbData) {
                imageView.currentImageLoadingTask?.cancel()
                imageView.image = thumbImage
                loadingIndicator.isVisible = false
            } else {
                loadingIndicator.isVisible = true
                imageTask = components.imageLoader.loadImage(
                    into: imageView,
                    from: attachment?.payload,
                    maxResolutionInPixels: components.imageAttachmentMaxPixels
                ) { [weak self] _ in
                    self?.loadingIndicator.isVisible = false
                    self?.imageTask = nil
                }
            }

            uploadingOverlay.content = content?.uploadingState
            uploadingOverlay.isVisible = attachment?.uploadingState != nil
        }

        // MARK: - Actions

        @objc open func didTapOnAttachment(_ recognizer: UITapGestureRecognizer) {
            guard let attachment = content else { return }
            didTapOnAttachment?(attachment)
        }

        // MARK: - Init & Deinit

        deinit {
            imageTask?.cancel()
            imageView.image = nil
        }
    }
}

extension MessageGalleryView {
    @objc(MessageGalleryViewGifImagePreview)
    open class GifImagePreview: _View, UIProvider, GalleryItemPreview {
        public var content: MessageImageAttachment? {
            didSet { 
                let isDifferentImage = oldValue?.imageURL != content?.imageURL
                guard hasFailed || isDifferentImage else { return }
                updateContentIfNeeded()
            }
        }

        private var gifLoadingHandler = SwiftyGifLoadingHandler()

        public var attachmentId: AttachmentId? {
            content?.id
        }

        public private(set) var hasFailed = false

        public var didTapOnAttachment: ((MessageImageAttachment) -> Void)?
        public var didTapOnUploadingActionButton: ((MessageImageAttachment) -> Void)?

        private weak var imageTask: Cancellable? {
            didSet { oldValue?.cancel() }
        }

        // MARK: - Subviews

        public private(set) lazy var imageView: UIImageView = {
            let imageView = UIImageView()
            imageView.contentMode = .scaleAspectFill
            imageView.layer.masksToBounds = true
            return imageView
                .withoutAutoresizingMaskConstraints
                .withAccessibilityIdentifier(identifier: "imageView")
        }()

        public private(set) lazy var loadingIndicator = components
            .loadingIndicator
            .init()
            .withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "loadingIndicator")

        public private(set) lazy var uploadingOverlay = components
            .uploadingOverlayView
            .init()
            .withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "uploadingOverlay")

        // MARK: - Overrides

        override open func setUpTheme() {
            super.setUpTheme()
            imageView.backgroundColor = theme.colors.surface
        }

        override open func setUp() {
            super.setUp()

            gifLoadingHandler.didFail = { [weak self] _ in
                self?.hasFailed = true
                self?.imageTask = nil
            }

            gifLoadingHandler.didSucceed = { [weak self] in
                self?.hasFailed = false
                self?.imageTask = nil
            }

            imageView.delegate = gifLoadingHandler

            let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(didTapOnAttachment(_:)))
            addGestureRecognizer(tapRecognizer)

            uploadingOverlay.didTapActionButton = { [weak self] in
                guard let self = self, let attachment = self.content else { return }

                self.didTapOnUploadingActionButton?(attachment)
            }
        }

        override open func setUpUI() {
            embed(imageView)
            embed(uploadingOverlay)
        }

        override open func contentDidChanged() {
            super.contentDidChanged()

            let attachment = content

            if let url = content?.imageURL {
                imageTask = imageView.setGifFromURL(url, customLoader: loadingIndicator)
            }

            uploadingOverlay.content = content?.uploadingState
            uploadingOverlay.isVisible = attachment?.uploadingState != nil
        }

        // MARK: - Actions

        @objc open func didTapOnAttachment(_ recognizer: UITapGestureRecognizer) {
            guard let attachment = content else { return }
            didTapOnAttachment?(attachment)
        }

        // MARK: - Init & Deinit

        deinit {
            imageTask?.cancel()
        }
    }
}

extension MessageGalleryView {
    class SwiftyGifLoadingHandler: SwiftyGifDelegate {
        var didFail: (Error?) -> Void = { _ in }
        var didSucceed: () -> Void = {}

        func gifDidStart(sender: UIImageView) {
            didSucceed()
        }

        func gifURLDidFail(sender: UIImageView, url: URL, error: Error?) {
            didFail(error)
        }
    }
}
