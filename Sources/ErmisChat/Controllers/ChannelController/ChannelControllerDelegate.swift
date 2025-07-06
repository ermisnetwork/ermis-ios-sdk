//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// `ChannelController` uses this protocol to communicate changes to its delegate.
public protocol ChannelControllerDelegate: DataControllerStateDelegate {
    /// The controller observed a change in the `Channel` entity.
    func channelController(
        _ channelController: ChannelController,
        didUpdateChannel channel: EntityChange<Channel>
    )

    /// The controller observed changes in the `Messages` of the observed channel.
    func channelController(
        _ channelController: ChannelController,
        didUpdateMessages changes: [ListChange<ChatMessage>]
    )

    /// The controller received a `MemberEvent` related to the channel it observes.
    func channelController(_ channelController: ChannelController, didReceiveMemberEvent: MemberEvent)

    /// The controller received a change related to users typing in the channel it observes.
    func channelController(
        _ channelController: ChannelController,
        didChangeTypingUsers typingUsers: Set<ChatUser>
    )
}

public extension ChannelControllerDelegate {
    func channelController(
        _ channelController: ChannelController,
        didUpdateChannel channel: EntityChange<Channel>
    ) {}

    func channelController(
        _ channelController: ChannelController,
        didUpdateMessages changes: [ListChange<ChatMessage>]
    ) {}

    func channelController(_ channelController: ChannelController, didReceiveMemberEvent: MemberEvent) {}

    func channelController(
        _ channelController: ChannelController,
        didChangeTypingUsers: Set<ChatUser>
    ) {}
}
