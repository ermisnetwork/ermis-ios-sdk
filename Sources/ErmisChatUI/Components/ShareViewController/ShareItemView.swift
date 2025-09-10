//
// Copyright 2025 Ermis Inc.
//

import UIKit
import ErmisChat

@MainActor
public protocol ShareItemViewDelegate: AnyObject {
    func shareItemViewDidTapSendButton(_ view: ShareItemView, cid: ChannelId?)
}

open class ShareItemView: _View, UIProvider {

    /// The view used to show channels avatar.
    open private(set) lazy var avatarView: ChannelAvatarView = components
        .channelAvatarView
        .init(avatarStyle: .cornerRadius(20))
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "avatarView")

    /// The `UILabel` instance showing the channel name.
    open private(set) lazy var titleLabel: UILabel = UILabel()
        .withoutAutoresizingMaskConstraints
        .withAdjustingFontForContentSizeCategory
        .withBidirectionalLanguagesSupport
        .withAccessibilityIdentifier(identifier: "titleLabel")

    open private(set) lazy var sendButton = createSendButton()

    public private(set) var avatarViewLeadingConstraint: NSLayoutConstraint?

    public var content: Channel? {
        didSet {
            updateContentIfNeeded()
        }
    }

    public weak var delegate: ShareItemViewDelegate?

    // MARK: - Setup
    open override func setUp() {
        sendButton.setContentHuggingPriority(.ermisRequire, for: .horizontal)
        sendButton.setContentCompressionResistancePriority(.ermisRequire, for: .horizontal)
    }

    open override func setUpUI() {
        addSubviews([avatarView, titleLabel, sendButton])

        avatarView.topAnchor.pin(equalTo: self.topAnchor, constant: 12).isActive = true
        avatarViewLeadingConstraint = avatarView.leadingAnchor.pin(equalTo: self.leadingAnchor, constant: 24)
        avatarViewLeadingConstraint?.isActive = true
        avatarView.pin(anchors: [.centerY], to: self)
        avatarView.pin(anchors: [.width, .height], to: 60)

        titleLabel.topAnchor.pin(greaterThanOrEqualTo: self.topAnchor, constant: 12).isActive = true
        titleLabel.leadingAnchor.pin(equalTo: avatarView.trailingAnchor, constant: 8).isActive = true
        //        titleLabel.pin(anchors: [.leading], to: self)
        titleLabel.pin(anchors: [.centerY], to: self)

        sendButton.leadingAnchor.pin(equalTo: titleLabel.trailingAnchor, constant: 8).isActive = true
        sendButton.pin(anchors: [.centerY], to: self)
        sendButton.pin(anchors: [.trailing], to: self, contant: -24)
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
        avatarView.content = .init(from: content)
        titleLabel.text = channelTitleText(for: content)
        updateAvatarViewLeadingConstraint()
    }
    // MARK: - Action
    @objc private func onSendButtonTapped() {
        sendButton.isEnabled = false
        delegate?.shareItemViewDidTapSendButton(self, cid: content?.cid)
    }

    private func updateAvatarViewLeadingConstraint() {
        let isTopic = content?.parentCid != nil
        avatarViewLeadingConstraint?.constant = isTopic ? 54: 24
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
    // MARK: - Create UI
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
}

public extension ShareItemView {
    struct Content {
        let channel: Channel
    }
}
