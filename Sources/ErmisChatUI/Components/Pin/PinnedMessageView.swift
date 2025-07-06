//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

public protocol PinnedMessageViewDelegate: AnyObject {
    func pinnedMessageViewDidSelected(_ pinnedMessageView: PinnedMessageView)
    func pinnedMessageViewDidSelectedTrailingButton(_ pinnedMessageView: PinnedMessageView)
    func pinnedMessageViewDidSelectClearButton(_ pinnedMessageView: PinnedMessageView)
}

open class PinnedMessageView: _View, UIProvider, PreviewMessageProvider {
    public private(set) lazy var leadingStackView = createLeadingStack()
    public private(set) lazy var centerStackView = createCenterStackView()
    public private(set) lazy var trailingStackView = createTrailingStackView()
    public private(set) lazy var imageView = createImageView()
    public private(set) lazy var titleLabel = createTitleLabel()
    public private(set) lazy var subtitleLabel = createSubtitleLabel()
    public private(set) lazy var trailingButton = createtrailingButton()

    public var delegate: PinnedMessageViewDelegate?

    public var content: Content? {
        didSet {
            updateContentIfNeeded()
        }
    }

    // MARK: - Setup
    open override func setUp() {
        super.setUp()
        layer.cornerRadius = 16
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        subtitleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        self.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(onBackgroundTapped)))
        isHidden = true
    }

    open override func setUpUI() {
        super.setUpUI()
        addSubviews([
            leadingStackView,
            centerStackView,
            trailingStackView
        ])
        leadingStackView.topAnchor.pin(greaterThanOrEqualTo: self.topAnchor, constant: 0).isActive = true
        leadingStackView.pin(anchors: [.centerY], to: self)
        leadingStackView.pin(anchors: [.leading], to: self, contant: 16)
        leadingStackView.addArrangedSubview(imageView)
        imageView.pin(anchors: [.width, .height], to: 24)
        imageView.pin(anchors: [.leading], to: leadingStackView, contant: 16)

        centerStackView.addArrangedSubviews([titleLabel, subtitleLabel])

        centerStackView.topAnchor.pin(greaterThanOrEqualTo: self.topAnchor, constant: 16).isActive = true
        centerStackView.pin(anchors: [.centerY], to: self)
        centerStackView.leadingAnchor.pin(equalTo: leadingStackView.trailingAnchor, constant: 8).isActive = true

        trailingStackView.topAnchor.pin(greaterThanOrEqualTo: self.topAnchor, constant: 0).isActive = true
        trailingStackView.leadingAnchor.pin(equalTo: centerStackView.trailingAnchor, constant: 10).isActive = true
        trailingStackView.pin(anchors: [.trailing], to: self, contant: -16)
        trailingStackView.pin(anchors: [.top, .centerY], to: self)

        trailingStackView.addArrangedSubview(trailingButton)
        trailingButton.pin(anchors: [.width, .height], to: 20)
    }

    open override func setUpTheme() {
        super.setUpTheme()
        self.backgroundColor = theme.colors.surfaceContainerLow.withAlphaComponent(0.96)
        layer.borderColor = theme.colors.outline.cgColor
        titleLabel.textColor = theme.colors.text
        titleLabel.font = theme.fonts.body.bold

        subtitleLabel.textColor = theme.colors.subtitleText
        subtitleLabel.font = theme.fonts.body
        trailingButton.tintColor = theme.colors.text
    }

    open override func contentDidChanged() {
        super.contentDidChanged()
        subtitleLabel.text = generatePreviewMessage()
        let pinnedMessages = content?.channel.pinnedMessages ?? []
        self.isHidden = pinnedMessages.isEmpty
     }
    // MARK: - Action
    @objc private func onBackgroundTapped() {
        delegate?.pinnedMessageViewDidSelected(self)
    }

    @objc private func onTrailingButtonTapped() {
        if content?.isShowClearButton == true {
            delegate?.pinnedMessageViewDidSelectClearButton(self)
        } else {
            delegate?.pinnedMessageViewDidSelectedTrailingButton(self)
        }
    }
    // MARK: - Helper
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
}

public extension PinnedMessageView {
    struct Content {
        public let message: ChatMessage
        public let channel: Channel
        public let isShowClearButton: Bool
    }
}

extension PinnedMessageView {
    var isLastMessageVoiceRecording: Bool {
        content?.message.voiceRecordingAttachments.isEmpty == false
    }
}

extension PinnedMessageView {
    private func createLeadingStack() -> ContainerStackView {
        let containerStackView = ContainerStackView()
        containerStackView.axis = .horizontal
        containerStackView.spacing = 8
        return containerStackView.withoutAutoresizingMaskConstraints
    }

    private func createCenterStackView() -> ContainerStackView {
        let containerStackView = ContainerStackView()
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

    private func createImageView() -> UIImageView {
        let imageView = UIImageView()
        imageView.image = theme.icons.messageActionPin
        return imageView.withoutAutoresizingMaskConstraints
    }

    private func createTitleLabel() -> UILabel {
        let label = UILabel()
        label.text = L10n.Pin.Collapsed.title
        return label.withoutAutoresizingMaskConstraints
    }

    private func createSubtitleLabel() -> UILabel {
        let label = UILabel()
        return label.withoutAutoresizingMaskConstraints
    }

    private func createtrailingButton() -> UIButton {
        let button = UIButton()
        button.addTarget(self, action: #selector(onTrailingButtonTapped), for: .touchUpInside)
        button.setImage(theme.icons.chevronRight, for: .normal)
        return button.withoutAutoresizingMaskConstraints
    }
}
