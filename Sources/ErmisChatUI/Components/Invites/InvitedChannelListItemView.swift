//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat
import UIKit

public
protocol InvitedChannelListItemViewDelegate: AnyObject {
    func invitedChannelListItemView(_ invitedChannelItem: InvitedChannelListItemView,
                                    didAcceptInviteAt indexPath: IndexPath)
    func invitedChannelListItemView(_ invitedChannelItem: InvitedChannelListItemView,
                                    didRejectInviteAt indexPath: IndexPath)
    func invitedChannelListItemView(_ invitedChannelItem: InvitedChannelListItemView,
                                    didSkipAt indexPath: IndexPath)
}

/// The channel item view that displays information in a channel list cell.
open 
class InvitedChannelListItemView: _View, UIProvider, SwiftUIRepresentable {
    /// The content of this view.
    public struct Content {
        /// Channel for the current Item.
        public let channel: Channel
        /// Current user ID needed to filter out when showing typing indicator.
        public let currentUserId: UserId?
        /// The result of a search query.
        public let searchResult: SearchResult?

        public init(
            channel: Channel,
            currentUserId: UserId?,
            searchResult: SearchResult? = nil
        ) {
            self.channel = channel
            self.currentUserId = currentUserId
            self.searchResult = searchResult
        }

        /// The additional information as part of a search query.
        public struct SearchResult {
            /// The search query input.
            public let text: String
            /// The message that belongs to a message search result.
            public let message: ChatMessage?

            /// Initialize from `text` and `message`
            public init(text: String, message: ChatMessage?) {
                self.text = text
                self.message = message
            }
        }
    }

    public weak var delegate: InvitedChannelListItemViewDelegate?
    public var indexPath: (() -> IndexPath?)?

    /// The data this view component shows.
    public var content: Content? {
        didSet { updateContentIfNeeded() }
    }

    /// A formatter that converts the message timestamp to textual representation.
    public lazy var timestampFormatter: MessageTimestampFormatter = formatters.channelListMessageTimestamp

    /// Main container which holds `avatarView` and two horizontal containers `title` and `unreadCount` and
    /// `subtitle` and `timestampLabel`
    open private(set) lazy var mainContainer: ContainerStackView = ContainerStackView(alignment: .top)
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "mainContainer")

    /// This container embeded by `mainContainer` containing `topContainer` and `bottomContainer`.
    open private(set) lazy var rightContainer: ContainerStackView = ContainerStackView(
        axis: .vertical,
        spacing: 4
    )
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "rightContainer")

    /// By default contains `title` and `unreadCount`.
    /// This container is embed inside `mainContainer ` and is the one above `bottomContainer`
    open private(set) lazy var topContainer: ContainerStackView = ContainerStackView(alignment: .center)
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "topContainer")

    /// By default contains `subtitle` and `timestampLabel`.
    /// This container is embed inside `mainContainer ` and is the one below `topContainer`
    open private(set) lazy var bottomContainer: ContainerStackView = ContainerStackView(alignment: .center, spacing: 4)
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "bottomContainer")

    open private(set) lazy var joinRoomContainer: ContainerStackView = ContainerStackView(
        alignment: .center,
        spacing: 12,
        distribution: .equal
    )
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "joinRoomContainer")

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

    /// The `UILabel` instance showing the time of the last sent message.
    open private(set) lazy var timestampLabel: UILabel = UILabel()
        .withoutAutoresizingMaskConstraints
        .withAdjustingFontForContentSizeCategory
        .withBidirectionalLanguagesSupport
        .withAccessibilityIdentifier(identifier: "timestampLabel")

    /// The view used to show channels avatar.
    open private(set) lazy var avatarView: ChannelAvatarView = components
        .channelAvatarView
        .init(avatarStyle: .cornerRadius(20))
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "avatarView")

    open
    private(set) lazy var acceptButton: UIButton = {
        let button = UIButton()
        button.setTitle("Accept", for: .normal)
        button.pin(anchors: [.height], to: 44)
        button.layer.cornerRadius = 15
        button.addTarget(self, action: #selector(onAcceptButtonSelected), for: .touchUpInside)
        return button.withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "acceptButton")

    }()

    open
    private(set) lazy var rejectButton: UIButton = {
        let button = UIButton()
        button.setTitle("Skip", for: .normal)
        button.pin(anchors: [.height], to: 44)
        button.addTarget(self, action: #selector(onRejectButtonSelected), for: .touchUpInside)
        return button.withoutAutoresizingMaskConstraints
            .withAccessibilityIdentifier(identifier: "rejectButton")
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
        guard let channel = content?.channel else {
            return nil
        }
        return channel.isDirectMessageChannel ? "Sent you a friend request" : "Admin invites you"
    }

    /// Text of `timestampLabel` which contains the time of the last sent message.
    open var timestampText: String? {
        if let timestamp = content?.channel.previewMessage?.createdAt {
            return timestampFormatter.format(timestamp)
        }

        return nil
    }

    /// The item's view background color.
    open var contentBackgroundColor: UIColor {
        theme.colors.surface
    }

    /// The item's view background color when highlighted.
    open var contentHighlightedBackgroundColor: UIColor {
        theme.colors.surfaceContainer
    }

    open override func setUp() {
        super.setUp()
        timestampLabel.isHidden = true
    }

    override open func setUpTheme() {
        super.setUpTheme()
        backgroundColor = contentBackgroundColor

        titleLabel.font = theme.fonts.subheadline

        subtitleLabel.textColor = theme.colors.subtitleText
        subtitleLabel.font = theme.fonts.callout

        timestampLabel.textColor = theme.colors.subtitleText
        timestampLabel.font = theme.fonts.footnote
        acceptButton.setTitleColor(theme.colors.onPrimary,
                                   for: .normal)
        acceptButton.titleLabel?.font = theme.fonts.callout.semiBold
        acceptButton.backgroundColor = theme.colors.primary
        rejectButton.setTitleColor(theme.colors.primary,
                                   for: .normal)
        rejectButton.titleLabel?.font = theme.fonts.callout.semiBold
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
            subtitleContainer, timestampLabel
        ])

        joinRoomContainer.addArrangedSubviews([
            rejectButton,
            acceptButton
        ])

        rightContainer.addArrangedSubviews([
            topContainer,
            bottomContainer,
            joinRoomContainer
        ])

        let avatarView: UIView

        avatarView = self.avatarView

        NSLayoutConstraint.activate([
            avatarView.heightAnchor.pin(equalToConstant: 60),
            avatarView.widthAnchor.pin(equalTo: avatarView.heightAnchor)
        ])

        mainContainer.addArrangedSubviews([
            avatarView,
            rightContainer
        ])

        mainContainer.isLayoutMarginsRelativeArrangement = true

        timestampLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        embed(mainContainer)
    }

    override open func contentDidChanged() {
        titleLabel.text = titleText
        subtitleLabel.text = subtitleText
        timestampLabel.text = timestampText
        avatarView.content = .init(from: content?.channel)

        rejectButton.setTitle(content?.channel.isDirectMessageChannel == true ? "Skip" : "Decline", for: .normal)
    }

    // MARK: - Channel title rendering

    /// The channel title text in case the channel is part of a search result.
    open func channelTitleTextForSearchedMessage(_ message: ChatMessage) -> String {
        var title = "\(message.author.name ?? message.author.id)"
        if let channelName = content?.channel.name, !channelName.isEmpty {
            title += L10n.Channel.Item.Search.in(channelName)
        }
        return title
    }

    /// The default channel title text.
    open func channelTitleText(for channel: Channel) -> String? {
        formatters
            .channelName
            .format(channel: channel, forCurrentUserId: channel.membership?.id)
    }

    // MARK: - Preview message text rendering

    /// The message preview text in case the message is empty.
    /// - Returns:  A string representing the message preview text.
    open func previewMessageTextForEmptyMessage() -> String {
        L10n.Channel.Item.emptyMessages
    }

    /// The message preview text in case the message is an audio recording message.
    /// - Parameter messageText: The current text of the message.
    /// - Returns:  A string representing the message preview text.
    open func previewMessageForAudioRecordingMessage(messageText: String) -> String {
        L10n.ChannelList.Preview.Voice.recording
    }

    /// The message preview text in case the message is a system message.
    /// - Parameter messageText: The current text of the message.
    /// - Returns:  A string representing the message preview text.
    open func previewMessageTextForSystemMessage(messageText: String, in channel: Channel) -> String {
        let systemMessage = SystemMessage(systemMessage: messageText)
        return self.formatters.systemMessage.format(systemMessage: systemMessage, in: channel) ?? messageText
    }

    /// The message preview text in case the message is a search result.
    /// - Parameter messageText: The current text of the message.
    /// - Returns:  A string representing the message preview text.
    open func previewMessageTextForSearchedMessage(messageText: String) -> String {
        messageText
    }

    /// The message preview text in case the message is from the current user.
    /// - Parameter messageText: The current text of the message.
    /// - Returns:  A string representing the message preview text.
    open func previewMessageTextForCurrentUser(messageText: String) -> String {
        "\(L10n.you): \(messageText)"
    }

    /// The message preview text in case the message is a 1on1 channel.
    /// - Parameter messageText: The current text of the message.
    /// - Returns:  A string representing the message preview text.
    open func previewMessageTextFor1on1Channel(messageText: String) -> String {
        messageText
    }

    /// The message preview text in case the message is from another user and it is not a 1on1 channel.
    /// - Parameter messageText: The current text of the message.
    /// - Returns:  A string representing the message preview text.
    open func previewMessageTextFromAnotherUser(_ user: ChatUser, messageText: String) -> String {
        let authorName = user.name ?? user.userId
        return "\(authorName): \(messageText)"
    }

    /// The message preview text in case the message is translated.
    /// - Parameter previewMessage: The preview message of the channel.
    /// - Parameter messageText: The current text of the message.
    /// - Returns: A string representing the message preview text.
    open func translatedPreviewText(for previewMessage: ChatMessage, messageText: String) -> String? {
        guard let currentUserLang = content?.channel.membership?.language,
              let translatedText = previewMessage.translatedText(for: currentUserLang) else {
            return nil
        }
        return translatedText
    }

    /// The message preview text in case it contains attachments.
    /// - Parameter previewMessage: The preview message of the channel.
    /// - Parameter messageText: The current text of the message.
    /// - Returns: A string representing the message preview text.
    open func attachmentPreviewText(for previewMessage: ChatMessage, messageText: String) -> String? {
        guard let attachment = previewMessage.allAttachments.first else {
            return nil
        }
        let text = messageText
        switch attachment.type {
        case .audio:
            let defaultAudioText = L10n.Channel.Item.audio
            return "🎧 \(text.isEmpty ? defaultAudioText : text)"
        case .file:
            guard let fileAttachment = previewMessage.fileAttachments.first else {
                return nil
            }
            let title = fileAttachment.payload.title
            return "📄 \(title ?? text)"
        case .image:
            let defaultPhotoText = L10n.Channel.Item.photo
            return "📷 \(text.isEmpty ? defaultPhotoText : text)"
        case .video:
            let defaultVideoText = L10n.Channel.Item.video
            return "📹 \(text.isEmpty ? defaultVideoText : text)"
        default:
            return nil
        }
    }

    // MARK: - Action
    @objc
    func onAcceptButtonSelected() {
        guard let indexPath = indexPath?() else {
            return
        }
        delegate?.invitedChannelListItemView(self, didAcceptInviteAt: indexPath)
    }

    @objc
    func onRejectButtonSelected() {
        guard let indexPath = indexPath?() else {
            return
        }
        if content?.channel.isDirectMessageChannel == true {
            delegate?.invitedChannelListItemView(self, didSkipAt: indexPath)
        } else {
            delegate?.invitedChannelListItemView(self, didRejectInviteAt: indexPath)
        }
    }

    // MARK: - Channel preview when user is typing

    /// The formatted string containing the typing member.
    open var typingUserString: String? {
        return nil
    }
}

extension InvitedChannelListItemView {
    var isLastMessageVoiceRecording: Bool {
        content?.channel.previewMessage?.voiceRecordingAttachments.isEmpty == false && typingUserString == nil
    }
}
