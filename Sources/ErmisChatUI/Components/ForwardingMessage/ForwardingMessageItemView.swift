//
// Copyright 2025 Ermis Inc.
//

import UIKit
import ErmisChat

public protocol ForwardingMessageItemViewDelegate: AnyObject {
    func forwardingMessageItemViewDidTapSendButton(_ view: ForwardingMessageItemView, cid: ChannelId?)
}

open class ForwardingMessageItemView: _View, UIProvider {

    /// The view used to show channels avatar.
    open private(set) lazy var avatarView: ChannelAvatarView = components
        .channelAvatarView
        .init(avatarStyle: .circular)
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "avatarView")

    /// The `UILabel` instance showing the channel name.
    open private(set) lazy var titleLabel: UILabel = UILabel()
        .withoutAutoresizingMaskConstraints
        .withAdjustingFontForContentSizeCategory
        .withBidirectionalLanguagesSupport
        .withAccessibilityIdentifier(identifier: "titleLabel")

    open private(set) lazy var sendButton = createSendButton()

    public var content: ForwardingMessageCell.Content? {
        didSet {
            updateContentIfNeeded()
        }
    }

    public weak var delegate: ForwardingMessageItemViewDelegate?

    // MARK: - Setup
    open override func setUp() {

    }

    open override func setUpUI() {
        addSubviews([avatarView, titleLabel, sendButton])

        avatarView.topAnchor.pin(greaterThanOrEqualTo: self.topAnchor, constant: 8).isActive = true
        avatarView.pin(anchors: [.leading], to: self, contant: 16)
        avatarView.pin(anchors: [.centerY], to: self)
        avatarView.pin(anchors: [.width, .height], to: 40)

        titleLabel.topAnchor.pin(greaterThanOrEqualTo: self.topAnchor, constant: 8).isActive = true
        titleLabel.leadingAnchor.pin(equalTo: avatarView.trailingAnchor, constant: 8).isActive = true
        titleLabel.pin(anchors: [.centerY], to: self)

        sendButton.leadingAnchor.pin(equalTo: titleLabel.trailingAnchor, constant: 8).isActive = true
        sendButton.pin(anchors: [.centerY], to: self)
        sendButton.pin(anchors: [.trailing], to: self, contant: -16)
        sendButton.pin(anchors: [.height], to: 30)
    }

    open override func setUpTheme() {
        backgroundColor = theme.colors.surface
        titleLabel.font = theme.fonts.body
        titleLabel.textColor = theme.colors.text

        sendButton.configuration?.background.backgroundColorTransformer = UIConfigurationColorTransformer({ [weak sendButton, weak self] incoming in
            guard let self, let sendButton else { return incoming }
            switch sendButton.state {
            case .normal:
                return theme.colors.surfaceContainer
            case .highlighted:
                return theme.colors.surfaceContainerHigh
            case .disabled:
                return theme.colors.surfaceContainer.withAlphaComponent(0.5)
            default:
                return theme.colors.surfaceContainer
            }
        })

        sendButton.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { [weak sendButton, weak self] incoming in
            guard let self, let sendButton else { return incoming }
            var outgoing = incoming
            switch sendButton.state {
            case .normal:
                outgoing.foregroundColor = theme.colors.text
            case .highlighted:
                outgoing.foregroundColor = theme.colors.text
            case .disabled:
                outgoing.foregroundColor = theme.colors.subtitleText
            default:
                outgoing.foregroundColor = theme.colors.text
            }
            outgoing.font = self.theme.fonts.body.bold
            return outgoing
        }
    }

    open override func contentDidChanged() {
        avatarView.content = .init(from: content?.channel)
        titleLabel.text = channelTitleText(for: content?.channel)
        updateSendButton(with: content?.forwardingState)
    }

    /// The default channel title text.
    open func channelTitleText(for channel: Channel?) -> String? {
        guard let channel else {
            return nil
        }
        return formatters
            .channelName
            .format(channel: channel, forCurrentUserId: channel.membership?.userId)
    }

    open func updateSendButton(with forwardingState: ForwardingMessageViewController.ForwardingState?) {
        switch forwardingState {
        case .idle:
            sendButton.isEnabled = true
            sendButton.configuration?.title = L10n.Forward.State.none
        case .forwarding:
            sendButton.isEnabled = false
            sendButton.configuration?.title = L10n.Forward.State.forwarding
        case .forwarded:
            sendButton.isEnabled = false
            sendButton.configuration?.title = L10n.Forward.State.forwarded
        case .error:
            sendButton.isEnabled = true
            sendButton.configuration?.title = L10n.Forward.State.error
        default:
            sendButton.isEnabled = false
            sendButton.configuration?.title = L10n.Forward.State.none
        }
    }

    open func createSendButton() -> UIButton {
        let button = UIButton()
        button.configuration = .filled()
        button.configuration?.cornerStyle = .capsule
        button.configuration?.title = L10n.Forward.State.none
        button.addTarget(self, action: #selector(onSendButtonTapped), for: .touchUpInside)
        return button
            .withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "sendButton")
    }

    @objc private func onSendButtonTapped() {
        sendButton.isEnabled = false
        delegate?.forwardingMessageItemViewDidTapSendButton(self, cid: content?.channel.cid)
    }
}
