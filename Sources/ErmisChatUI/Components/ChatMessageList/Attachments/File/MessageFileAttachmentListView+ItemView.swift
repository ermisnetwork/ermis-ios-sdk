//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// Process-scoped presentation for an explicit file download/export.
///
/// The destination URL stays owned by the message-list controller and is never exposed through
/// this public UI value. Cells receive only non-sensitive progress and action state.
public enum FileAttachmentDownloadPresentation: Equatable {
    case idle
    case progress(AttachmentOriginalDownloadProgress)
    case choosingDestination
    case saved
    case failed
}

extension MessageFileAttachmentListView {
    open class ItemView: _View, UIProvider {
        /// Content of the attachment `MessageFileAttachment`
        public var content: MessageFileAttachment? {
            didSet { updateContentIfNeeded() }
        }

        /// Closure which notifies when the user tapped the attachment.
        open var didTapOnAttachment: ((MessageFileAttachment) -> Void)?

        /// Closure which notifies when the user tapped an attachment action. (Ex: Retry)
        open var didTapActionOnAttachment: ((MessageFileAttachment) -> Void)?

        /// Download/export state supplied by the owning message-list controller.
        public var downloadPresentation: FileAttachmentDownloadPresentation = .idle {
            didSet { applyDownloadPresentation() }
        }

        /// Label which shows name of the file, usually with extension (file.pdf)
        open private(set) lazy var fileNameLabel = UILabel()
            .withoutAutoresizingMaskConstraints
            .withBidirectionalLanguagesSupport
            .withAdjustingFontForContentSizeCategory
            .withAccessibilityIdentifier(identifier: "fileNameLabel")

        /// Label indicating size of the file.
        open private(set) lazy var fileSizeLabel = UILabel()
            .withoutAutoresizingMaskConstraints
            .withBidirectionalLanguagesSupport
            .withAdjustingFontForContentSizeCategory
            .withAccessibilityIdentifier(identifier: "fileSizeLabel")

        /// Animated indicator showing progress of uploading of a file.
        open private(set) lazy var loadingIndicator = components
            .loadingIndicator
            .init()
            .withoutAutoresizingMaskConstraints

        /// Byte progress for an explicit original download. It shares the file-size row and uses
        /// the primary accent color so it cannot be confused with upload activity.
        open private(set) lazy var downloadProgressView = UIProgressView(progressViewStyle: .default)
            .withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "downloadProgressView")

        /// imageView indicating action for the file attachment. (Download / Retry upload...)
        open private(set) lazy var actionIconImageView = UIImageView()
            .withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "actionIconImageView")

        open private(set) lazy var mainContainerStackView: ContainerStackView = ContainerStackView()
            .withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "mainContainerStackView")

        /// Stack containing loading indicator and label with fileSize.
        open private(set) lazy var spinnerAndSizeStack: ContainerStackView = ContainerStackView()
            .withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "spinnerAndSizeStack")

        /// Stack containing file name and and the size of the file.
        open private(set) lazy var fileNameAndSizeStack: ContainerStackView = ContainerStackView()
            .withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "fileNameAndSizeStack")

        open private(set) lazy var fileIconImageView = UIImageView()
            .withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "fileIconImageView")

        override open func setUp() {
            super.setUp()

            let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(didTapOnAttachment(_:)))
            mainContainerStackView.addGestureRecognizer(tapRecognizer)

            let actionTapRecognizer = UITapGestureRecognizer(target: self, action: #selector(didTapActionOnAttachment(_:)))
            actionIconImageView.addGestureRecognizer(actionTapRecognizer)
            actionIconImageView.isUserInteractionEnabled = true
        }

        override open func setUpTheme() {
            super.setUpTheme()

            fileSizeLabel.textColor = theme.colors.subtitleText
            fileSizeLabel.font = theme.fonts.subheadline.bold
            fileNameLabel.font = theme.fonts.body.bold
            fileNameLabel.lineBreakMode = .byTruncatingMiddle
            fileIconImageView.contentMode = .center
            downloadProgressView.progressTintColor = .systemCyan
            downloadProgressView.trackTintColor = .systemGray3
            actionIconImageView.tintColor = theme.colors.primary
            backgroundColor = theme.colors.surfaceContainer
            layer.cornerRadius = 12
            layer.masksToBounds = true
            layer.borderWidth = 1
            layer.borderColor = theme.colors.outline.cgColor
        }

        override open func setUpUI() {
            super.setUpUI()
            addSubview(mainContainerStackView)
            mainContainerStackView.pin(to: layoutMarginsGuide)

            spinnerAndSizeStack.addArrangedSubviews([loadingIndicator, fileSizeLabel, downloadProgressView])
            fileNameAndSizeStack.addArrangedSubviews([fileNameLabel, spinnerAndSizeStack])
            mainContainerStackView.addArrangedSubviews([fileIconImageView, fileNameAndSizeStack, actionIconImageView])

            downloadProgressView.widthAnchor.pin(equalToConstant: 84).isActive = true
            downloadProgressView.isHidden = true

            spinnerAndSizeStack.axis = .horizontal
            spinnerAndSizeStack.alignment = .center
            spinnerAndSizeStack.spacing = 8

            fileNameAndSizeStack.axis = .vertical
            fileNameAndSizeStack.alignment = .leading
            fileNameAndSizeStack.spacing = 3

            mainContainerStackView.axis = .horizontal
            mainContainerStackView.alignment = .center
        }

        override open func contentDidChanged() {
            super.contentDidChanged()

            fileIconImageView.image = fileIcon
            fileSizeLabel.isHidden = false
            fileSizeLabel.textColor = theme.colors.subtitleText
            actionIconImageView.accessibilityLabel = nil
            // If we cannot fetch filename, let's use only content type.
            fileNameLabel.text = content?.payload.title ?? content?.type.rawValue

            switch content?.uploadingState?.state {
            case .uploaded, .none:
                fileSizeLabel.text = content?.payload.file.sizeString
            case .uploadingFailed:
                fileSizeLabel.text = L10n.Message.Sending.attachmentUploadingFailed
            default:
                fileSizeLabel.text = content?.uploadingState?.fileUploadingProgress
            }

            if let state = content?.uploadingState?.state {
                actionIconImageView.image = theme.fileAttachmentActionIcon(for: state)
            } else {
                actionIconImageView.image = nil
            }

            switch content?.uploadingState?.state {
            case .pendingUpload, .uploading:
                loadingIndicator.isVisible = true
            default:
                loadingIndicator.isVisible = false
            }

            if content?.file.type == .unknown {
                fileNameLabel.text = L10n.Message.unsupportedAttachment
                fileSizeLabel.isHidden = true
            }

            applyDownloadPresentation()
        }

        @objc open func didTapOnAttachment(_ recognizer: UITapGestureRecognizer) {
            guard let attachment = content else { return }
            didTapOnAttachment?(attachment)
        }

        @objc open func didTapActionOnAttachment(_ recognizer: UITapGestureRecognizer) {
            guard let attachment = content else { return }
            didTapActionOnAttachment?(attachment)
        }

        private var fileIcon: UIImage? {
            guard let file = content?.payload.file else { return nil }

            /// If the `file.type` is `.aac` (VoiceRecording) but we `VoiceRecordings` feature
            /// is disabled, we don't want to show the `.aac` new icon and instead we are mapping it
            /// to an `.mp3`.
            let fileType: AttachmentFileType = file.type == .aac ? .mp3 : file.type

            return theme.icons.fileIcons[fileType] ?? theme.icons.fileFallback
        }

        private func applyDownloadPresentation() {
            guard let content else {
                downloadProgressView.isHidden = true
                return
            }
            if let uploadState = content.uploadingState?.state,
               uploadState != .uploaded {
                downloadProgressView.isHidden = true
                return
            }

            switch downloadPresentation {
            case .idle:
                downloadProgressView.isHidden = true
                downloadProgressView.progress = 0
                fileSizeLabel.text = content.payload.file.sizeString
                fileSizeLabel.textColor = theme.colors.subtitleText
                actionIconImageView.image = theme.fileAttachmentActionIcon(for: .uploaded)
                actionIconImageView.accessibilityLabel = L10n.Message.Actions.download

            case .progress(let progress):
                downloadProgressView.isHidden = false
                let fraction = Float(progress.fractionCompleted ?? 0)
                downloadProgressView.setProgress(fraction, animated: true)
                fileSizeLabel.textColor = .systemCyan
                actionIconImageView.image = theme.fileAttachmentActionIcon(for: .uploaded)
                actionIconImageView.accessibilityLabel = L10n.Message.Actions.Download.inProgress

                switch progress.phase {
                case .queued, .downloading:
                    let logicalBytes = Int64(
                        Double(content.payload.file.size) * Double(max(0, min(1, fraction)))
                    )
                    let downloadedSize = AttachmentFile.sizeFormatter.string(fromByteCount: logicalBytes)
                    fileSizeLabel.text = "\(downloadedSize)/\(content.payload.file.sizeString)"
                    downloadProgressView.accessibilityValue = "\(Int(fraction * 100))%"
                case .verifying:
                    downloadProgressView.setProgress(1, animated: true)
                    fileSizeLabel.text = L10n.Message.Actions.Download.verifying
                case .waitingForUnlock:
                    downloadProgressView.setProgress(1, animated: true)
                    fileSizeLabel.text = L10n.Message.Actions.Download.waitingForUnlock
                case .decrypting:
                    downloadProgressView.setProgress(1, animated: true)
                    fileSizeLabel.text = L10n.Message.Actions.Download.decrypting
                }

            case .choosingDestination:
                downloadProgressView.isHidden = false
                downloadProgressView.setProgress(1, animated: true)
                fileSizeLabel.text = L10n.Message.Actions.Download.choosingDestination
                fileSizeLabel.textColor = .systemCyan
                actionIconImageView.image = theme.fileAttachmentActionIcon(for: .uploaded)
                actionIconImageView.accessibilityLabel = L10n.Message.Actions.Download.choosingDestination

            case .saved:
                downloadProgressView.isHidden = true
                fileSizeLabel.text = "\(L10n.Message.Actions.Download.saved) • \(L10n.Message.Actions.Download.showInFiles)"
                fileSizeLabel.textColor = .systemGreen
                actionIconImageView.image = UIImage(systemName: "folder")?.withRenderingMode(.alwaysTemplate)
                actionIconImageView.tintColor = .systemGreen
                actionIconImageView.accessibilityLabel = L10n.Message.Actions.Download.showInFiles

            case .failed:
                downloadProgressView.isHidden = true
                downloadProgressView.progress = 0
                fileSizeLabel.text = L10n.Message.Actions.Download.failureTitle
                fileSizeLabel.textColor = theme.colors.error
                actionIconImageView.image = theme.fileAttachmentActionIcon(for: .uploaded)
                actionIconImageView.accessibilityLabel = L10n.Message.Actions.download
            }
        }
    }
}
