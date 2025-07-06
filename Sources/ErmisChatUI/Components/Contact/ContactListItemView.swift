//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// The channel item view that displays information in a channel list cell.
open class ContactListItemView: _View, UIProvider, SwiftUIRepresentable {
    /// The content of this view.
    public struct Content {
        /// Channel for the current Item.
        public let channel: Channel
        /// Current user ID needed to filter out when showing typing indicator.
        public let currentUserId: UserId?

        public init(
            channel: Channel,
            currentUserId: UserId?
        ) {
            self.channel = channel
            self.currentUserId = currentUserId
        }
    }

    /// The data this view component shows.
    public var content: Content? {
        didSet { updateContentIfNeeded() }
    }

    /// A formatter that converts the message timestamp to textual representation.
    public lazy var timestampFormatter: MessageTimestampFormatter = formatters.channelListMessageTimestamp

    /// Main container which holds `avatarView` and two horizontal containers `title` and
    /// `subtitle`
    open private(set) lazy var mainContainer: ContainerStackView = ContainerStackView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "mainContainer")

    /// This container embeded by `mainContainer` containing `topContainer` and `bottomContainer`.
    open private(set) lazy var rightContainer: ContainerStackView = ContainerStackView(
        axis: .vertical,
        spacing: 4
    )
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "rightContainer")

    /// By default contains `title`.
    /// This container is embed inside `mainContainer ` and is the one above `bottomContainer`
    open private(set) lazy var topContainer: ContainerStackView = ContainerStackView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "topContainer")

    /// By default contains `subtitle`.
    /// This container is embed inside `mainContainer ` and is the one below `topContainer`
    open private(set) lazy var bottomContainer: ContainerStackView = ContainerStackView(alignment: .center, spacing: 4)
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "bottomContainer")

    /// The `UILabel` instance showing the channel name.
    open private(set) lazy var titleLabel: UILabel = UILabel()
        .withoutAutoresizingMaskConstraints
        .withAdjustingFontForContentSizeCategory
        .withBidirectionalLanguagesSupport
        .withAccessibilityIdentifier(identifier: "titleLabel")

    open private(set) lazy var subtitleContainer: UIStackView = UIStackView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "topContainer")

    /// The `UILabel` instance showing the last message or typing users if any.
    open private(set) lazy var subtitleLabel: UILabel = UILabel()
        .withoutAutoresizingMaskConstraints
        .withAdjustingFontForContentSizeCategory
        .withBidirectionalLanguagesSupport
        .withAccessibilityIdentifier(identifier: "subtitleLabel")

    /// The view used to show channels avatar.
    open private(set) lazy var avatarView: ChannelAvatarView = components
        .channelAvatarView
        .init(avatarStyle: .cornerRadius(15))
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "avatarView")
    /// The view in tralling to show chevron.right icon
    open private(set) lazy var trailingImageView: UIImageView = {
        let imageView = UIImageView()
            .withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "trailingImageView")
        imageView.contentMode = .center
        imageView.image = theme.icons.chevronRight
        return imageView
    }()

    /// Text of `titleLabel` which contains the channel name.
    open var titleText: String? {
        if let channel = content?.channel {
            return channelTitleText(for: channel)
        }

        return nil
    }

    /// Text of `subtitleLabel` which contains current typing user or the last message in the channel.
    open var subtitleText: String? {
        guard let content = content, let directMember = content.channel.directUserMembership else { return nil }
        if directMember.isOnline {
            return "Online"
        } else if let lastActive = directMember.lastActiveAt {
            return "Offline"//return "Last active: " + timestampFormatter.format(lastActive)
        } else {
            return "Offline"
        }
    }

    /// The item's view background color.
    open var contentBackgroundColor: UIColor {
        theme.colors.channelListItemBackground
    }

    /// The item's view background color when highlighted.
    open var contentHighlightedBackgroundColor: UIColor {
        theme.colors.surfaceContainerHigh
    }

    override open func setUpUI() {
        super.setUpUI()

        topContainer.addArrangedSubviews([
            titleLabel.flexible(axis: .horizontal)
        ])

        subtitleContainer.axis = .horizontal
        subtitleContainer.spacing = 4
        subtitleContainer.alignment = .center
        subtitleContainer.addArrangedSubview(subtitleLabel)
        subtitleContainer.addArrangedSubview(UIView().flexible(axis: .horizontal))

        bottomContainer.addArrangedSubviews([
            subtitleContainer
        ])

        rightContainer.addArrangedSubviews([
            topContainer, bottomContainer
        ])

        let avatarView: UIView

        avatarView = self.avatarView

        NSLayoutConstraint.activate([
            avatarView.heightAnchor.pin(equalToConstant: 44),
            avatarView.widthAnchor.pin(equalTo: avatarView.heightAnchor)
        ])

        NSLayoutConstraint.activate([
            trailingImageView.heightAnchor.pin(equalToConstant: 20),
            trailingImageView.widthAnchor.pin(equalTo: trailingImageView.heightAnchor)
        ])

        mainContainer.addArrangedSubviews([
            avatarView,
            rightContainer,
            trailingImageView
        ])

        mainContainer.alignment = .center
        mainContainer.isLayoutMarginsRelativeArrangement = true

        embed(mainContainer)
    }

    override open func setUpTheme() {
        super.setUpTheme()
        backgroundColor = contentBackgroundColor

        titleLabel.font = theme.fonts.body.bold

        subtitleLabel.textColor = theme.colors.subtitleText
        subtitleLabel.font = theme.fonts.body
    }

    override open func contentDidChanged() {
        titleLabel.text = titleText
        subtitleLabel.text = subtitleText

        avatarView.content = .init(from: content?.channel)
    }

    // MARK: - Channel title rendering

    /// The default channel title text.
    open func channelTitleText(for channel: Channel) -> String? {
        formatters
            .channelName
            .format(channel: channel, forCurrentUserId: channel.membership?.userId)
    }
}
