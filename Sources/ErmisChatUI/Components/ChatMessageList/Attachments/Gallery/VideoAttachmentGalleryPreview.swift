//
// Copyright 2025 Ermis Inc.
//

import AVFoundation
import ErmisChat
import UIKit

/// A view used to display video attachment preview in a gallery inside a message cell
open class VideoAttachmentGalleryPreview: _View, UIProvider, RemoteImageDisplayable {
    /// A video attachment the view displays
    open var content: MessageVideoAttachment? {
        didSet { updateContentIfNeeded() }
    }

    /// A handler that will be invoked when the view is tapped
    open var didTapOnAttachment: ((MessageVideoAttachment) -> Void)?

    /// A handler that will be invoked when action button on uploading overlay is tapped
    open var didTapOnUploadingActionButton: ((MessageVideoAttachment) -> Void)?

    /// An image view used to display video preview image
    open private(set) lazy var imageView = UIImageView()
        .withoutAutoresizingMaskConstraints

    /// A loading indicator that is shown when preview is being loaded
    open private(set) lazy var loadingIndicator = components
        .loadingIndicator.init()
        .withoutAutoresizingMaskConstraints

    /// An uploading overlay that shows video uploading progress
    open private(set) lazy var uploadingOverlay = components
        .uploadingOverlayView.init()
        .withoutAutoresizingMaskConstraints

    /// A button displaying `play` icon.
    open private(set) lazy var playButton = UIButton()
        .withoutAutoresizingMaskConstraints

    public weak var imageDownloadTask: (any Cancellable)?

    override open func setUpTheme() {
        super.setUpTheme()

        imageView.backgroundColor = theme.colors.surface
        imageView.contentMode = .scaleAspectFill
        imageView.layer.masksToBounds = true

        playButton.setImage(theme.icons.bigPlay, for: .normal)
    }

    override open func setUp() {
        super.setUp()

        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTapOnAttachment(_:)))
        addGestureRecognizer(tapRecognizer)

        playButton.addTarget(self, action: #selector(handleTapOnPlay), for: .touchUpInside)

        uploadingOverlay.didTapActionButton = { [weak self] in
            guard let self = self, let attachment = self.content else { return }

            self.didTapOnUploadingActionButton?(attachment)
        }
    }

    override open func setUpUI() {
        super.setUpUI()

        addSubview(imageView)
        imageView.pin(to: self)

        addSubview(loadingIndicator)
        loadingIndicator.pin(anchors: [.centerX, .centerY], to: self)

        addSubview(uploadingOverlay)
        uploadingOverlay.pin(to: self)

        addSubview(playButton)
        playButton.pin(anchors: [.centerY, .centerX], to: self)
    }

    override open func contentDidChanged() {
        super.contentDidChanged()

        if content == nil {
            cancelImageLoading()
            imageView.image = nil
            return
        }

        loadingIndicator.isHidden = false
        imageView.image = nil
        playButton.isVisible = false

        if let thumbnailURL = content?.thumbnailURL {
            showPreview(using: thumbnailURL)
        } else if let url = content?.videoURL {
            components.videoLoader.loadPreviewForVideo(at: url) { [weak self] in
                self?.loadingIndicator.isHidden = true
                switch $0 {
                case let .success(preview):
                    self?.showPreview(using: preview)
                case .failure:
                    break
                }
            }
        }

        uploadingOverlay.content = content?.uploadingState
        uploadingOverlay.isVisible = uploadingOverlay.content != nil
    }

    private func showPreview(using thumbnailURL: URL) {
        loadImage(from: thumbnailURL) { [weak self] result in
            self?.loadingIndicator.isHidden = true
            guard case let .success = result else { return }
            self?.playButton.isVisible = self?.content?.uploadingState == nil
        }
    }

    private func showPreview(using thumbnail: UIImage) {
        imageView.image = thumbnail
        playButton.isVisible = content?.uploadingState == nil
    }

    /// A handler that is invoked when view is tapped.
    @objc open func handleTapOnAttachment(_ recognizer: UITapGestureRecognizer) {
        guard let attachment = content else { return }

        didTapOnAttachment?(attachment)
    }

    /// A handler that is invoked when `playButton` is touched up inside.
    @objc open func handleTapOnPlay(_ sender: UIButton) {
        guard let attachment = content else { return }

        didTapOnAttachment?(attachment)
    }

    deinit {
        content = nil
    }
}

extension VideoAttachmentGalleryPreview: GalleryItemPreview {
    public var attachmentId: AttachmentId? {
        content?.id
    }
}
