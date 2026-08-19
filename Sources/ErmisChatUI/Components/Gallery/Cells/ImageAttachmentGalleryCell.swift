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
    /// Returns a cancellation closure for the in-flight original resolver, if any. Gallery cells
    /// must release full-download work immediately when they are reused or dismissed.
    public var imageURLResolver: ((
        AnyMessageAttachment,
        @escaping @Sendable (E2eeAttachmentOriginalDownloadProgress) -> Void,
        @escaping (Result<E2eeAttachmentOriginalLease, Error>) -> Void
    ) -> (() -> Void)?)?

    /// Notifies the gallery when a full E2EE original is using an interactive download slot.
    /// Thumbnails do not affect this state.
    public var originalResolutionStateDidChange: ((Bool) -> Void)?

    /// Emits progress for the visible original only. The gallery owns presentation of the value;
    /// the cell deliberately keeps the encrypted preview visible while the original is verified.
    public var originalResolutionProgressDidChange: ((E2eeAttachmentOriginalDownloadProgress) -> Void)?

    public private(set) var isResolvingE2eeOriginal = false

    /// Gallery pages beside the selected item keep their encrypted thumbnail only. Loading a full
    /// original is reserved for the attachment the user is actively viewing.
    public var isE2eeOriginalResolutionEnabled = true {
        didSet {
            guard oldValue != isE2eeOriginalResolutionEnabled else { return }
            if isE2eeOriginalResolutionEnabled {
                contentDidChanged()
            } else {
                cancelPendingOriginalResolution()
                resolutionToken = UUID()
            }
        }
    }

    private var resolutionToken = UUID()
    private var cancelOriginalResolution: (() -> Void)?
    private var originalLease: E2eeAttachmentOriginalLease?
    private var resolvedOpaqueURL: URL?

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
        guard isE2eeOriginalResolutionEnabled else { return }
        if resolvedOpaqueURL == imageURL,
           originalLease != nil || isResolvingE2eeOriginal {
            return
        }

        cancelPendingOriginalResolution()
        resolutionToken = UUID()
        let token = resolutionToken
        guard let content, let imageURLResolver else { return }
        setResolvingE2eeOriginal(true)
        resolvedOpaqueURL = imageURL
        cancelOriginalResolution = imageURLResolver(
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
                    guard case let .success(lease) = result else {
                        self.resolvedOpaqueURL = nil
                        return
                    }
                    self.originalLease?.release()
                    self.originalLease = lease
                    self.displayImage(at: lease.localURL, attachment: imageAttachment)
                }
            }
        )
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

    public func cancelPendingOriginalResolution() {
        cancelOriginalResolution?()
        cancelOriginalResolution = nil
        imageDownloadTask?.cancel()
        imageDownloadTask = nil
        originalLease?.release()
        originalLease = nil
        resolvedOpaqueURL = nil
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
        imageURLResolver = nil
        originalResolutionStateDidChange = nil
        originalResolutionProgressDidChange = nil
    }
}
