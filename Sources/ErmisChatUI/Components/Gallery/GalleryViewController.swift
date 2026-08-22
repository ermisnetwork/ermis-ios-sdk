//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat
import UIKit

/// A viewcontroller to showcase and slide through multiple attachments
/// (images and videos by default).
open class GalleryViewController: _ViewController,
                                  UIGestureRecognizerDelegate,
                                  UICollectionViewDataSource,
                                  UICollectionViewDelegate,
                                  UICollectionViewDelegateFlowLayout,
                                  UIProvider {
    /// The content of gallery view controller.
    public struct Content {
        /// The message which attachments are displayed by the gallery.
        public var message: ChatMessage
        /// The index of currently visible gallery item.
        public var currentPage: Int

        public init(
            message: ChatMessage,
            currentPage: Int = 0
        ) {
            self.message = message
            self.currentPage = currentPage
        }
    }

    /// Content to display.
    open var content: Content! {
        didSet {
            updateContentIfNeeded()
        }
    }

    public var client: ErmisClient?

    /// Items to display.
    open var items: [AnyMessageAttachment] {
        let videos = content.message.videoAttachments.map(\.asAnyAttachment)
        let images = content.message.imageAttachments.map(\.asAnyAttachment)
        return videos + images
    }

    /// Returns the date formatter function used to represent when the user was last seen online.
    open var lastSeenDateFormatter: (Date) -> String? { formatters.userLastActivity.format }

    /// Controller for handling the transition for dismissal
    open var transitionController: ZoomTransitionController!

    /// `UICollectionViewFlowLayout` instance for `attachmentsCollectionView`.
    open private(set) lazy var attachmentsFlowLayout: UICollectionViewFlowLayout = .init()

    /// `UICollectionView` instance to display attachments.
    open private(set) lazy var attachmentsCollectionView: UICollectionView = UICollectionView(
        frame: .zero,
        collectionViewLayout: attachmentsFlowLayout
    )
    .withoutAutoresizingMaskConstraints

    /// Bar view displayed at the top.
    open private(set) lazy var topBarView = UIView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "topBarView")

    /// Stack view inside the `topBarView`'s view hierarchy
    open private(set) lazy var topBarContainerStackView = ContainerStackView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "topBarContainerStackView")

    /// Stack view that displays user and date label.
    open private(set) lazy var infoContainerStackView = ContainerStackView()
        .withAccessibilityIdentifier(identifier: "infoContainerStackView")

    /// Label to show information about the user that sent the message.
    open private(set) lazy var userLabel = UILabel()
        .withoutAutoresizingMaskConstraints
        .withBidirectionalLanguagesSupport
        .withAdjustingFontForContentSizeCategory
        .withAccessibilityIdentifier(identifier: "userLabel")

    /// Label to show information about the date the message was sent at.
    open private(set) lazy var dateLabel = UILabel()
        .withoutAutoresizingMaskConstraints
        .withBidirectionalLanguagesSupport
        .withAdjustingFontForContentSizeCategory
        .withAccessibilityIdentifier(identifier: "dateLabel")

    /// Visible only while the current E2EE original is being fetched. Network completion is not
    /// treated as media readiness: `.verifying` and `.decrypting` stay explicit to avoid a false
    /// "100% complete" state while authenticated processing is still running.
    open private(set) lazy var originalDownloadProgressLabel = UILabel()
        .withoutAutoresizingMaskConstraints
        .withBidirectionalLanguagesSupport
        .withAdjustingFontForContentSizeCategory
        .withAccessibilityIdentifier(identifier: "originalDownloadProgressLabel")

    /// Bar view displayed at the bottom.
    open private(set) lazy var bottomBarView = UIView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "bottomBarView")

    /// Stack view inside the `bottomBarView`'s view hierarchy
    open private(set) lazy var bottomBarContainerStackView = ContainerStackView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "bottomBarContainerStackView")

    /// Label to show which photo is currently being displayed.
    open private(set) lazy var currentPhotoLabel = UILabel()
        .withoutAutoresizingMaskConstraints
        .withBidirectionalLanguagesSupport
        .withAdjustingFontForContentSizeCategory
        .withAccessibilityIdentifier(identifier: "currentPhotoLabel")

    /// Button for closing this view controller.
    open private(set) lazy var closeButton = components
        .closeButton.init()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "closeButton")

    /// Button for download attachments.
    open private(set) lazy var downloadButton = components
        .downloadButton.init()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "downloadButton")

    /// View that controls the video player of currently visible cell.
    open private(set) lazy var videoPlaybackBar: VideoPlaybackControlView = components
        .videoPlaybackControlView.init()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "videoPlaybackBar")

    /// Button for sharing content.
    open private(set) lazy var shareButton = components
        .shareButton.init()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "shareButton")

    /// A constaint between `topBarView.topAnchor` and `view.topAnchor`.
    open private(set) var topBarTopConstraint: NSLayoutConstraint?

    /// A constaint between `bottomBarView.bottomAnchor` and `view.bottomAnchor`.
    open private(set) var bottomBarBottomConstraint: NSLayoutConstraint?

    open private(set) lazy var alertRouter = components.alertsRouter.init(rootViewController: self)

    /// Explicit Save may outlive this gallery. Use its stable presenting owner for document export
    /// so a completed file download never tries to present a picker from a detached gallery.
    open private(set) lazy var attachmentSaver = client?.attachmentSaver(
        presentingFrom: presentingViewController ?? self
    )

    /// Share is viewer-scoped: if the gallery disappears before the verified original is ready,
    /// do not present a share sheet from a detached view controller. Explicit Save deliberately
    /// has independent ownership and is therefore not stored here.
    private var sharePreparationTask: _Concurrency.Task<Void, Never>?

    override open func setUpTheme() {
        super.setUpTheme()

        view.backgroundColor = theme.colors.surface

        attachmentsCollectionView.backgroundColor = .clear
        attachmentsCollectionView.showsHorizontalScrollIndicator = false
        attachmentsCollectionView.showsVerticalScrollIndicator = false

        topBarView.backgroundColor = theme.colors.surfaceContainer
        bottomBarView.backgroundColor = theme.colors.surfaceContainer
        videoPlaybackBar.backgroundColor = theme.colors.surfaceContainer

        userLabel.font = theme.fonts.body.bold
        userLabel.textColor = theme.colors.text
        userLabel.adjustsFontForContentSizeCategory = true
        userLabel.textAlignment = .center

        dateLabel.font = theme.fonts.footnote
        dateLabel.textColor = theme.colors.subtitleText
        dateLabel.adjustsFontForContentSizeCategory = true
        dateLabel.textAlignment = .center

        originalDownloadProgressLabel.font = theme.fonts.footnote
        originalDownloadProgressLabel.textColor = theme.colors.subtitleText
        originalDownloadProgressLabel.adjustsFontForContentSizeCategory = true
        originalDownloadProgressLabel.textAlignment = .center
        originalDownloadProgressLabel.numberOfLines = 1

        currentPhotoLabel.font = theme.fonts.body.bold
        currentPhotoLabel.textColor = theme.colors.text
        currentPhotoLabel.adjustsFontForContentSizeCategory = true
        currentPhotoLabel.textAlignment = .center

    }

    override open func setUp() {
        super.setUp()
        attachmentsFlowLayout.scrollDirection = .horizontal
        attachmentsFlowLayout.minimumInteritemSpacing = 0
        attachmentsFlowLayout.minimumLineSpacing = 0

        attachmentsCollectionView.register(
            components.imageAttachmentGalleryCell.self,
            forCellWithReuseIdentifier: components.imageAttachmentGalleryCell.reuseId
        )
        attachmentsCollectionView.register(
            components.videoAttachmentGalleryCell.self,
            forCellWithReuseIdentifier: components.videoAttachmentGalleryCell.reuseId
        )
        attachmentsCollectionView.contentInsetAdjustmentBehavior = .never
        attachmentsCollectionView.isPagingEnabled = true
        attachmentsCollectionView.alwaysBounceVertical = false
        attachmentsCollectionView.alwaysBounceHorizontal = true
        attachmentsCollectionView.dataSource = self
        attachmentsCollectionView.delegate = self

        closeButton.addTarget(self, action: #selector(closeButtonTapped), for: .touchUpInside)
        downloadButton.addTarget(self, action: #selector(downloadButtonTapped), for: .touchUpInside)
        shareButton.addTarget(self, action: #selector(shareButtonTapped), for: .touchUpInside)

        let panGestureRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        panGestureRecognizer.delegate = self
        view.addGestureRecognizer(panGestureRecognizer)
    }

    override open func setUpUI() {
        super.setUpUI()

        view.embed(attachmentsCollectionView)

        view.addSubview(topBarView)
        topBarView.pin(anchors: [.leading, .trailing], to: view)
        topBarTopConstraint = topBarView.topAnchor.pin(equalTo: view.topAnchor)
        topBarTopConstraint?.isActive = true

        topBarView.embed(topBarContainerStackView)
        topBarContainerStackView.preservesSuperviewLayoutMargins = true
        topBarContainerStackView.isLayoutMarginsRelativeArrangement = true

        topBarContainerStackView.addArrangedSubview(closeButton)

        infoContainerStackView.axis = .vertical
        infoContainerStackView.alignment = .center
        infoContainerStackView.spacing = 4
        topBarContainerStackView.addArrangedSubview(infoContainerStackView)
        infoContainerStackView.pin(anchors: [.centerX], to: view)

        userLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        infoContainerStackView.addArrangedSubview(userLabel)

        infoContainerStackView.addArrangedSubview(dateLabel)

        originalDownloadProgressLabel.isHidden = true
        infoContainerStackView.addArrangedSubview(originalDownloadProgressLabel)

        topBarContainerStackView.addArrangedSubview(UIView.spacer(axis: .horizontal))
        topBarContainerStackView.addArrangedSubview(downloadButton)

        view.addSubview(bottomBarView)
        bottomBarView.pin(anchors: [.leading, .trailing], to: view)
        bottomBarBottomConstraint = bottomBarView.bottomAnchor.pin(equalTo: view.bottomAnchor)
        bottomBarBottomConstraint?.isActive = true

        bottomBarContainerStackView.preservesSuperviewLayoutMargins = true
        bottomBarContainerStackView.isLayoutMarginsRelativeArrangement = true
        bottomBarView.embed(bottomBarContainerStackView)

        shareButton.setContentHuggingPriority(.ermisRequire, for: .horizontal)
        shareButton.contentEdgeInsets = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        bottomBarContainerStackView.addArrangedSubview(shareButton)

        currentPhotoLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bottomBarContainerStackView.addArrangedSubview(currentPhotoLabel)
        currentPhotoLabel.pin(anchors: [.centerX], to: view)

        bottomBarContainerStackView.addArrangedSubview(.spacer(axis: .horizontal))

        view.addSubview(videoPlaybackBar)
        videoPlaybackBar.pin(anchors: [.leading, .trailing], to: view)
        videoPlaybackBar.bottomAnchor.pin(equalTo: bottomBarView.topAnchor).isActive = true
    }

    override open func viewDidLoad() {
        super.viewDidLoad()

        attachmentsCollectionView.reloadData()
        DispatchQueue.main.async {
            self.attachmentsCollectionView.performBatchUpdates(nil) { _ in
                self.contentDidChanged()
                self.attachmentsCollectionView.scrollToItem(
                    at: .init(item: self.content.currentPage, section: 0),
                    at: .centeredHorizontally,
                    animated: false
                )
            }
        }
    }

    override open func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        videoPlaybackBar.player?.pause()

        // Full E2EE originals are downloaded only to satisfy an active gallery viewer. Do not let
        // a quick open/close leave large downloads competing with the next attachment the user
        // selects. Each cell releases a reference; shared downloads survive while another cell is
        // still using the same asset.
        attachmentsCollectionView.visibleCells.forEach { cell in
            (cell as? ImageAttachmentGalleryCell)?.cancelPendingOriginalResolution()
            (cell as? VideoAttachmentGalleryCell)?.cancelPendingOriginalResolution()
        }
        sharePreparationTask?.cancel()
        sharePreparationTask = nil
        shareButton.isEnabled = true
    }

    override open func contentDidChanged() {
        super.contentDidChanged()

        if content.message.author.isOnline {
            dateLabel.text = L10n.Message.Title.online
        } else {
            if
                let lastActive = content.message.author.lastActiveAt,
                let timeAgo = lastSeenDateFormatter(lastActive) {
                dateLabel.text = timeAgo
            } else {
                dateLabel.text = L10n.Message.Title.offline
            }
        }

        userLabel.text = content.message.author.name

        currentPhotoLabel.text = L10n.currentSelection(content.currentPage + 1, items.count)

        let videoCell = attachmentsCollectionView.cellForItem(
            at: currentItemIndexPath
        ) as? VideoAttachmentGalleryCell

        videoPlaybackBar.player = videoCell?.player
        videoPlaybackBar.isHidden = videoPlaybackBar.player == nil
        updateOriginalDownloadProgressPresentation()
    }

    /// Called whenever user pans with a given `gestureRecognizer`.
    @objc open func handlePan(with gestureRecognizer: UIPanGestureRecognizer) {
        // `GalleryViewController` is also used outside `MessageListRouter` (for
        // example from Channel Info). Those callers can intentionally use the
        // system presentation transition and therefore do not provide a zoom
        // transition controller. A pan must never make the gallery crash in
        // that configuration; the close button remains the dismissal path.
        guard let transitionController else { return }

        switch gestureRecognizer.state {
        case .began:
            transitionController.isInteractive = true
            dismiss(animated: true, completion: nil)
        case .ended:
            guard transitionController.isInteractive else { return }
            transitionController.isInteractive = false
            transitionController.handlePan(with: gestureRecognizer)
        default:
            guard transitionController.isInteractive else { return }
            transitionController.handlePan(with: gestureRecognizer)
        }
    }

    open func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let panGestureRecognizer = gestureRecognizer as? UIPanGestureRecognizer else {
            return true
        }

        let beginsInsidePlaybackControls = videoPlaybackBar.frame.contains(
            panGestureRecognizer.location(in: view)
        )
        return GalleryDismissalPanPolicy.shouldBegin(
            velocity: panGestureRecognizer.velocity(in: view),
            beginsInsidePlaybackControls: beginsInsidePlaybackControls,
            hasTransitionController: transitionController != nil
        )
    }

    /// Called when `closeButton` is tapped.
    @objc open func closeButtonTapped() {
        dismiss(animated: true, completion: nil)
    }

    /// Called when `downloadButton` is tapped.
    @objc open func downloadButtonTapped() {
        guard let client, let attachmentSaver else { return }
        downloadButton.isEnabled = false
        let attachment = currentItem
        guard client.requiresVerifiedE2eeOriginal(attachment) else {
            attachmentSaver.downloadAttachments(attachments: [attachment], completion: { [weak self] error in
                self?.alertRouter.showDownloadAttachmentAlertResult(isSuccess: error == nil)
                self?.downloadButton.isEnabled = true
            })
            return
        }

        // Explicit Save owns a requester independently from the visible cell. Closing the viewer
        // cancels only the viewer requester; Save still receives one verified local plaintext URL.
        _Concurrency.Task { [weak self, client, attachmentSaver] in
            do {
                let lease = try await client.acquireAttachmentForViewing(
                    attachment,
                    progress: { [weak self] progress in
                        DispatchQueue.main.async { self?.updateOriginalDownloadProgress(progress) }
                    }
                )
                defer { lease.release() }
                try _Concurrency.Task.checkCancellation()
                await withCheckedContinuation { continuation in
                    attachmentSaver.saveVerifiedAttachment(
                        at: lease.localURL,
                        attachment: attachment
                    ) { [weak self] error in
                        self?.alertRouter.showDownloadAttachmentAlertResult(isSuccess: error == nil)
                        self?.downloadButton.isEnabled = true
                        self?.updateOriginalDownloadProgressPresentation()
                        continuation.resume()
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.downloadButton.isEnabled = true
                    self?.updateOriginalDownloadProgressPresentation()
                }
            } catch {
                await MainActor.run {
                    self?.alertRouter.showDownloadAttachmentAlertResult(isSuccess: false)
                    self?.downloadButton.isEnabled = true
                    self?.updateOriginalDownloadProgressPresentation()
                }
            }
        }
    }

    /// Called when `shareButton` is tapped.
    @objc open func shareButtonTapped() {
        guard let client else { return }
        let attachment = currentItem
        guard client.requiresVerifiedE2eeOriginal(attachment) else {
            presentShareSheet(for: shareItem(at: currentItemIndexPath))
            return
        }

        shareButton.isEnabled = false
        sharePreparationTask?.cancel()
        sharePreparationTask = _Concurrency.Task { [weak self, client] in
            defer {
                DispatchQueue.main.async { [weak self] in
                    self?.sharePreparationTask = nil
                }
            }
            do {
                let lease = try await client.acquireAttachmentForViewing(
                    attachment,
                    progress: { [weak self] progress in
                        DispatchQueue.main.async { self?.updateOriginalDownloadProgress(progress) }
                    }
                )
                try _Concurrency.Task.checkCancellation()
                await MainActor.run {
                    guard let self else {
                        lease.release()
                        return
                    }
                    self.shareButton.isEnabled = true
                    self.updateOriginalDownloadProgressPresentation()
                    self.presentShareSheet(for: lease.localURL, lease: lease)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.shareButton.isEnabled = true
                    self?.updateOriginalDownloadProgressPresentation()
                }
            } catch {
                await MainActor.run {
                    self?.shareButton.isEnabled = true
                    self?.updateOriginalDownloadProgressPresentation()
                    self?.alertRouter.showDownloadAttachmentAlertResult(isSuccess: false)
                }
            }
        }
    }

    private func presentShareSheet(
        for shareItem: Any?,
        lease: E2eeAttachmentOriginalLease? = nil
    ) {
        guard let shareItem else {
            lease?.release()
            log.assertionFailure("Share item is missing for item at \(currentItemIndexPath).")
            return
        }
        let activityViewController = UIActivityViewController(
            activityItems: [shareItem],
            applicationActivities: nil
        )
        activityViewController.completionWithItemsHandler = { _, _, _, _ in
            lease?.release()
        }
        activityViewController.popoverPresentationController?.sourceView = shareButton
        present(activityViewController, animated: true)
    }

    /// Updates `currentPage`.
    open func updateCurrentPage() {
        content.currentPage = Int(attachmentsCollectionView.contentOffset.x + attachmentsCollectionView.bounds.width / 2) /
            Int(attachmentsCollectionView.bounds.width)
        updateVisibleE2eeOriginalResolution()
        contentDidChanged()
    }

    open func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    open func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let reuseIdentifier = cellReuseIdentifierForItem(at: indexPath) else {
            log.assertionFailure("Reuse identifier is missing for item at \(indexPath)")
            return UICollectionViewCell()
        }

        let cell = collectionView.dequeueReusableCell(with: GalleryCollectionViewCell.self, for: indexPath, reuseIdentifier: reuseIdentifier)

        guard let item = getItem(at: indexPath) else { return cell }

        if let imageCell = cell as? ImageAttachmentGalleryCell {
            imageCell.imageURLResolver = { [weak client] attachment, progress, completion in
                guard let client else {
                    completion(.failure(URLError(.cancelled)))
                    return nil
                }
                let task = _Concurrency.Task {
                    do {
                        let lease = try await client.acquireAttachmentForViewing(
                            attachment,
                            progress: progress
                        )
                        guard !_Concurrency.Task.isCancelled else {
                            lease.release()
                            return
                        }
                        completion(.success(lease))
                    } catch is CancellationError {
                        // A gallery close is an expected cancellation, not a render failure.
                    } catch {
                        guard !_Concurrency.Task.isCancelled else { return }
                        completion(.failure(error))
                    }
                }
                return { task.cancel() }
            }
            imageCell.isE2eeOriginalResolutionEnabled = indexPath == currentItemIndexPath
            imageCell.originalResolutionStateDidChange = { [weak self, weak imageCell] _ in
                DispatchQueue.main.async {
                    guard let self,
                          let imageCell,
                          self.attachmentsCollectionView.indexPath(for: imageCell) == self.currentItemIndexPath else {
                        return
                    }
                    self.updateOriginalDownloadProgressPresentation()
                }
            }
            imageCell.originalResolutionProgressDidChange = { [weak self, weak imageCell] progress in
                guard let self,
                      let imageCell,
                      self.attachmentsCollectionView.indexPath(for: imageCell) == self.currentItemIndexPath else {
                    return
                }
                self.updateOriginalDownloadProgress(progress)
            }
        }

        if let videoCell = cell as? VideoAttachmentGalleryCell {
            videoCell.videoPlaybackResolver = { [weak client] attachment, progress, completion in
                guard let client else {
                    completion(.failure(URLError(.cancelled)))
                    return nil
                }
                let task = _Concurrency.Task {
                    do {
                        let lease = try await client.acquireVideoAttachmentForPlayback(
                            attachment,
                            progress: progress
                        )
                        guard !_Concurrency.Task.isCancelled else {
                            lease.release()
                            return
                        }
                        completion(.success(lease))
                    } catch is CancellationError {
                        // A gallery close is an expected cancellation, not a render failure.
                    } catch {
                        guard !_Concurrency.Task.isCancelled else { return }
                        completion(.failure(error))
                    }
                }
                return { task.cancel() }
            }
            videoCell.isE2eeOriginalResolutionEnabled = indexPath == currentItemIndexPath
            videoCell.originalResolutionStateDidChange = { [weak self, weak videoCell] _ in
                DispatchQueue.main.async {
                    guard let self,
                          let videoCell,
                          self.attachmentsCollectionView.indexPath(for: videoCell) == self.currentItemIndexPath else {
                        return
                    }
                    self.updateOriginalDownloadProgressPresentation()
                }
            }
            videoCell.originalResolutionProgressDidChange = { [weak self, weak videoCell] progress in
                guard let self,
                      let videoCell,
                      self.attachmentsCollectionView.indexPath(for: videoCell) == self.currentItemIndexPath else {
                    return
                }
                self.updateOriginalDownloadProgress(progress)
            }
        }

        cell.content = item

        cell.didTapOnce = { [weak self] in
            self?.handleSingleTapOnCell(at: indexPath)
        }

        return cell
    }

    open func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        collectionView.bounds.size
    }

    open func collectionView(
        _ collectionView: UICollectionView,
        targetContentOffsetForProposedContentOffset proposedContentOffset: CGPoint
    ) -> CGPoint {
        CGPoint(
            x: CGFloat(content.currentPage) * collectionView.bounds.width,
            y: proposedContentOffset.y
        )
    }

    open func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateCurrentPage()
    }

    open func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !decelerate else { return }
        updateCurrentPage()
    }

    open func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard let player = videoPlaybackBar.player,
              player.timeControlStatus != .paused else { return }
        player.pause()
    }

    override open func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        attachmentsFlowLayout.invalidateLayout()
        super.viewWillTransition(to: size, with: coordinator)
    }

    /// An index path for the currently visible cell.
    open var currentItemIndexPath: IndexPath {
        .init(item: content.currentPage, section: 0)
    }

    /// A currently visible gallery item.
    open var currentItem: AnyMessageAttachment {
        items.assertIndexIsPresent(currentItemIndexPath.item)
        return items[currentItemIndexPath.item]
    }

    /// Only the page the user is actually viewing may resolve a full E2EE original. Adjacent
    /// collection-view cells retain their already-decrypted thumbnail, which prevents a quick
    /// swipe through a media list from queueing several large foreground downloads.
    private func updateVisibleE2eeOriginalResolution() {
        let activeIndexPath = currentItemIndexPath
        attachmentsCollectionView.visibleCells.forEach { cell in
            let isActive = attachmentsCollectionView.indexPath(for: cell) == activeIndexPath
            (cell as? ImageAttachmentGalleryCell)?.isE2eeOriginalResolutionEnabled = isActive
            (cell as? VideoAttachmentGalleryCell)?.isE2eeOriginalResolutionEnabled = isActive
        }
    }

    /// Closing a gallery cancels its visible original request, so an additional gallery-level
    /// cancel button would duplicate the close action. This method only owns the transient
    /// progress label while the currently visible cell resolves its original.
    private func updateOriginalDownloadProgressPresentation() {
        let currentCell = attachmentsCollectionView.cellForItem(at: currentItemIndexPath)
        let isResolving = (currentCell as? ImageAttachmentGalleryCell)?.isResolvingE2eeOriginal == true
            || (currentCell as? VideoAttachmentGalleryCell)?.isResolvingE2eeOriginal == true
        if !isResolving {
            originalDownloadProgressLabel.isHidden = true
            originalDownloadProgressLabel.text = nil
        }
    }

    private func updateOriginalDownloadProgress(_ progress: E2eeAttachmentOriginalDownloadProgress) {
        let text: String
        switch progress.phase {
        case .queued:
            text = "Đang chờ tải"
        case .downloading:
            let completed = ByteCountFormatter.string(
                fromByteCount: Int64(progress.completedCiphertextBytes),
                countStyle: .file
            )
            let total = ByteCountFormatter.string(
                fromByteCount: Int64(progress.totalCiphertextBytes),
                countStyle: .file
            )
            let percentage = Int((progress.fractionCompleted ?? 0) * 100)
            text = "Đang tải \(completed) / \(total) · \(percentage)%"
        case .verifying:
            text = "Đang kiểm tra tệp"
        case .waitingForUnlock:
            text = "Mở khóa thiết bị để tiếp tục"
        case .decrypting:
            text = "Đang giải mã tệp"
        }
        originalDownloadProgressLabel.text = text
        originalDownloadProgressLabel.accessibilityLabel = text
        originalDownloadProgressLabel.isHidden = false
    }

    /// Returns a share item for the gallery item at given index path.
    /// - Parameter indexPath: An index path.
    /// - Returns: An item to share.
    open func shareItem(at indexPath: IndexPath) -> Any? {
        guard let item = getItem(at: indexPath) else { return nil }

        switch item.type {
        case .image:
            let cell = attachmentsCollectionView
                .cellForItem(at: indexPath) as? ImageAttachmentGalleryCell
            return cell?.imageView.image
        case .video:
            guard let itemAttachment = item.attachment(payloadType: VideoAttachmentPayload.self),
                  let urlData = try? Data(contentsOf: itemAttachment.videoURL) else {
                return nil
            }

            let fileName = itemAttachment.payload.title ?? itemAttachment.id.messageId.lowercased() + ".mp4"
            let filePath = NSTemporaryDirectory().appending("\(fileName)")
            let url = URL(fileURLWithPath: filePath)
            do {
                try urlData.write(to: url)
                return url
            } catch {
                return nil
            }
        default:
            return nil
        }
    }

    /// Returns cell reuse identifier for a gallery item at given index path.
    /// - Parameter indexPath: An index path.
    /// - Returns: A cell reuse identifier.
    open func cellReuseIdentifierForItem(at indexPath: IndexPath) -> String? {
        guard let item = getItem(at: indexPath) else { return nil }

        switch item.type {
        case .image:
            return components.imageAttachmentGalleryCell.reuseId
        case .video:
            return components.videoAttachmentGalleryCell.reuseId
        default:
            return nil
        }
    }

    /// Triggered when the current image is single tapped.
    open func handleSingleTapOnCell(at indexPath: IndexPath) {
        let areBarsHidden = bottomBarBottomConstraint?.constant != 0

        topBarTopConstraint?.constant = areBarsHidden ? 0 : -topBarView.frame.height
        bottomBarBottomConstraint?.constant = areBarsHidden ? 0 : bottomBarView.frame.height

        Animate {
            self.topBarView.alpha = areBarsHidden ? 1 : 0
            self.bottomBarView.alpha = areBarsHidden ? 1 : 0
            self.videoPlaybackBar.backgroundColor = areBarsHidden ? self.bottomBarView.backgroundColor : .clear
            self.view.layoutIfNeeded()
        }
    }

    /// Returns an image view to animate during interactive dismissing.
    open var imageViewToAnimateWhenDismissing: UIImageView? {
        let indexPath = currentItemIndexPath
        guard let item = getItem(at: indexPath) else { return nil }

        switch item.type {
        case .image:
            let cell = attachmentsCollectionView
                .cellForItem(at: indexPath) as? ImageAttachmentGalleryCell
            return cell?.imageView
        case .video:
            let cell = attachmentsCollectionView
                .cellForItem(at: indexPath) as? VideoAttachmentGalleryCell
            return cell?.animationPlaceholderImageView
        default:
            return nil
        }
    }

    private func getItem(at indexPath: IndexPath) -> AnyMessageAttachment? {
        let index = indexPath.item
        items.assertIndexIsPresent(index)
        return items[safe: index]
    }
}
