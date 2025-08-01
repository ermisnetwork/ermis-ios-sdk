//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// The channel item view that displays information in a channel list cell.
open class ChannelListItemView: _View, UIProvider, PreviewMessageProvider, SwiftUIRepresentable {
    /// The content of this view.
    public struct Content {
        /// Channel for the current Item.
        public let channel: Channel
        /// Current user ID needed to filter out when showing typing indicator.
        public let currentUserId: UserId?
        /// The result of a search query.
        public let searchResult: SearchResult?

        /// The message part of a search result.
        var searchedMessage: ChatMessage? {
            searchResult?.message
        }

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
        }
    }

    /// The data this view component shows.
    public var content: Content? {
        didSet { updateContentIfNeeded() }
    }

    /// A formatter that converts the message timestamp to textual representation.
    public lazy var timestampFormatter: MessageTimestampFormatter = formatters.channelListMessageTimestamp

    /// Main container which holds `avatarView` and two horizontal containers `title` and `unreadCount` and
    /// `subtitle` and `timestampLabel`
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

    /// By default contains `title` and `unreadCount`.
    /// This container is embed inside `mainContainer ` and is the one above `bottomContainer`
    open private(set) lazy var topContainer: ContainerStackView = ContainerStackView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "topContainer")

    /// By default contains `subtitle` and `timestampLabel`.
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
    open private(set) lazy var subtitleImageView: UIImageView = UIImageView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "subtitleIcon")

    /// The `UILabel` instance showing the last message or typing users if any.
    open private(set) lazy var subtitleLabel: UILabel = UILabel()
        .withoutAutoresizingMaskConstraints
        .withAdjustingFontForContentSizeCategory
        .withBidirectionalLanguagesSupport
        .withAccessibilityIdentifier(identifier: "subtitleLabel")

    /// The `UIImageView` instance showing the status of drirect channel.
    open private(set) lazy var channelStatusImageView: UIImageView = UIImageView()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "statusImageView")

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

    /// The view used to show user avatar in case we are in a search result.
    open private(set) lazy var userAvatarView: UserAvatarView = components
        .userAvatarView
        .init()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "userAvatarView")

    /// The view showing number of unread messages in channel if any.
    open private(set) lazy var unreadCountView: UnreadCountView = components
        .channelUnreadCountView.init()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "unreadCountView")

    /// Text of `titleLabel` which contains the channel name.
    open var titleText: String? {
        if let searchedMessage = content?.searchedMessage {
            return channelTitleTextForSearchedMessage(searchedMessage)
        }

        if let channel = content?.channel {
            return channelTitleText(for: channel)
        }

        return nil
    }

    /// Text of `subtitleLabel` which contains current typing user or the last message in the channel.
    open var subtitleText: String? {
        guard let content = content else { return nil }

        if let searchedMessage = content.searchedMessage {
            if searchedMessage.type == .system {
                return previewMessageTextForSystemMessage(messageText: searchedMessage.text, in: content.channel)
            } else if searchedMessage.type == .signal {
                return previewMessageTextForCallMessage(messageText: searchedMessage.text, in: content.channel)
            }
            return previewMessageTextForSearchedMessage(messageText: searchedMessage.textContentAfterParseMention ?? searchedMessage.text)
        }

        if let typingUsersInfo = typingUserString {
            return typingUsersInfo
        }

        if isShowUnsentContent, let unsentContentText = content.channel.composerUnsentContent?.displayText {
            return unsentContentText
        }

        if let previewMessage = content.channel.previewMessage {
            if isLastMessageVoiceRecording {
                return previewMessageForAudioRecordingMessage(messageText: previewMessage.textContentAfterParseMention ?? previewMessage.text)
            }

            if previewMessage.type == .system {
                return previewMessageTextForSystemMessage(messageText: previewMessage.textContent ?? previewMessage.text,
                                                          in: content.channel)
            } else if previewMessage.type == .signal {
                return previewMessageTextForCallMessage(messageText: previewMessage.textContent ?? previewMessage.text,
                                                        in: content.channel)
            }

            var text = previewMessage.textContentAfterParseMention ?? previewMessage.text

            if let translatedText = translatedPreviewText(for: previewMessage,
                                                          in: content.channel,
                                                          messageText: text) {
                text = translatedText
            }

            if let attachmentText = attachmentPreviewText(for: previewMessage, messageText: text) {
                text = attachmentText
            }

            if previewMessage.isSentByCurrentUser {
                return previewMessageTextForCurrentUser(messageText: text)
            }

            if content.channel.memberCount == 2 {
                return previewMessageTextFor1on1Channel(messageText: text)
            }

            return previewMessageTextFromAnotherUser(previewMessage.author, messageText: text)
        }

        return previewMessageTextForEmptyMessage()
    }

    open var subtitleIcon: UIImage? {
        isLastMessageVoiceRecording ? theme.icons.mic : nil
    }

    /// Text of `timestampLabel` which contains the time of the last sent message.
    open var timestampText: String? {
        if let searchedMessage = content?.searchedMessage {
            return timestampFormatter.format(searchedMessage.createdAt)
        }
        
        if let timestamp = content?.channel.previewMessage?.createdAt {
            return timestampFormatter.format(timestamp)
        }

        return nil
    }

    /// The delivery status to be shown for the channel's preview message.
    open var previewMessageDeliveryStatus: MessageDeliveryStatus? {
        if content?.searchedMessage != nil {
            // When doing message search, we don't want to display delivery status.
            return nil
        }

        guard
            let content = content,
            let deliveryStatus = content.channel.previewMessage?.deliveryStatus
        else { return nil }

        switch deliveryStatus {
        case .pending, .failed:
            return deliveryStatus
        case .sent, .read:
            guard content.channel.config?.readEventsEnabled ?? true else { return nil }
            return deliveryStatus
        default:
            return nil
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

    /// The indicator the delivery status of the channel preview message.
    open private(set) lazy var previewMessageDeliveryStatusView = components
        .messageDeliveryStatusCheckmarkView.init()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "previewMessageDeliveryStatusView")

    override open func setUpTheme() {
        super.setUpTheme()
        backgroundColor = contentBackgroundColor

        titleLabel.font = theme.fonts.body.bold

        channelStatusImageView.tintColor = theme.colors.error

        subtitleLabel.textColor = theme.colors.subtitleText
        subtitleLabel.font = theme.fonts.body

        subtitleImageView.tintColor = subtitleLabel.textColor
        subtitleImageView.contentMode = .scaleAspectFit

        timestampLabel.textColor = theme.colors.subtitleText
        timestampLabel.font = theme.fonts.footnote
    }

    open override func setUp() {
        topContainer.alignment = .center
        topContainer.distribution = .natural
        bottomContainer.alignment = .fill
        channelStatusImageView.contentMode = .center
    }

    override open func setUpUI() {
        super.setUpUI()

        topContainer.addArrangedSubviews([
            titleLabel.flexible(axis: .horizontal), channelStatusImageView, timestampLabel
        ])


        channelStatusImageView.pin(anchors: [.width, .height], to: 20)

        subtitleContainer.axis = .horizontal
        subtitleContainer.spacing = 4
        subtitleContainer.alignment = .center
        subtitleContainer.addArrangedSubview(subtitleLabel)
        subtitleContainer.addArrangedSubview(UIView().flexible(axis: .horizontal))


        bottomContainer.addArrangedSubviews([
            subtitleContainer, unreadCountView
        ])

        rightContainer.addArrangedSubviews([
            topContainer, bottomContainer
        ])

        let avatarView: UIView

        if content?.searchedMessage != nil {
            avatarView = userAvatarView
        } else {
            avatarView = self.avatarView
        }

        avatarView.pin(anchors: [.width, .height], to: 60)

        mainContainer.addArrangedSubviews([
            avatarView,
            rightContainer
        ])

        mainContainer.alignment = .center
        mainContainer.isLayoutMarginsRelativeArrangement = false
        rightContainer.alignment = .fill
        rightContainer.distribution = .natural
        timestampLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        embed(mainContainer, insets: .init(top: 0, leading: 24, bottom: 0, trailing: 24))
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)


    }

    override open func contentDidChanged() {
        titleLabel.text = titleText
        if isShowUnsentContent {
            let subtitleAttributedString = NSMutableAttributedString(string: "\(L10n.ChannelList.LastMessage.draft): ",
                                                               attributes: [.foregroundColor: theme.colors.error])
            subtitleAttributedString.append(.init(string: subtitleText ?? ""))
            subtitleLabel.attributedText = subtitleAttributedString
        } else {
            subtitleLabel.text = subtitleText
        }
        timestampLabel.text = timestampText
        subtitleImageView.image = subtitleIcon
        if subtitleImageView.image != nil {
            subtitleImageView.heightAnchor.pin(equalToConstant: subtitleLabel.font.pointSize).isActive = true
            subtitleImageView.widthAnchor.pin(equalTo: subtitleImageView.heightAnchor).isActive = true
            subtitleContainer.insertArrangedSubview(subtitleImageView, at: 0)
        } else if subtitleImageView.superview == subtitleContainer {
            subtitleContainer.removeArrangedSubview(subtitleImageView)
        }

        if let searchedMessage = content?.searchedMessage {
            userAvatarView.content = .init(with: searchedMessage.author)
        } else {
            avatarView.content = .init(from: content?.channel)
        }

        unreadCountView.content = .init(channelUnreadCount: content?.channel.unreadCount ?? .noUnread)
        unreadCountView.invalidateIntrinsicContentSize()

        if content?.searchedMessage != nil {
            unreadCountView.content = .init(channelUnreadCount: .noUnread)
        }

        let checkmarkContent = previewMessageDeliveryStatus.map {
            MessageDeliveryStatusCheckmarkView.Content(deliveryStatus: $0)
        }
        previewMessageDeliveryStatusView.content = checkmarkContent
        previewMessageDeliveryStatusView.isHidden = checkmarkContent == nil

        if let status = checkmarkContent?.deliveryStatus {
            bottomContainer.insertArrangedSubview(
                previewMessageDeliveryStatusView,
                at: status == .pending || status == .failed ? 0 : 1
            )
        }
        updateChannelStatusImageView()
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
            .format(channel: channel, forCurrentUserId: channel.membership?.userId)
    }
    // MARK: - Channel preview when user is typing

    /// The formatted string containing the typing member.
    open var typingUserString: String? {
        guard let users = content?.channel.currentlyTypingUsers.filter({ $0.id != content?.currentUserId }),
              !users.isEmpty
        else { return nil }

        let name = users.first?.name ?? "Someone"
        return L10n.MessageList.TypingIndicator.users(name, users.count - 1)  + "..."
    }

    // MARK: - Update channel status imageView
    open func updateChannelStatusImageView() {
        let isFavorited = content?.channel.isPinned ?? false
        let isBlocked = content?.channel.isBlocked ?? false
        let isMuted = content?.channel.isMuted ?? false
        if isBlocked {
            channelStatusImageView.image = theme.icons.block
        } else if isMuted {
            channelStatusImageView.image = theme.icons.mute
        } else if isFavorited {
            channelStatusImageView.image = theme.icons.favorite
        } else {
            channelStatusImageView.image = nil
        }

        let isHidden = !isBlocked && !isMuted && !isFavorited
        channelStatusImageView.isHidden == isHidden
        channelStatusImageView.pin(anchors: [.width], to: isHidden ? 0 : 20)
    }
}

extension ChannelListItemView {
    var isShowUnsentContent: Bool {
        guard let unsentContent = content?.channel.composerUnsentContent else {
            return false
        }
        guard let lastMessage = content?.channel.previewMessage else {
            return true
        }
        return (lastMessage.textUpdatedAt ?? lastMessage.createdAt) < unsentContent.createdAt
    }

    var isLastMessageVoiceRecording: Bool {
        if isShowUnsentContent {
            return false
        }
        return content?.channel.previewMessage?.voiceRecordingAttachments.isEmpty == false && typingUserString == nil
    }
}
