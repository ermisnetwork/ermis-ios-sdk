//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// An event type.
public struct EventType: RawRepresentable, Codable, Hashable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}

public extension EventType {
    static let healthCheck: Self = "health.check"

    // MARK: User Events

    /// When a user presence changed, e.g. online, offline, away.
    static let userPresenceChanged: Self = "user.presence.changed"
    /// When a user was updated.
    static let userUpdated: Self = "user.updated"
    /// When a user starts watching a channel.
    static let userStartWatching: Self = "user.watching.start"
    /// When a user stops watching a channel.
    static let userStopWatching: Self = "user.watching.stop"
    /// Sent when a user starts typing.
    static let userStartTyping: Self = "typing.start"
    /// Sent when a user stops typing.
    static let userStopTyping: Self = "typing.stop"
    /// When a user was banned.
    static let userBanned: Self = "user.banned"
    /// When a user was unbanned.
    static let userUnbanned: Self = "user.unbanned"

    // MARK: Channel Events
    /// When a channel was updated.
    static let channelUpdated: Self = "channel.updated"
    /// When a channel was deleted.
    static let channelDeleted: Self = "channel.deleted"
    /// When a channel was hidden.
    static let channelHidden: Self = "channel.hidden"
    /// When a channel is visible.
    static let channelVisible: Self = "channel.visible"
    /// When a channel was truncated.
    static let channelTruncated: Self = "channel.truncated"
    /// When a channel was pinned
    static let channelPinned: Self = "channel.pinned"
    /// When a channel was unpinned
    static let channelUnpinned: Self = "channel.unpinned"
    /// When a channel topic was enable.
    static let channelTopicEnable: Self = "channel.topic.enabled"
    /// When a channel topic was disable.
    static let channelTopicDisable: Self = "channel.topic.disabled"
    /// When a channel topic was created.
    static let channelTopicCreated: Self = "channel.topic.created"

    // MARK: Message Events

    /// When a new message was added on a channel.
    static let messageNew: Self = "message.new"
    /// When a message was updated.
    static let messageUpdated: Self = "message.updated"
    /// When a message was pinned.
    static let messagePinned: Self = "message.pinned"
    /// When a message was unpinned.
    static let messageUnpinned: Self = "message.unpinned"
    /// When a message was deleted.
    static let messageDeleted: Self = "message.deleted"
    /// When a channel was marked as read.
    static let messageRead: Self = "message.read"

    /// When a member was added to a channel.
    static let memberAdded: Self = "member.added"
    /// When a member joinned a public channel.
    static let memberJoinned: Self = "member.joined"
    /// When a member was updated.
    static let memberUpdated: Self = "member.updated"
    /// When a member was removed from a channel.
    static let memberRemoved: Self = "member.removed"
    /// When a member was promoted to mod.
    static let memberPromoted: Self = "member.promoted"
    /// When a member was demote to member.
    static let memberDemoted: Self = "member.demoted"
    /// When a member was banned.
    static let memberBanned: Self = "member.banned"
    /// When a member was unbanned.
    static let memberUnBanned: Self = "member.unbanned"
    /// When a member was blocked.
    static let memberBlocked: Self = "member.blocked"
    /// When a member was unblock.
    static let memberUnblocked: Self = "member.unblocked"
    // MARK: Reactions

    /// When a message reaction was added.
    static let reactionNew: Self = "reaction.new"
    /// When a message reaction updated.
    static let reactionUpdated: Self = "reaction.updated"
    /// When a message reaction deleted.
    static let reactionDeleted: Self = "reaction.deleted"

    /// When a message was added to a channel (when clients that are not currently watching the channel).
    static let notificationMessageNew: Self = "notification.message_new"
    /// When the total count of unread messages (across all channels the user is a member) changes
    /// (when clients from the user affected by the change).
    static let notificationMarkRead: Self = "notification.mark_read"

    /// When a message of a channel is marked as unread
    static let notificationMarkUnread: Self = "notification.mark_unread"

    /// When the user mutes someone.
    static let notificationMutesUpdated: Self = "notification.mutes_updated"
    /// When someone else from channel has muted someone.
    static let notificationChannelMutesUpdated: Self = "notification.channel_mutes_updated"

    /// When user create a channel.
    static let notificationChannelCreated: Self = "channel.created"

    /// When a user is invited to a channel
    static let notificationInvited: Self = "notification.invited"

    /// When a user accepted a channel invitation
    static let notificationInviteAccepted: Self = "notification.invite_accepted"

    /// When a user rejected a channel invitation
    static let notificationInviteRejected: Self = "notification.invite_rejected"

    static let notificationInviteSkipped: Self = "notification.invite_messaging_skipped"

    /// When a user rejected a direct invitation
    static let notificationInviteMessagingRejected: Self = "notification.invite_messaging_rejected"

    /// When a user was removed from a channel.
    static let notificationRemovedFromChannel: Self = "notification.removed_from_channel"

    /// When a channel was deleted
    static let notificationChannelDeleted: Self = "notification.channel_deleted"

    /// When receive call signal
    static let callSignal: Self = "signal"
    // MARK: - Call

}

extension EventType {
    func event(from response: EventPayload) throws -> Event {
        switch self {
        case .healthCheck: return try HealthCheckEvent(from: response)

        case .userPresenceChanged: return try UserPresenceChangedEventDTO(from: response)
        case .userUpdated: return try UserUpdatedEventDTO(from: response)
        case .userStartWatching, .userStopWatching: return try UserWatchingEventDTO(from: response)
        case .userStartTyping, .userStopTyping: return try TypingEventDTO(from: response)
        case .userBanned:
            return try (try? UserBannedEventDTO(from: response)) ?? UserGloballyBannedEventDTO(from: response)
        case .userUnbanned:
            return try (try? UserUnbannedEventDTO(from: response)) ?? UserGloballyUnbannedEventDTO(from: response)

        case .channelUpdated: return try ChannelUpdatedEventDTO(from: response)
        case .channelDeleted: return try ChannelDeletedEventDTO(from: response)
        case .channelHidden: return try ChannelHiddenEventDTO(from: response)
        case .channelTruncated: return try ChannelTruncatedEventDTO(from: response)
        case .channelVisible: return try ChannelVisibleEventDTO(from: response)
        case .channelPinned: return try ChannelPinnedEventDTO(from: response)
        case .channelUnpinned: return try ChannelUnpinnedEventDTO(from: response)
        case .channelTopicEnable: return try ChannelTopicEnableEventDTO(from: response)
        case .channelTopicDisable: return try ChannelTopicDisableEventDTO(from: response)
        case .channelTopicCreated: return try ChannelTopicCreatedEventDTO(from: response)

        case .messageNew: return try MessageNewEventDTO(from: response)
        case .messageUpdated: return try MessageUpdatedEventDTO(from: response)
        case .messagePinned: return try MessagePinnedEventDTO(from: response)
        case .messageUnpinned: return try MessagePinnedEventDTO(from: response)
        case .messageDeleted: return try MessageDeletedEventDTO(from: response)
        case .messageRead: return try MessageReadEventDTO(from: response)

        case .memberAdded: return try MemberAddedEventDTO(from: response)
        case .memberJoinned: return try MemberJoinnedEventDTO(from: response)
        case .memberUpdated: return try MemberUpdatedEventDTO(from: response)
        case .memberRemoved: return try MemberRemovedEventDTO(from: response)
        case .memberPromoted: return try MemberUpdatedEventDTO(from: response)
        case .memberDemoted: return try MemberUpdatedEventDTO(from: response)
        case .memberBanned: return try MemberBannedEventDTO(from: response)
        case .memberUnBanned: return try MemberUnbannedEventDTO(from: response)
        case .memberBlocked: return try MemberUpdatedEventDTO(from: response)
        case .memberUnblocked: return try MemberUpdatedEventDTO(from: response)

        case .reactionNew: return try ReactionNewEventDTO(from: response)
        case .reactionUpdated: return try ReactionUpdatedEventDTO(from: response)
        case .reactionDeleted: return try ReactionDeletedEventDTO(from: response)

        case .notificationMessageNew: return try NotificationMessageNewEventDTO(from: response)

        case .notificationMarkRead:
            return response.channel == nil
                ? try NotificationMarkAllReadEventDTO(from: response)
                : try NotificationMarkReadEventDTO(from: response)
        case .notificationMarkUnread:
            return try NotificationMarkUnreadEventDTO(from: response)

        case .notificationMutesUpdated: return try NotificationMutesUpdatedEventDTO(from: response)
        case .notificationChannelCreated: return try NotificationChannelCreatedEventDTO(from: response)
        case .notificationRemovedFromChannel: return try NotificationRemovedFromChannelEventDTO(from: response)
        case .notificationChannelMutesUpdated: return try NotificationChannelMutesUpdatedEventDTO(from: response)
        case .notificationInvited:
            return try NotificationInvitedEventDTO(from: response)
        case .notificationInviteAccepted:
            return try NotificationInviteAcceptedEventDTO (from: response)
        case .notificationInviteSkipped:
            return try NotificationInviteSkippedEventDTO(from: response)
        case .notificationInviteRejected:
            return try NotificationInviteRejectedEventDTO(from: response)
        case .notificationInviteMessagingRejected:
            return try NotificationInviteMessagingRejectedEventDTO(from: response)
        case .notificationChannelDeleted: return try NotificationChannelDeletedEventDTO(from: response)
        case .callSignal: return try CallSignalEventDTO(from: response)
        default:
            if response.cid == nil {
                throw ClientError.UnknownUserEvent(response.eventType)
            } else {
                throw ClientError.UnknownChannelEvent(response.eventType)
            }
        }
    }
}

extension ClientError {
    class UnknownChannelEvent: ClientError {
        init(_ type: EventType) {
            super.init("Event with \(type) cannot be decoded as system event.")
        }
    }

    class UnknownUserEvent: ClientError {
        init(_ type: EventType) {
            super.init("Event with \(type) cannot be decoded as system event.")
        }
    }
}
