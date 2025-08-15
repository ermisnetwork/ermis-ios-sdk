//
// Copyright 2025 Ermis Inc.
//

import Foundation
import UIKit
import ErmisChat

public protocol ChannelAcceptInvitationViewDelegate: AnyObject {
    func channelAcceptInvitationViewDidAccept(_ view: ChannelAcceptInvitationView)
    func channelAcceptInvitationViewDidReject(_ view: ChannelAcceptInvitationView)
    func channelAcceptInvitationViewDidSkip(_ view: ChannelAcceptInvitationView)
}

open class ChannelAcceptInvitationView: _View, UIProvider {

    /// A view that acts as the main container for the subviews
    open private(set) lazy var containerView = UIView()
        .withoutAutoresizingMaskConstraints

    /// The `ChannelAvatarView` used to show channels avatar.
    open private(set) lazy var avatarView: ChannelAvatarView = components
        .channelAvatarView
        .init(avatarStyle: .circular)
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "avatarView")

    /// The `UILabel` instance showing the channel name.
    open private(set) lazy var titleLabel: UILabel = UILabel()
        .withoutAutoresizingMaskConstraints
        .withAdjustingFontForContentSizeCategory
        .centerTextAlignment
        .withAccessibilityIdentifier(identifier: "titleLabel")

    /// The `UILabel` instance showing the accept require message.
    open private(set) lazy var messageLabel: UILabel = UILabel()
        .withoutAutoresizingMaskConstraints
        .withAdjustingFontForContentSizeCategory
        .withBidirectionalLanguagesSupport
        .withAccessibilityIdentifier(identifier: "titleLabel")
        .multiline

    /// A view that acts as the buttons container for the subviews
    open private(set) lazy var buttonsContainerView: ContainerStackView = ContainerStackView(axis: .horizontal)
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "containerView")

    /// The `UIButton` accept button
    open private(set) lazy var acceptButton: UIButton = {
        let button = UIButton()
        button.setTitle("Accept", for: .normal)
        return button.withoutAutoresizingMaskConstraints
    }()

    /// The `UIButton` reject button
    open private(set) lazy var rejectButton: UIButton = {
        let button = UIButton()
        button.setTitle("Reject", for: .normal)
        return button.withoutAutoresizingMaskConstraints
    }()

    /// The data this view component shows.
    open var content: (channel: Channel?, currentUserId: UserId?) {
        didSet { updateContentIfNeeded() }
    }

    /// Text of `titleLabel` which contains the channel name.
    open var titleText: String? {
        guard let channel = content.channel else {
            return nil
        }
        return channelTitleText(for: channel)
    }

    /// Text of `messageLabel`
    open var messageText: String? {
        guard let channel = content.channel else {
            return nil
        }
        return channel.isDirectMessageChannel ? 
        L10n.Channel.Invitation.directAccceptRequireMessage :
        L10n.Channel.Invitation.accceptRequireMessage
    }

    var isLoading: Bool = false

    public weak var delegate: ChannelAcceptInvitationViewDelegate?

    open override func setUp() {
        super.setUp()
        acceptButton.addTarget(self,
                               action: #selector(onAcceptButtonDidSelected),
                               for: .touchUpInside)
        rejectButton.addTarget(self,
                               action: #selector(onRejectButtonDidSelected),
                               for: .touchUpInside)
    }

    open override func setUpUI() {
        super.setUpUI()
        
        buttonsContainerView.addArrangedSubviews([rejectButton, acceptButton])

        self.addSubview(containerView)
        containerView.pin(anchors: [.centerX, .centerY], to: self)
        containerView.pin(anchors: [.width], to: 300)
        containerView.layer.cornerRadius = 10

        [avatarView, titleLabel, messageLabel, buttonsContainerView].forEach({
            containerView.addSubview($0)
        })

        let padding: CGFloat =  10
        avatarView.pin(anchors: [.width, .height], to: 60)
        avatarView.pin(anchors: [.centerX], to: containerView)
        messageLabel.pin(anchors: [.leading, .trailing], to: titleLabel)
        NSLayoutConstraint.activate([
            avatarView.makeConstraint(attribute: .top,
                                      toItem: containerView,
                                      attribute: .top,
                                      constant: padding),
            titleLabel.makeConstraint(attribute: .top,
                                      toItem: avatarView,
                                      attribute: .bottom,
                                      constant: padding),
            titleLabel.makeConstraint(attribute: .centerX,
                                      toItem: containerView,
                                      attribute: .centerX),

            titleLabel.leadingAnchor.pin(greaterThanOrEqualTo: containerView.leadingAnchor,
                                         constant: padding),
            messageLabel.topAnchor.pin(equalTo: titleLabel.bottomAnchor,
                                       constant: padding),

            buttonsContainerView.makeConstraint(attribute: .top,
                                                toItem: messageLabel,
                                                attribute: .bottom,
                                                constant: padding * 3),
            buttonsContainerView.makeConstraint(attribute: .bottom,
                                                toItem: containerView,
                                                attribute: .bottom,
                                                constant: -padding),
            buttonsContainerView.leadingAnchor.pin(equalTo: containerView.leadingAnchor,
                                                   constant: padding),
            acceptButton.widthAnchor.pin(equalTo: rejectButton.widthAnchor)
        ])

        buttonsContainerView.pin(anchors: [.height], to: 40)
        buttonsContainerView.pin(anchors: [.centerX], to: containerView)


        [rejectButton, acceptButton].forEach({ button in

            if #available(iOS 15.0, *) {
                var configuration = button.configuration ?? UIButton.Configuration.bordered()
                configuration.contentInsets = .zero
                configuration.cornerStyle = .capsule
                configuration.imagePadding = 0
                button.configuration = configuration
            } else {
                button.imageEdgeInsets = .zero
                button.layer.cornerRadius = 20
            }
            
            button.pin(anchors: [.height], to: 40)
        })

    }

    open override func setUpTheme() {
        super.setUpTheme()

        backgroundColor = theme.colors.surface
        containerView.backgroundColor  = theme.colors.surfaceContainer
        containerView.layer.borderColor = theme.colors.outline.cgColor

        titleLabel.font = theme.fonts.body.bold
        titleLabel.textColor = theme.colors.text

        rejectButton.tintColor = theme.colors.onSurfaceHigh
        rejectButton.layer.borderColor = rejectButton.tintColor.cgColor

        acceptButton.tintColor = theme.colors.onSuccess
        acceptButton.layer.borderColor = acceptButton.tintColor.cgColor

        if #available(iOS 15.0, *) {
            acceptButton.configuration?.background.backgroundColor = theme.colors.success
            rejectButton.configuration?.background.backgroundColor = theme.colors.surfaceContainerHighest
        } else {
            acceptButton.backgroundColor = theme.colors.success
            rejectButton.backgroundColor = theme.colors.surfaceContainerHighest

        }
    }

    open override func contentDidChanged() {
        titleLabel.text = titleText
        messageLabel.text = messageText
        avatarView.content = .init(from: content.channel)
        rejectButton.setTitle(content.channel?.isDirectMessageChannel == true ? "Skip" : "Decline" , for: .normal)
    }

    /// The default channel title text.
    open func channelTitleText(for channel: Channel) -> String? {
        formatters
            .channelName
            .format(channel: channel, forCurrentUserId: channel.membership?.id)
    }

    // MARK: - Action
    @objc func onAcceptButtonDidSelected() {
        guard !isLoading else {
            return
        }
        delegate?.channelAcceptInvitationViewDidAccept(self)
    }

    @objc func onRejectButtonDidSelected() {
        guard !isLoading, let channel = content.channel else {
            return
        }
        if channel.isDirectMessageChannel {
            delegate?.channelAcceptInvitationViewDidSkip(self)
        } else {
            delegate?.channelAcceptInvitationViewDidReject(self)
        }
    }
}
