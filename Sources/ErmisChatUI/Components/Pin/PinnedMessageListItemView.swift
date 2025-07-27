//
// Copyright 2025 Ermis Inc.
//

import UIKit
import ErmisChat

public protocol PinnedMessageListItemViewDelegate: AnyObject {
    func pinnedMessageListItemViewDidSelectUnpin(_ view: PinnedMessageListItemView)
    func pinnedMessageListItemViewDidSelectShowInChat(_ view: PinnedMessageListItemView)
}

open class PinnedMessageListItemView: _View, UIProvider, PreviewMessageProvider {
    public private(set) lazy var leadingStackView = createLeadingStack()
    public private(set) lazy var centerStackView = createCenterStackView()
    public private(set) lazy var trailingStackView = createTrailingStackView()

    /// The button to unpin message.
    public private(set) lazy var unpinButton = createUnpinButton()

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

    public private(set) lazy var showInChatButton = createShowInChatButton()

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
        leadingStackView.addArrangedSubview(unpinButton)
        unpinButton.pin(anchors: [.width, .height], to: 32)

        centerStackView.addArrangedSubviews([textView, authorNameLabel])
        centerStackView.topAnchor.pin(greaterThanOrEqualTo: self.topAnchor, constant: 16).isActive = true
        centerStackView.pin(anchors: [.centerY], to: self)
        centerStackView.leadingAnchor.pin(equalTo: leadingStackView.trailingAnchor, constant: 8).isActive = true

        trailingStackView.addArrangedSubviews([imageView, gifImageView, videoPreview, showInChatButton])
        trailingStackView.topAnchor.pin(greaterThanOrEqualTo: self.topAnchor, constant: 8).isActive = true
        trailingStackView.leadingAnchor.pin(equalTo: centerStackView.trailingAnchor, constant: 10).isActive = true
        trailingStackView.pin(anchors: [.trailing], to: self, contant: -16)
        trailingStackView.pin(anchors: [.top, .centerY], to: self)

        imageView.pin(anchors: [.width, .height], to: 40)
        gifImageView.pin(anchors: [.width, .height], to: 40)
        videoPreview.pin(anchors: [.width, .height], to: 40)
    }

    open override func setUpTheme() {
        backgroundColor = theme.colors.surface
        textView.textColor = theme.colors.text
        textView.font = theme.fonts.callout.bold

        unpinButton.tintColor = theme.colors.text
        unpinButton.configuration?.image = theme.icons.messageActionUnpin
        unpinButton.configuration?.background.cornerRadius = 10
        unpinButton.configuration?.background.backgroundColor = theme.colors.surfaceContainerLowest

        showInChatButton.tintColor = theme.colors.text
        showInChatButton.configuration?.image = theme.icons.messageActionShowInChat
        updateAuthorLabel()
    }

    open override func contentDidChanged() {
        // Avatar
        textView.text = generatePreviewMessage()
        updateAuthorLabel()

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

    open func updateAuthorLabel() {
        if let senderName = content?.message.author.displayName {
            let attributedString = NSMutableAttributedString(
                attributedString: NSAttributedString(string: "\(L10n.from) \(senderName)",attributes: [
                    .font: theme.fonts.footnote.bold,
                    .foregroundColor: theme.colors.subtitleText
                ]
            ))
            attributedString.addAttribute(.font,
                                          value: theme.fonts.footnote,
                                          range: NSRange(location: 0, length: L10n.from.count))
            authorNameLabel.attributedText = attributedString
        } else {
            authorNameLabel.attributedText = nil
        }
    }

    @objc
    private func onUnpinButtonSelected() {
        delegate?.pinnedMessageListItemViewDidSelectUnpin(self)
    }

    @objc
    private func onShowInChatButtonSelected() {
        delegate?.pinnedMessageListItemViewDidSelectShowInChat(self)
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
        return authorNameLabel
    }

    open func createUnpinButton() -> UIButton {
        let button = UIButton()
        button.configuration = .plain()
        button.addTarget(self, action: #selector(onUnpinButtonSelected), for: .touchUpInside)
        return button
    }

    open func createShowInChatButton() -> UIButton {
        let button = UIButton()
        button.configuration = .plain()
        button.addTarget(self, action: #selector(onShowInChatButtonSelected), for: .touchUpInside)
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
