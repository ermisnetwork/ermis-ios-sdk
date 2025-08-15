//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

public protocol PinnedMessageViewDelegate: AnyObject {
    func pinnedMessageViewDidSelected(_ pinnedMessageView: PinnedMessageView)
    func pinnedMessageViewDidSelectedShowInChatButton(_ pinnedMessageView: PinnedMessageView)
    func pinnedMessageViewDidSelectedUnpinButton(_ pinnedMessageView: PinnedMessageView)
    func pinnedMessageViewDidSelectedExpandButton(_ pinnedMessageView: PinnedMessageView)
}

open class PinnedMessageView: _View, UIProvider, PreviewMessageProvider {
    public private(set) lazy var leadingStackView = createLeadingStack()
    public private(set) lazy var centerStackView = createCenterStackView()
    public private(set) lazy var trailingStackView = createTrailingStackView()
    /// The button to unpin message.
    public private(set) lazy var unpinButton = createUnpinButton()
    public private(set) lazy var titleLabel = createTitleLabel()
    public private(set) lazy var subtitleLabel = createSubtitleLabel()
    public private(set) lazy var showInChatButton = createShowInChatButton()
    public private(set) lazy var expandButton = createExpandButton()

    public weak var delegate: PinnedMessageViewDelegate?

    public var content: Content? {
        didSet {
            updateContentIfNeeded()
        }
    }

    // MARK: - Setup
    open override func setUp() {
        super.setUp()
        layer.cornerRadius = 16
        titleLabel.setContentCompressionResistancePriority(.lowest, for: .horizontal)
        subtitleLabel.setContentCompressionResistancePriority(.lowest, for: .horizontal)
        expandButton.setContentHuggingPriority(.required, for: .vertical)
        expandButton.setContentHuggingPriority(.ermisRequire, for: .horizontal)
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
        leadingStackView.isLayoutMarginsRelativeArrangement = true
        leadingStackView.layoutMargins = .init(top: 0, left: 14, bottom: 0, right: 0)
        leadingStackView.addArrangedSubview(unpinButton)
        unpinButton.pin(anchors: [.width, .height], to: 32)

        centerStackView.addArrangedSubviews([titleLabel, subtitleLabel])

        centerStackView.topAnchor.pin(greaterThanOrEqualTo: self.topAnchor, constant: 16).isActive = true
        centerStackView.pin(anchors: [.centerY], to: self)
        centerStackView.leadingAnchor.pin(equalTo: leadingStackView.trailingAnchor, constant: 8).isActive = true

        trailingStackView.topAnchor.pin(greaterThanOrEqualTo: self.topAnchor, constant: 0).isActive = true
        trailingStackView.leadingAnchor.pin(equalTo: centerStackView.trailingAnchor, constant: 10).isActive = true
        trailingStackView.pin(anchors: [.trailing], to: self, contant: -16)
        trailingStackView.pin(anchors: [.top, .centerY], to: self)

        trailingStackView.addArrangedSubviews([showInChatButton, expandButton])
        showInChatButton.pin(anchors: [.width, .height], to: 24)
    }

    open override func setUpTheme() {
        super.setUpTheme()
        self.backgroundColor = theme.colors.surfaceContainerLow.withAlphaComponent(0.96)
        layer.borderColor = theme.colors.outline.cgColor
        titleLabel.textColor = theme.colors.text
        titleLabel.font = theme.fonts.callout.bold
        updateSubTitleLabel()

        unpinButton.tintColor = theme.colors.text
        unpinButton.configuration?.image = theme.icons.messageActionUnpin
        unpinButton.configuration?.background.cornerRadius = 10
        unpinButton.configuration?.background.backgroundColor = theme.colors.surfaceContainerLowest

        showInChatButton.tintColor = theme.colors.text
        showInChatButton.configuration?.image = theme.icons.messageActionShowInChat

        expandButton.configuration?.titleTextAttributesTransformer = .init(
            { [weak self] incoming in
                var outgoing = incoming
                outgoing.font = self?.theme.fonts.callout
                outgoing.foregroundColor = self?.theme.colors.text
                return outgoing
            }
        )

        expandButton.configuration?.imageColorTransformer = UIConfigurationColorTransformer { [unowned self] _ in
            return self.theme.colors.text
        }

        expandButton.configuration?.background.strokeColor = theme.colors.text
    }

    open override func contentDidChanged() {
        super.contentDidChanged()
        titleLabel.text = generatePreviewMessage()
        let pinnedMessages = content?.channel.pinnedMessages ?? []
        self.isHidden = pinnedMessages.isEmpty
        updateSubTitleLabel()
        expandButton.configuration?.title = "+\(pinnedMessages.count - 1)"
        expandButton.isHidden = pinnedMessages.count <= 1
        showInChatButton.isHidden = pinnedMessages.count > 1
     }
    // MARK: - Action
    @objc private func onBackgroundTapped() {
        delegate?.pinnedMessageViewDidSelected(self)
    }

    @objc
    private func onUnpinButtonSelected() {
        delegate?.pinnedMessageViewDidSelectedUnpinButton(self)
    }

    @objc
    private func onShowInChatButtonSelected() {
        delegate?.pinnedMessageViewDidSelectedShowInChatButton(self)
    }

    @objc
    private func onExpandButtonSelected() {
        delegate?.pinnedMessageViewDidSelectedExpandButton(self)
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

    open func updateSubTitleLabel() {
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
            subtitleLabel.attributedText = attributedString
        } else {
            subtitleLabel.attributedText = nil
        }
    }

    // MARK: - Create UI
    open func createLeadingStack() -> ContainerStackView {
        let containerStackView = ContainerStackView()
        containerStackView.axis = .horizontal
        containerStackView.spacing = 8
        return containerStackView.withoutAutoresizingMaskConstraints
    }

    open func createCenterStackView() -> ContainerStackView {
        let containerStackView = ContainerStackView()
        containerStackView.axis = .vertical
        containerStackView.spacing = 8
        return containerStackView.withoutAutoresizingMaskConstraints
    }

    open func createTrailingStackView() -> ContainerStackView {
        let containerStackView = ContainerStackView()
        containerStackView.axis = .horizontal
        containerStackView.spacing = 8
        return containerStackView.withoutAutoresizingMaskConstraints
    }

    open func createUnpinButton() -> UIButton {
        let button = UIButton()
        button.configuration = .plain()
        button.addTarget(self, action: #selector(onUnpinButtonSelected), for: .touchUpInside)
        return button
    }


    open func createTitleLabel() -> UILabel {
        let label = UILabel()
        label.text = L10n.Pin.Collapsed.title
        return label.withoutAutoresizingMaskConstraints
    }

    open func createSubtitleLabel() -> UILabel {
        let label = UILabel()
        return label.withoutAutoresizingMaskConstraints
    }

    open func createShowInChatButton() -> UIButton {
        let button = UIButton()
        button.configuration = .plain()
        button.addTarget(self, action: #selector(onShowInChatButtonSelected), for: .touchUpInside)
        return button
    }

    open func createExpandButton() -> UIButton {
        let button = UIButton(configuration: .bordered())
        button.configuration?.image = theme.icons.scrollDownArrow
        button.configuration?.imagePlacement = .trailing
        button.configuration?.imagePadding = 4
        button.configuration?.background.cornerRadius = 12
        button.addTarget(self, action: #selector(onExpandButtonSelected), for: .touchUpInside)
        return button.withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "expandButton")
    }
}

public extension PinnedMessageView {
    struct Content {
        public let message: ChatMessage
        public let channel: Channel
        public let pinnedMessageCount: Int
    }
}

extension PinnedMessageView {
    var isLastMessageVoiceRecording: Bool {
        content?.message.voiceRecordingAttachments.isEmpty == false
    }
}
