//
// Copyright 2025 Ermis Inc.
//

import AVKit
import ErmisChat
import UIKit

/// `UICollectionViewCell` for video gallery item.
open class VideoAttachmentGalleryCell: GalleryCollectionViewCell, RemoteImageDisplayable {
    /// A cell reuse identifier.
    open class var reuseId: String { String(describing: self) }

    /// A player that handles the video content.
    public var player: AVPlayer {
        playerView.player
    }

    /// Resolves encrypted opaque media URLs to verified local plaintext files before AVPlayer sees
    /// them. Standard video URLs bypass this closure unchanged in `ErmisClient`.
    /// Returns a cancellation closure for the in-flight original resolver, if any. This prevents
    /// a dismissed video gallery from continuing a full authenticated download in the background.
    public var videoURLResolver: ((
        AnyMessageAttachment,
        @escaping @Sendable (E2eeAttachmentOriginalDownloadProgress) -> Void,
        @escaping (Result<URL, Error>) -> Void
    ) -> (() -> Void)?)?

    /// Notifies the gallery when a full E2EE original is using an interactive download slot.
    /// The poster thumbnail remains available independently from this state.
    public var originalResolutionStateDidChange: ((Bool) -> Void)?

    /// Emits encrypted-download / verification / decryption state for the visible original.
    public var originalResolutionProgressDidChange: ((E2eeAttachmentOriginalDownloadProgress) -> Void)?

    public private(set) var isResolvingE2eeOriginal = false

    /// Gallery pages beside the selected item keep their decrypted preview. The full original is
    /// requested only for the item the user is actively viewing.
    public var isE2eeOriginalResolutionEnabled = true {
        didSet {
            guard oldValue != isE2eeOriginalResolutionEnabled else { return }
            if isE2eeOriginalResolutionEnabled {
                contentDidChanged()
            } else {
                cancelPendingOriginalResolution()
                resolutionToken = UUID()
                player.pause()
            }
        }
    }

    private var resolutionToken = UUID()
    private var cancelOriginalResolution: (() -> Void)?

    /// Image view to be used for zoom in/out animation.
    open private(set) lazy var animationPlaceholderImageView: UIImageView = UIImageView()
        .withoutAutoresizingMaskConstraints

    /// A view that displays currently playing video.
    open private(set) lazy var playerView: PlayerView = components
        .playerView.init()
        .withoutAutoresizingMaskConstraints

    public var imageView: UIImageView {
        return animationPlaceholderImageView
    }

    override open func setUpTheme() {
        super.setUpTheme()

        animationPlaceholderImageView.clipsToBounds = true
        animationPlaceholderImageView.contentMode = .scaleAspectFit
    }

    override open func setUpUI() {
        super.setUpUI()

        scrollView.addSubview(animationPlaceholderImageView)
        animationPlaceholderImageView.pin(anchors: [.height, .width], to: contentView)

        animationPlaceholderImageView.addSubview(playerView)
        playerView.pin(to: animationPlaceholderImageView)
        playerView.pin(anchors: [.height, .width], to: animationPlaceholderImageView)
    }

    override open func contentDidChanged() {
        super.contentDidChanged()

        let videoAttachment = content?.attachment(payloadType: VideoAttachmentPayload.self)

        if let thumbnailData = content?.thumbnailData {
            showPreview(using: UIImage(data: thumbnailData))
        }

        let newAssetURL = videoAttachment?.videoURL
        let currentAssetURL = (player.currentItem?.asset as? AVURLAsset)?.url

        if newAssetURL != currentAssetURL {
            cancelPendingOriginalResolution()
            resolutionToken = UUID()
            let token = resolutionToken
            player.replaceCurrentItem(with: nil)

            if let content, let videoURLResolver, newAssetURL?.scheme == "ermis-e2ee-attachment" {
                guard isE2eeOriginalResolutionEnabled else { return }
                setResolvingE2eeOriginal(true)
                cancelOriginalResolution = videoURLResolver(
                    content,
                    { [weak self] progress in
                        DispatchQueue.main.async {
                            guard let self, self.resolutionToken == token else { return }
                            self.originalResolutionProgressDidChange?(progress)
                        }
                    },
                    { [weak self] result in
                        DispatchQueue.main.async {
                            guard let self, self.resolutionToken == token else { return }
                            self.cancelOriginalResolution = nil
                            self.setResolvingE2eeOriginal(false)
                            switch result {
                            case let .success(localURL):
                                self.player.replaceCurrentItem(
                                    with: AVPlayerItem(asset: self.components.videoLoader.videoAsset(at: localURL))
                                )
                            case .failure:
                                self.player.replaceCurrentItem(with: nil)
                            }
                        }
                    }
                )
            } else {
                let playerItem = newAssetURL.map {
                    AVPlayerItem(asset: components.videoLoader.videoAsset(at: $0))
                }
                player.replaceCurrentItem(with: playerItem)
            }

            if let thumbnailURL = videoAttachment?.thumbnailURL {
                showPreview(using: thumbnailURL)
            } else if content?.thumbnailData == nil, let url = newAssetURL,
                      url.scheme != "ermis-e2ee-attachment" {
                components.videoLoader.loadPreviewForVideo(at: url) { [weak self] in
                    switch $0 {
                    case let .success(preview):
                        self?.showPreview(using: preview)
                    case .failure:
                        self?.showPreview(using: nil)
                    }
                }
            }
        }
    }

    private func showPreview(using thumbnailURL: URL) {
        loadImage(from: thumbnailURL)
    }

    private func showPreview(using thumbnail: UIImage?) {
        animationPlaceholderImageView.image = thumbnail
    }

    override open func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        animationPlaceholderImageView
    }

    public func cancelPendingOriginalResolution() {
        cancelOriginalResolution?()
        cancelOriginalResolution = nil
        setResolvingE2eeOriginal(false)
    }

    private func setResolvingE2eeOriginal(_ isResolving: Bool) {
        guard isResolvingE2eeOriginal != isResolving else { return }
        isResolvingE2eeOriginal = isResolving
        originalResolutionStateDidChange?(isResolving)
    }

    open override func prepareForReuse() {
        super.prepareForReuse()
        cancelPendingOriginalResolution()
        resolutionToken = UUID()
        imageView.image = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        videoURLResolver = nil
        originalResolutionStateDidChange = nil
        originalResolutionProgressDidChange = nil
    }
}
