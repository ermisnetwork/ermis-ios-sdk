//
// Copyright 2025 Ermis Inc.
//

import UIKit
import ErmisChat

public protocol PinnedMessageListItemViewDelegate: AnyObject {
    func pinnedMessageListItemViewDidSelectUnpin(_ view: PinnedMessageListItemView)
}

open class PinnedMessageListItemView: _View, UIProvider, PreviewMessageProvider {
    public private(set) lazy var leadingStackView = createLeadingStack()
    public private(set) lazy var centerStackView = createCenterStackView()
    public private(set) lazy var trailingStackView = createTrailingStackView()

    /// Shows message author avatar.
    public private(set) lazy var authorAvatarView: AvatarView = components
        .avatarView
        .init(style: .circular)
        .withoutAutoresizingMaskConstraints

    /// Shows message text content.
    public private(set) lazy var textView = createTextView()

    /// Shows message author name.
    public private(set) lazy var authorNameLabel = createAuthorNameLabel()

    /// Shows attachment preview content.
    public private(set) lazy var imageView = components
        .imageAttachmentGalleryPreview
        .init()
        .withoutAutoresizingMaskConstraints

    public private(set) lazy var gifImageView = components
        .gifImageAttachmentGalleryPreview
        .init()
        .withoutAutoresizingMaskConstraints

    public private(set) lazy var videoPreview = components
        .videoAttachmentGalleryPreview
        .init()
        .withoutAutoresizingMaskConstraints

    public private(set) lazy var unpinButton = createUnpinButton()

    /// Specifies the size of `authorAvatarView`. In case `.avatarSizePadding` option is set the leading offset
    /// for the content will taken from the provided `width`.
    open var authorAvatarSize: CGSize { .init(width: 32, height: 32) }

    public weak var delegate: PinnedMessageListItemViewDelegate?

    public var content: Content? {
        didSet {
            updateContentIfNeeded()
        }
    }

    // MARK: - Setup
    open override func setUp() {
        
    }

    open override func setUpUI() {
        addSubviews([
            leadingStackView,
            centerStackView,
            trailingStackView
        ])

        leadingStackView.topAnchor.pin(greaterThanOrEqualTo: self.topAnchor, constant: 0).isActive = true
        leadingStackView.pin(anchors: [.centerY], to: self)
        leadingStackView.pin(anchors: [.leading], to: self, contant: 16)
        leadingStackView.addArrangedSubview(authorAvatarView)
        authorAvatarView.pin(anchors: [.width, .height], to: 32)

        centerStackView.addArrangedSubviews([textView, authorNameLabel])
        centerStackView.topAnchor.pin(greaterThanOrEqualTo: self.topAnchor, constant: 16).isActive = true
        centerStackView.pin(anchors: [.centerY], to: self)
        centerStackView.leadingAnchor.pin(equalTo: leadingStackView.trailingAnchor, constant: 8).isActive = true

        trailingStackView.addArrangedSubviews([imageView, gifImageView, videoPreview, unpinButton])
        trailingStackView.topAnchor.pin(greaterThanOrEqualTo: self.topAnchor, constant: 8).isActive = true
        trailingStackView.leadingAnchor.pin(equalTo: centerStackView.trailingAnchor, constant: 10).isActive = true
        trailingStackView.pin(anchors: [.trailing], to: self, contant: -16)
        trailingStackView.pin(anchors: [.top, .centerY], to: self)

        imageView.pin(anchors: [.width, .height], to: 40)
        gifImageView.pin(anchors: [.width, .height], to: 40)
        videoPreview.pin(anchors: [.width, .height], to: 40)
        unpinButton.pin(anchors: [.width, .height], to: 30)
    }

    open override func setUpTheme() {
        backgroundColor = theme.colors.surface
        textView.textColor = theme.colors.text
        textView.font = theme.fonts.body.bold

        authorNameLabel.textColor = theme.colors.subtitleText
        authorNameLabel.font = theme.fonts.body

        unpinButton.tintColor = theme.colors.text
        unpinButton.configuration?.image = theme.icons.messageActionUnpin
        unpinButton.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { [weak self] incoming in
            var outgoing = incoming
            outgoing.font = self?.theme.fonts.body.bold
            return outgoing
        }
    }

    open override func contentDidChanged() {
        // Avatar
        authorAvatarView.loadImage(from: content?.message.author.imageURL,
                                   with: ImageLoaderOptions(
                                    resize: .init(components.avatarThumbnailSize),
                                    placeHolderString: content?.message.author.displayName ?? ""
                                   )
        )

        textView.text = generatePreviewMessage()
        authorNameLabel.text = content?.message.author.displayName

        imageView.isHidden = true
        gifImageView.isHidden = true
        videoPreview.isHidden = true

        if let attachments = content?.message.allAttachments.filter({ $0.type == .image || $0.type == .video}),
           attachments.count == 1 {
            let attachment  = attachments.first!

            if attachment.type == .image, let messageImageAttachment = attachment.attachment(payloadType: ImageAttachmentPayload.self) {
                if messageImageAttachment.isGif {
                    gifImageView.content = messageImageAttachment
                    gifImageView.isHidden = false
                } else {
                    imageView.content = messageImageAttachment
                    imageView.isHidden = false
                }
            } else if attachment.type == .image, let messageVideoAttachment = attachment.attachment(payloadType: VideoAttachmentPayload.self) {
                videoPreview.content = messageVideoAttachment
                videoPreview.isHidden = false
            }
        }
    }

    open func generatePreviewMessage() -> String? {
        if let previewMessage = content?.message, let channel = content?.channel {
            if isLastMessageVoiceRecording {
                return previewMessageForAudioRecordingMessage(messageText: previewMessage.textContentAfterParseMention ?? previewMessage.text)
            }

            if previewMessage.type == .system {
                return previewMessageTextForSystemMessage(messageText: previewMessage.textContent ?? previewMessage.text,
                                                          in: channel)
            } else if previewMessage.type == .signal {
                return previewMessageTextForCallMessage(messageText: previewMessage.textContent ?? previewMessage.text,
                                                        in: channel)
            }

            var text = previewMessage.textContentAfterParseMention ?? previewMessage.text

            if let translatedText = translatedPreviewText(for: previewMessage, in: channel, messageText: text) {
                text = translatedText
            }

            if let attachmentText = attachmentPreviewText(for: previewMessage, messageText: text) {
                text = attachmentText
            }

            if previewMessage.isSentByCurrentUser {
                return previewMessageTextForCurrentUser(messageText: text)
            }

            return previewMessageTextFromAnotherUser(previewMessage.author, messageText: text)
        }

        return nil
    }

    @objc
    private func onUnpinButtonSelected() {
        delegate?.pinnedMessageListItemViewDidSelectUnpin(self)
    }
    // MARK: - Create UI
    open func createTextView() -> UITextView {
        let textView = OnlyLinkTappableTextView()
            .withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "textView")
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = .init(top: 0, left: 0, bottom: 0, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.font = theme.fonts.body
        textView.textContainer.maximumNumberOfLines = 2
        return textView
    }

    /// Instantiates, configures and assigns `authorNameLabel` when called for the first time.
    /// - Returns: The `authorNameLabel` subview.
    open func createAuthorNameLabel() -> UILabel {
        authorNameLabel = UILabel()
            .withAdjustingFontForContentSizeCategory
            .withBidirectionalLanguagesSupport
            .withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "authorNameLabel")

        authorNameLabel.textColor = theme.colors.subtitleText
        authorNameLabel.font = theme.fonts.footnote
        return authorNameLabel
    }

    open func createUnpinButton() -> UIButton {
        let button = UIButton()
        button.configuration = .plain()
        button.addTarget(self, action: #selector(onUnpinButtonSelected), for: .touchUpInside)
        return button
    }
}
extension PinnedMessageListItemView {
    var isLastMessageVoiceRecording: Bool {
        content?.message.voiceRecordingAttachments.isEmpty == false
    }
}
// MARK: - Content
public
extension PinnedMessageListItemView {
    struct Content {
        let message: ChatMessage
        let channel: Channel
    }
}
// MARK: - Create UI
extension PinnedMessageListItemView {
    private func createLeadingStack() -> ContainerStackView {
        let containerStackView = ContainerStackView()
        containerStackView.axis = .horizontal
        containerStackView.spacing = 8
        return containerStackView.withoutAutoresizingMaskConstraints
    }

    private func createCenterStackView() -> ContainerStackView {
        let containerStackView = ContainerStackView()
        containerStackView.alignment = .leading
        containerStackView.axis = .vertical
        containerStackView.spacing = 8
        return containerStackView.withoutAutoresizingMaskConstraints
    }

    private func createTrailingStackView() -> ContainerStackView {
        let containerStackView = ContainerStackView()
        containerStackView.axis = .horizontal
        containerStackView.spacing = 8
        return containerStackView.withoutAutoresizingMaskConstraints
    }
}
