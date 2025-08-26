//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// The view that displays channel information on the message list header
open class ChannelHeaderView: _View, UIProvider, ChannelControllerDelegate {
    /// Controller for observing data changes within the channel.
    open var channelController: ChannelController? {
        didSet {
            channelController?.delegate = self
        }
    }

    /// Returns the date formater function used to represent when the user was last seen online
    open var lastSeenDateFormatter: (Date) -> String? { formatters.userLastActivity.format }

    /// The user id of the current logged in user.
    open var currentUserId: UserId? {
        channelController?.client.currentUserId
    }

    open var showAsTopic: Bool = false

    open var isCenterAlignment: Bool = false

    /// Timer used to update the online status of member in the channel.
    open var timer: Timer? {
        didSet {
            oldValue?.invalidate()
        }
    }

    /// The amount of time it updates the online status of the members.
    /// By default it is 60 seconds.
    open var statusUpdateInterval: TimeInterval { 60 }

    /// View for displaying the channel image in the navigation bar.
    open private(set) lazy var channelAvatarView = components
        .channelAvatarView.init(avatarStyle: .cornerRadius(15))
        .withoutAutoresizingMaskConstraints

    /// A view that displays a title label and subtitle in a container stack view.
    open private(set) lazy var titleContainerView: TitleContainerView = components
        .titleContainerView.init()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "titleContainerView")

    override open func setUp() {
        super.setUp()

        makeTimer()
    }

    override open func setUpUI() {
        super.setUpUI()
        addSubview(channelAvatarView)
        addSubview(titleContainerView)

        if isCenterAlignment {
            channelAvatarView.leadingAnchor.pin(greaterThanOrEqualTo: self.leadingAnchor).isActive = true
        } else {
            channelAvatarView.pin(anchors: [.leading], to: self)
        }
        channelAvatarView.pin(anchors: [.centerY], to: self)
        channelAvatarView.topAnchor.pin(greaterThanOrEqualTo: self.topAnchor).isActive = true
        channelAvatarView.pin(anchors: [.width, .height], to: 40)

        if isCenterAlignment {
            titleContainerView.trailingAnchor.pin(lessThanOrEqualTo: self.trailingAnchor, constant: -16).isActive = true
        } else {
            titleContainerView.pin(anchors: [.trailing], to: self)
        }

        titleContainerView.pin(anchors: [.top, .bottom], to: self)
        titleContainerView.leadingAnchor.pin(equalTo: channelAvatarView.trailingAnchor, constant: 10).isActive = true

        titleContainerView.containerView.alignment = .leading
    }

    override open func contentDidChanged() {
        super.contentDidChanged()

        titleContainerView.content = .init(title: titleText, subtitle: subtitleText)
        
        if let parentChannel = channelController?.channel?.parent {
            channelAvatarView.content = .init(from: parentChannel)
        } else {
            channelAvatarView.content = .init(from: channelController?.channel)
        }  
    }

    /// The title text used to render the title label. By default it is the channel name.
    open var titleText: String? {
        guard let channel = channelController?.channel else { return nil }
        if showAsTopic, (channel.topicsEnabled || channel.parentCid != nil) {
            return formatters.channelName.format(
                topic: channel,
                forCurrentUserId: currentUserId
            )
        }
        return formatters.channelName.format(
            channel: channel,
            forCurrentUserId: currentUserId
        )
    }

    /// The subtitle text used in the subtitle label. By default it shows member online status.
    open var subtitleText: String? {
        guard let channel = channelController?.channel else { return nil }
        if showAsTopic, channel.topicsEnabled || channel.parentCid != nil {
            return formatters
                .channelName
                .format(channel: channel.parent ?? channel,
                        forCurrentUserId: channel.membership?.userId)
        }
        guard let channel = channelController?.channel else { return nil }
        guard let currentUserId = self.currentUserId else { return nil }

        if channel.isDirectMessageChannel {
            guard let member = channel
                .lastActiveMembers
                .first(where: { $0.id != currentUserId })
            else {
                return nil
            }

            if member.isOnline {
                return L10n.Message.Title.online
            } else if let lastActiveAt = member.lastActiveAt, let timeAgo = lastSeenDateFormatter(lastActiveAt) {
                return timeAgo
            } else {
                return L10n.Message.Title.offline
            }
        }

        return L10n.Message.Title.group(channel.memberCount)
    }

    /// Create the timer to repeatedly update the online status of the members.
    open func makeTimer() {
        // Only create the timer if is not created yet and if the interval is not zero.
        guard timer == nil, statusUpdateInterval > 0 else {
            return
        }

        timer = Timer.scheduledTimer(
            withTimeInterval: statusUpdateInterval,
            repeats: true
        ) { [weak self] _ in
            self?.updateContentIfNeeded()
        }
    }

    // MARK: - ChannelControllerDelegate Implementation

    open func channelController(
        _ channelController: ChannelController,
        didUpdateChannel channel: EntityChange<Channel>
    ) {
        switch channel {
        case .update, .create:
            contentDidChanged()
        default:
            break
        }
    }

    open func channelController(
        _ channelController: ChannelController,
        didChangeTypingUsers typingUsers: Set<ChatUser>
    ) {
        // By default the header view is not interested in typing events
        // but this can be overridden by subclassing this component.
    }

    open func channelController(
        _ channelController: ChannelController,
        didReceiveMemberEvent: MemberEvent
    ) {
        // By default the header view is not interested in member events
        // but this can be overridden by subclassing this component.
    }

    open func channelController(
        _ channelController: ChannelController,
        didUpdateMessages changes: [ListChange<ChatMessage>]
    ) {
        // By default the header view is not interested in message events
        // but this can be overridden by subclassing this component.
    }

    deinit {
        timer?.invalidate()
    }
}
