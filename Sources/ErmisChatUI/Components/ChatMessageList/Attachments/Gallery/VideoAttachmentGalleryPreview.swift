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

    /// Displays the authenticated video duration before the user opens the gallery player.
    /// This avoids probing/downloading E2EE originals just to populate a timeline thumbnail.
    open private(set) lazy var durationLabel = UILabel()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "videoDurationLabel")

    override open func setUpTheme() {
        super.setUpTheme()

        imageView.backgroundColor = theme.colors.surfaceContainer
        imageView.contentMode = .scaleAspectFill
        imageView.layer.masksToBounds = true
        imageView.layer.cornerRadius = 12
        imageView.layer.borderWidth = 1
        imageView.layer.borderColor = theme.colors.outline.cgColor
        imageView.tintColor = theme.colors.subtitleText

        playButton.setImage(theme.icons.bigPlay, for: .normal)

        durationLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        durationLabel.textColor = .white
        durationLabel.font = .monospacedDigitSystemFont(
            ofSize: theme.fonts.caption1.pointSize,
            weight: .semibold
        )
        durationLabel.layer.cornerRadius = 4
        durationLabel.layer.masksToBounds = true
        durationLabel.textAlignment = .center
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

        addSubview(durationLabel)
        durationLabel.pin(anchors: [.trailing, .bottom], to: self, contant: -8)
        durationLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        durationLabel.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    override open func contentDidChanged() {
        super.contentDidChanged()

        if content == nil {
            imageView.image = nil
            durationLabel.isHidden = true
            return
        }

        loadingIndicator.isHidden = false
        imageView.image = nil
        playButton.isVisible = false

        let duration = content?.payload.duration
        durationLabel.text = duration.flatMap(formatters.videoDuration.format)
        durationLabel.isHidden = durationLabel.text == nil || content?.uploadingState != nil

        if let thumbnailData = content?.thumbnailData, let thumbImage = UIImage(data: thumbnailData) {
            imageView.currentImageLoadingTask?.cancel()
            showPreview(using: thumbImage)
            loadingIndicator.isHidden = true
        } else if let thumbnailURL = content?.thumbnailURL {
            showPreview(using: thumbnailURL)
        } else if let url = content?.videoURL,
                  url.scheme != "ermis-e2ee-attachment" {
            components.videoLoader.loadPreviewForVideo(at: url) { [weak self] in
                guard self?.content?.videoURL == url else { return }
                self?.loadingIndicator.isHidden = true
                switch $0 {
                case let .success(preview):
                    self?.showPreview(using: preview)
                case .failure:
                    break
                }
            }
        } else {
            // Legacy or foreign E2EE video manifests may legitimately contain only the original.
            // Keep the outlined video card visible, but do not place another centered symbol under
            // the play button. The play control is the single visual affordance for this fallback.
            imageView.contentMode = .center
            imageView.image = nil
            loadingIndicator.isHidden = true
            playButton.isVisible = content?.uploadingState == nil
        }

        uploadingOverlay.content = content?.uploadingState
        uploadingOverlay.isVisible = uploadingOverlay.content != nil
    }

    private func showPreview(using thumbnailURL: URL) {
        imageView.contentMode = .scaleAspectFill
        loadImage(from: thumbnailURL) { [weak self] result in
            self?.loadingIndicator.isHidden = true
            guard case let .success = result else { return }
            self?.playButton.isVisible = self?.content?.uploadingState == nil
        }
    }

    private func showPreview(using thumbnail: UIImage) {
        imageView.contentMode = .scaleAspectFill
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
