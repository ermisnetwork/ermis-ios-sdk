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
    public var videoURLResolver: ((AnyMessageAttachment, @escaping (Result<URL, Error>) -> Void) -> Void)?

    private var resolutionToken = UUID()

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
            resolutionToken = UUID()
            let token = resolutionToken
            player.replaceCurrentItem(with: nil)

            if let content, let videoURLResolver, newAssetURL?.scheme == "ermis-e2ee-attachment" {
                videoURLResolver(content) { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self, self.resolutionToken == token else { return }
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

    open override func prepareForReuse() {
        super.prepareForReuse()
        resolutionToken = UUID()
        imageView.image = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        videoURLResolver = nil
    }
}
