//
// Copyright 2025 Ermis Inc.
//

import AVKit
import ErmisChat
import UIKit

/// A view that displays a quoted message.
open class QuotedMessageView: _View, UIProvider, SwiftUIRepresentable, RemoteImageDisplayable {
    /// The content of the view.
    public struct Content {
        /// The quoted message.
        public let message: ChatMessage?
        /// The boolean true if parent message sent by current user.
        public let repliedMessageAuthor: ChatUser?
        /// The channel which the message belongs to.
        public let channel: Channel?

        public var isRepliedMessageSentByCurrentUser: Bool {
            guard let repliedMessageAuthor, let channel else {
                return false
            }
            return repliedMessageAuthor.userId == channel.membership?.userId
        }

        public init(
            message: ChatMessage?,
            repliedMessageAuthor: ChatUser?,
            channel: Channel? = nil
        ) {
            self.message = message
            self.repliedMessageAuthor = repliedMessageAuthor
            self.channel = channel
        }
    }

    /// The content of this view, composed by the quoted message and the desired avatar alignment.
    public var content: Content? {
        didSet {
            updateContentIfNeeded()
        }
    }

    /// A Boolean value that checks if all attachments are empty.
    open var isAttachmentsEmpty: Bool {
        guard let message = self.content?.message else { return true }
        return message.allAttachments.isEmpty
    }

    /// The container view that holds the `authorAvatarView` and the `contentContainerView`.
    open private(set) lazy var containerView: ContainerStackView = ContainerStackView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "containerView")

    /// The label on top to show the reply context
    open private(set) lazy var descriptionLabel: UILabel = .init()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "answerByLabel")

    /// The container view that holds the `quoteMarkView` and the `bubbleContainerView`.
    open private(set) lazy var contentContainerView: ContainerStackView = ContainerStackView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "contentContainerView")

    /// The view to mark this message is replied
    open private(set) lazy var quoteMarkView = UIView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "quoteMarkView")

    /// The container view that holds the `textView` and the `attachmentPreview`.
    open private(set) lazy var bubbleContainerView: ContainerStackView = ContainerStackView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "bubbleContainerView")

    /// The `UITextView` that contains quoted message content.
    open private(set) lazy var textView: UITextView = UITextView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "textView")

    /// The attachments preview view if the quoted message has attachments.
    /// The default logic is that the first attachment is displayed on the preview view.
    open private(set) lazy var attachmentPreviewView: UIImageView = UIImageView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "attachmentPreviewView")

    open private(set) var stickerPreview: StickerPreview?

    open private(set) lazy var voiceRecordingAttachmentQuotedPreview: VoiceRecordingAttachmentQuotedPreview =
        components
            .voiceRecordingAttachmentQuotedPreview
            .init()
            .withoutAutoresizingMaskConstraints

    /// The size of the attachments preview.s
    open var attachmentPreviewSize: CGSize { .init(width: 44, height: 44) }

    /// The component responsible to detect links in the message text.
    public let linkDetector = TextLinkDetector()

    public var imageView: UIImageView {
        return attachmentPreviewView
    }
    // MARK: - Setup
    override open func setUp() {
        super.setUp()
        quoteMarkView.layer.cornerRadius = 1.5
        textView.isEditable = false
        textView.dataDetectorTypes = .link
        textView.isScrollEnabled = false
        textView.adjustsFontForContentSizeCategory = true
        textView.isUserInteractionEnabled = false

        bubbleContainerView.layer.cornerRadius = 12
        bubbleContainerView.layer.masksToBounds = true
    }

    override open func setUpUI() {
        preservesSuperviewLayoutMargins = true
        containerView.isLayoutMarginsRelativeArrangement = true
        containerView.alignment = .leading
        containerView.axis = .vertical
        containerView.spacing = 4

        contentContainerView.isLayoutMarginsRelativeArrangement = true
        contentContainerView.spacing = 8
        contentContainerView.alignment = .center
        contentContainerView.distribution = .natural
        contentContainerView.axis = .horizontal
        contentContainerView.layoutMargins = .zero

        bubbleContainerView.isLayoutMarginsRelativeArrangement = true
        bubbleContainerView.alignment = .top
        bubbleContainerView.layoutMargins = .init(top: 8, left: 16, bottom: 8, right: 16)

        embed(containerView)

        containerView.addArrangedSubviews([
            descriptionLabel,
            contentContainerView
        ])

        contentContainerView.addArrangedSubview(quoteMarkView)
        contentContainerView.addArrangedSubview(bubbleContainerView)

        bubbleContainerView.addArrangedSubview(attachmentPreviewView)
        bubbleContainerView.addArrangedSubview(voiceRecordingAttachmentQuotedPreview)
        bubbleContainerView.addArrangedSubview(textView)

        NSLayoutConstraint.activate([
            quoteMarkView.widthAnchor.pin(equalToConstant: 3),
            quoteMarkView.heightAnchor.pin(equalTo: self.bubbleContainerView.heightAnchor, constant: -12)
        ])

        NSLayoutConstraint.activate([
            attachmentPreviewView.widthAnchor.pin(equalToConstant: attachmentPreviewSize.width),
            attachmentPreviewView.heightAnchor.pin(equalToConstant: attachmentPreviewSize.height)
        ])

        attachmentPreviewView.layer.cornerRadius = attachmentPreviewSize.width / 4
        attachmentPreviewView.layer.masksToBounds = true

        voiceRecordingAttachmentQuotedPreview.isHidden = true
    }

    override open func setUpTheme() {
        super.setUpTheme()

        descriptionLabel.textColor = theme.colors.subtitleText
        descriptionLabel.font = theme.fonts.footnote.semiBold

        quoteMarkView.backgroundColor = theme.colors.primary

        textView.textContainer.maximumNumberOfLines = 6
        textView.textContainer.lineBreakMode = .byTruncatingTail
        textView.textContainer.lineFragmentPadding = .zero
        textView.backgroundColor = .clear
        textView.font = theme.fonts.callout
        textView.textContainerInset = .zero

        bubbleContainerView.backgroundColor = theme.colors.bubbleQuotedMessageBackground
    }

    override open func contentDidChanged() {
        let message = content?.message
        containerView.alignment = content?.isRepliedMessageSentByCurrentUser == true ? .trailing : .leading
        updateDescriptionLabel()
        updateQuoteMarkViewPosition()

        if message?.type == .sticker, message?.isDeleted != true {
            if stickerPreview == nil {
                let stickerPreview = components.stickerPreview.init()
                    .withoutAutoresizingMaskConstraints
                bubbleContainerView.addArrangedSubviews([stickerPreview])
                self.stickerPreview = stickerPreview
            }

            guard let stickerPreview, let stickerUrl = message?.stickerUrl else {
                return
            }
            stickerPreview.content = .init(url: stickerUrl, sticker: nil)
            textView.text = nil
            NSLayoutConstraint.activate([
                stickerPreview.widthAnchor.pin(equalToConstant: attachmentPreviewSize.width),
                stickerPreview.heightAnchor.pin(equalToConstant: attachmentPreviewSize.height)
            ])
            bubbleContainerView.spacing = 0
            return
        } else {
            if let stickerPreview {
                bubbleContainerView.removeArrangedSubview(stickerPreview)
                bubbleContainerView.spacing = .auto
            }
        }

        if message?.isDeleted == true || message == nil {
            setDeletedText()
            hideAttachmentPreview()
        } else if let message = message {
            if !message.text.isEmpty {
                setText(message.text)
            } else if isAttachmentsEmpty {
                hideAttachmentPreview()
            } else {
                setAttachmentPreview(for: message)
                showAttachmentPreview()
            }
        }

        if let currentUserLang = content?.channel?.membership?.language,
           let translatedText = content?.message?.translatedText(for: currentUserLang) {
            textView.text = translatedText
        }
    }
    // MARK: - Action

    /// Update content of description label
    open func updateDescriptionLabel() {
        if content?.message?.author.userId == content?.channel?.membership?.userId {
            descriptionLabel.text = "Have answered you"
        } else if let author = content?.message?.author {
            descriptionLabel.text = "Have answered \(author.displayName)"
        }
        descriptionLabel.isHidden = content?.repliedMessageAuthor == nil
        descriptionLabel.textAlignment = content?.isRepliedMessageSentByCurrentUser == false ? .left : .right
    }

    /// Update quote markview alignment to left or right base on the parent sender.
    open func updateQuoteMarkViewPosition() {
        contentContainerView.removeArrangedSubview(quoteMarkView)
        if content?.isRepliedMessageSentByCurrentUser == true {
            contentContainerView.addArrangedSubview(quoteMarkView)
        } else {
            contentContainerView.insertArrangedSubview(quoteMarkView, at: 0)
        }
        NSLayoutConstraint.activate([
            quoteMarkView.widthAnchor.pin(equalToConstant: 3),
            quoteMarkView.heightAnchor.pin(equalTo: self.bubbleContainerView.heightAnchor, constant: -12)
        ])
    }

    /// Sets the text of the quoted message.
    /// - Parameter text: A string representing the text of the quoted message.
    open func setText(_ text: String) {
        guard text != textView.text else { return }
        let attributedText = NSMutableAttributedString(
            string: text,
            attributes: [
                .foregroundColor: theme.colors.subtitleText,
                .font: theme.fonts.body
            ]
        )

        linkDetector.links(in: text).forEach { textLink in
            attributedText.addAttribute(.link, value: textLink.url, range: textLink.range)
        }

        textView.attributedText = attributedText

        // Mentions
        if let mentionedUsers = content?.message?.mentionedUsers, !mentionedUsers.isEmpty {
            mentionedUsers.forEach {
                textView.highlightMentions($0,
                                           isCurrentUser: $0.userId == content?.channel?.membership?.userId,
                                           isSendByCurrentUser: false)
            }
        }

        if content?.message?.mentionedAll == true {
            textView.highlightMentionAllUsers(isSendByCurrentUser: false)
        }
    }

    open func setDeletedText() {
        let text = L10n.Message.deletedMessagePlaceholder
        let attributedText = NSMutableAttributedString(
            string: text,
            attributes: [
                .foregroundColor: theme.colors.quotedMessageText,
                .font: theme.fonts.body
            ]
        )
        textView.attributedText = attributedText
    }

    /// Sets the attachment content to the preview view.
    /// Override this function if you want to provide custom logic to present
    /// the attachments preview of the message, or if you want to support your custom attachment.
    /// - Parameter message: The message that contains all the attachments.
    open func setAttachmentPreview(for message: ChatMessage) {
        if let filePayload = message.fileAttachments.first?.payload {
            attachmentPreviewView.contentMode = .scaleAspectFit
            attachmentPreviewView.image = theme.icons.fileIcons[filePayload.file.type] ?? theme.icons.fileFallback
            textView.text = message.text.isEmpty ? filePayload.title : message.text
        } else if let imagePayload = message.imageAttachments.first?.payload {
            attachmentPreviewView.contentMode = .scaleAspectFill
            setAttachmentPreviewImage(url: imagePayload.imageURL)
            textView.text = message.text.isEmpty ? L10n.Composer.QuotedMessage.photo : message.text
        } else if let linkPayload = message.linkAttachments.first?.payload {
            attachmentPreviewView.contentMode = .scaleAspectFill
            setAttachmentPreviewImage(url: linkPayload.previewURL)
            textView.text = linkPayload.originalURL.absoluteString
        } else if let videoPayload = message.videoAttachments.first?.payload {
            attachmentPreviewView.contentMode = .scaleAspectFill
            textView.text = message.text.isEmpty ? videoPayload.title : message.text
            if let thumbnailURL = videoPayload.thumbnailURL {
                setVideoAttachmentThumbnail(url: thumbnailURL)
            } else {
                setVideoAttachmentPreviewImage(url: videoPayload.videoURL)
            }
        } else if let voiceRecordingPayload = message.voiceRecordingAttachments.first?.payload {
            voiceRecordingAttachmentQuotedPreview.content = .init(
                title: voiceRecordingPayload.title ?? message.text,
                size: voiceRecordingPayload.file.size,
                duration: voiceRecordingPayload.duration ?? 0,
                audioAssetURL: voiceRecordingPayload.voiceRecordingURL
            )
            textView.text = nil
        } else {
            setUnsupportedAttachmentPreview(for: message)
        }
    }

    /// Sets the image from the given URL into `attachmentPreviewView.image`
    /// - Parameter url: The URL from which the image is to be loaded
    open func setAttachmentPreviewImage(url: URL?) {
        loadImage(from: url, with: ImageLoaderOptions(resize: .init(attachmentPreviewSize)))
    }

    /// Set the image from the given URL into `attachmentPreviewImage.image`
    /// - Parameter url: The URL of the thumbnail
    open func setVideoAttachmentThumbnail(url: URL) {
        loadImage(from: url)
    }

    /// Set the image from the given URL into `attachmentPreviewImage.image`
    /// - Parameter url: The URL from which to generate the image on the video
    open func setVideoAttachmentPreviewImage(url: URL?) {
        guard let url = url else { return }

        components.videoLoader.loadPreviewForVideo(at: url) { [weak self] in
            switch $0 {
            case let .success(preview):
                self?.attachmentPreviewView.image = preview
            case let .failure(error):
                self?.attachmentPreviewView.image = nil
                log.error("This \(error) received for processing Video Preview image.")
            }
        }
    }

    /// Show the attachment preview view.
    open func showAttachmentPreview() {
        let containsVoiceRecording = content?.message?.voiceRecordingAttachments.isEmpty == false
        Animate {
            self.voiceRecordingAttachmentQuotedPreview.isHidden = !containsVoiceRecording
            self.attachmentPreviewView.isHidden = containsVoiceRecording
        }
    }

    /// Hide the attachment preview view.
    open func hideAttachmentPreview() {
        Animate {
            self.attachmentPreviewView.isHidden = true
            self.voiceRecordingAttachmentQuotedPreview.isHidden = true
        }
    }

    /// Sets the unsupported attachment content to the preview view.
    open func setUnsupportedAttachmentPreview(for message: ChatMessage) {
        attachmentPreviewView.contentMode = .scaleAspectFit
        attachmentPreviewView.image = theme.icons.fileFallback
        textView.text = message.text.isEmpty ? L10n.Message.unsupportedAttachment : message.text
    }
}
