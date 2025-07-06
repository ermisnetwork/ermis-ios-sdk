//
// Copyright 2025 Ermis Inc.
//

import ErmisChat
import UIKit

/// The view that displays channel information on the thread header
open class ThreadHeaderView: _View,
                             UIProvider,
                             ChannelControllerDelegate {
    
    /// Controller for observing data changes within the channel.
    open var channelController: ChannelController?

    /// The user id of the current logged in user.
    open var currentUserId: UserId? {
        channelController?.client.currentUserId
    }

    /// A view that displays a title label and subtitle in a container stack view.
    open private(set) lazy var titleContainerView: TitleContainerView = components
        .titleContainerView.init()
        .withoutAutoresizingMaskConstraints
        .withAccessibilityIdentifier(identifier: "titleContainerView")

    override open func setUp() {
        super.setUp()

        channelController?.delegate = self
    }

    override open func setUpUI() {
        super.setUpUI()

        embed(titleContainerView)
    }

    override open func contentDidChanged() {
        super.contentDidChanged()

        titleContainerView.content = .init(title: titleText, subtitle: subtitleText)
    }

    /// The title text used to render the title label. By default it is "Thread Reply" label.
    open var titleText: String? {
        L10n.Message.Threads.reply
    }

    /// The subtitle text used in the subtitle label. By default it is the channel name.
    open var subtitleText: String? {
        guard let channel = channelController?.channel else { return nil }
        let channelName = formatters.channelName.format(
            channel: channel,
            forCurrentUserId: currentUserId
        )
        return channelName.map { L10n.Message.Threads.replyWith($0) }
    }

    // MARK: - ChannelControllerDelegate Implementation

    open func channelController(
        _ channelController: ChannelController,
        didUpdateChannel channel: EntityChange<Channel>
    ) {
        switch channel {
        case .update:
            updateContentIfNeeded()
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
}
