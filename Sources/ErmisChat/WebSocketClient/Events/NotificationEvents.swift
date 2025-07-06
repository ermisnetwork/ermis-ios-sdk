//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// Triggered when a new message is sent to a channel the current user is member of.
public struct NotificationMessageNewEvent: ChannelSpecificEvent, HasUnreadCount {
    /// The identifier of a channel a message is sent to.
    public var cid: ChannelId { channel.cid }

    /// The channel a message was sent to.
    public let channel: Channel

    /// The sent message.
    public let message: ChatMessage

    /// The event timestamp.
    public let createdAt: Date

    /// The unread counts of the current user.
    public let unreadCount: UnreadCount?
}

class NotificationMessageNewEventDTO: EventDTO {
    let channel: ChannelDetailPayload
    let message: MessagePayload
    let unreadCount: UnreadCount?
    let createdAt: Date
    let payload: EventPayload

    init(from response: EventPayload) throws {
        channel = try response.value(at: \.channel)
        message = try response.value(at: \.message)
        createdAt = try response.value(at: \.createdAt)
        unreadCount = try? response.value(at: \.unreadCount)
        payload = response
    }

    func toDomainEvent(session: DatabaseSession) -> Event? {
        guard
            let channelDTO = session.channel(cid: channel.cid),
            let messageDTO = session.message(id: message.id)
        else { return nil }

        return try? NotificationMessageNewEvent(
            channel: channelDTO.asModel(),
            message: messageDTO.asModel(),
            createdAt: createdAt,
            unreadCount: unreadCount
        )
    }
}

/// Triggered when all channels the current user is member of are marked as read.
public struct NotificationMarkAllReadEvent: Event, HasUnreadCount {
    /// The current user.
    public let user: ChatUser

    /// The unread counts of the current user.
    public let unreadCount: UnreadCount?

    /// The event timestamp.
    public let createdAt: Date
}

class NotificationMarkAllReadEventDTO: EventDTO {
    let user: UserPayload
    let unreadCount: UnreadCount
    let createdAt: Date
    let payload: EventPayload

    init(from response: EventPayload) throws {
        user = try response.value(at: \.user)
        createdAt = try response.value(at: \.createdAt)
        unreadCount = try response.value(at: \.unreadCount)
        payload = response
    }

    func toDomainEvent(session: DatabaseSession) -> Event? {
        guard let userDTO = session.user(id: user.id, projectId: payload.getProjectId()) else { return nil }

        return try? NotificationMarkAllReadEvent(
            user: userDTO.asModel(),
            unreadCount: unreadCount,
            createdAt: createdAt
        )
    }
}

/// Triggered when a channel the current user is member of is marked as read.
public struct NotificationMarkReadEvent: ChannelSpecificEvent, HasUnreadCount {
    /// The current user.
    public let user: ChatUser

    /// The read channel identifier.
    public let cid: ChannelId

    /// The unread counts of the current user.
    public let unreadCount: UnreadCount?

    /// The id of the last read message id
    public let lastReadMessageId: MessageId?

    /// The event timestamp.
    public let createdAt: Date
}

/// Triggered when a channel the current user is member of is marked as unread.
public struct NotificationMarkUnreadEvent: ChannelSpecificEvent {
    /// The current user.
    public let user: ChatUser

    /// The read channel identifier.
    public let cid: ChannelId

    /// The event timestamp.
    public let createdAt: Date

    /// The id of the first unread message id
    public let firstUnreadMessageId: MessageId

    /// The id of the last read message id
    public let lastReadMessageId: MessageId?

    /// The timestamp of the last read message
    public let lastReadAt: Date

    /// The number of unread messages for the channel
    public let unreadMessagesCount: Int
}

class NotificationMarkReadEventDTO: EventDTO {
    let user: UserPayload
    let cid: ChannelId
    let unreadCount: UnreadCount
    let createdAt: Date
    let lastReadMessageId: MessageId?
    let payload: EventPayload

    init(from response: EventPayload) throws {
        user = try response.value(at: \.user)
        cid = try response.value(at: \.cid)
        createdAt = try response.value(at: \.createdAt)
        unreadCount = try response.value(at: \.unreadCount)
        lastReadMessageId = try? response.value(at: \.lastReadMessageId)
        payload = response
    }

    func toDomainEvent(session: DatabaseSession) -> Event? {
        guard let userDTO = session.user(id: user.id, projectId: cid.projectId) else { return nil }

        return try? NotificationMarkReadEvent(
            user: userDTO.asModel(),
            cid: cid,
            unreadCount: unreadCount,
            lastReadMessageId: lastReadMessageId,
            createdAt: createdAt
        )
    }
}

class NotificationMarkUnreadEventDTO: EventDTO {
    let user: UserPayload
    let cid: ChannelId
    let createdAt: Date
    let firstUnreadMessageId: MessageId
    let lastReadMessageId: MessageId?
    let lastReadAt: Date
    let unreadMessagesCount: Int
    let payload: EventPayload

    init(from response: EventPayload) throws {
        user = try response.value(at: \.user)
        cid = try response.value(at: \.cid)
        createdAt = try response.value(at: \.createdAt)
        firstUnreadMessageId = try response.value(at: \.firstUnreadMessageId)
        lastReadMessageId = try response.value(at: \.lastReadMessageId)
        lastReadAt = try response.value(at: \.lastReadAt)
        unreadMessagesCount = try response.value(at: \.unreadMessagesCount)
        payload = response
    }

    func toDomainEvent(session: DatabaseSession) -> Event? {
        guard let userDTO = session.user(id: user.id, projectId: cid.projectId) else { return nil }

        return try? NotificationMarkUnreadEvent(
            user: userDTO.asModel(),
            cid: cid,
            createdAt: createdAt,
            firstUnreadMessageId: firstUnreadMessageId,
            lastReadMessageId: lastReadMessageId,
            lastReadAt: lastReadAt,
            unreadMessagesCount: unreadMessagesCount
        )
    }
}

/// Triggered when current user mutes/unmutes a user.
public struct NotificationMutesUpdatedEvent: Event {
    /// The current user.
    public let currentUser: CurrentChatUser

    /// The event timestamp.
    public let createdAt: Date
}

class NotificationMutesUpdatedEventDTO: EventDTO {
    let currentUser: CurrentUserPayload
    let createdAt: Date
    let payload: EventPayload

    init(from response: EventPayload) throws {
        currentUser = try response.value(at: \.currentUser)
        createdAt = try response.value(at: \.createdAt)
        payload = response
    }

    func toDomainEvent(session: DatabaseSession) -> Event? {
        guard let currentUserDTO = session.currentUser else { return nil }

        return try? NotificationMutesUpdatedEvent(
            currentUser: currentUserDTO.asModel(payload.getProjectId()),
            createdAt: createdAt
        )
    }
}

/// Triggered when the current user is added to the channel member list.
public struct NotificationAddedToChannelEvent: ChannelSpecificEvent, HasUnreadCount {
    /// The identifier of a channel a message is sent to.
    public var cid: ChannelId { channel.cid }

    /// The channel the current user was added to.
    public let channel: Channel

    /// The unread counts of the current user.
    public let unreadCount: UnreadCount?

    /// The membership information of the current user.
    public let member: ChannelMember

    /// The event timestamp.
    public let createdAt: Date
}

class NotificationChannelCreatedEventDTO: EventDTO {
    let channel: ChannelDetailPayload
    let unreadCount: UnreadCount?
    // This `member` field is equal to the `membership` field in channel query
    let member: MemberPayload
    let createdAt: Date
    let payload: EventPayload

    init(from response: EventPayload) throws {
        channel = try response.value(at: \.channel)
        unreadCount = try? response.value(at: \.unreadCount)
        member = try response.value(at: \.memberContainer?.member)
        createdAt = try response.value(at: \.createdAt)
        payload = response
    }

    func toDomainEvent(session: DatabaseSession) -> Event? {
        guard
            let channelDTO = session.channel(cid: channel.cid),
            let memberDTO = session.member(userId: member.userId, cid: channel.cid)
        else { return nil }

        return try? NotificationAddedToChannelEvent(
            channel: channelDTO.asModel(),
            unreadCount: unreadCount,
            member: memberDTO.asModel(),
            createdAt: createdAt
        )
    }
}

/// Triggered when the current user is removed from a channel member list.
public struct NotificationRemovedFromChannelEvent: ChannelSpecificEvent {
    /// The user who removed the current user from channel members.
    public let user: ChatUser

    /// The channel identifier the current user was removed from.
    public let cid: ChannelId

    /// The current user.
    public let member: ChannelMember

    /// The event timestamp.
    public let createdAt: Date
}

class NotificationRemovedFromChannelEventDTO: EventDTO {
    let cid: ChannelId
    let user: UserPayload
    // This `member` field is equal to the `membership` field in channel query
    let member: MemberPayload
    let createdAt: Date
    let payload: EventPayload

    init(from response: EventPayload) throws {
        cid = try response.value(at: \.cid)
        user = try response.value(at: \.user)
        member = try response.value(at: \.memberContainer?.member)
        createdAt = try response.value(at: \.createdAt)
        payload = response
    }

    func toDomainEvent(session: DatabaseSession) -> Event? {
        guard
            let userDTO = session.user(id: user.id, projectId: cid.projectId),
            let memberDTO = session.member(userId: member.userId, cid: cid)
        else { return nil }

        return try? NotificationRemovedFromChannelEvent(
            user: userDTO.asModel(),
            cid: cid,
            member: memberDTO.asModel(),
            createdAt: createdAt
        )
    }
}

/// Triggered when current user mutes/unmutes a channel.
public struct NotificationChannelMutesUpdatedEvent: Event {
    /// The current user.
    public let currentUser: CurrentChatUser

    /// The event timestamp.
    public let createdAt: Date
}

class NotificationChannelMutesUpdatedEventDTO: EventDTO {
    let currentUser: CurrentUserPayload
    let createdAt: Date
    let payload: EventPayload

    init(from response: EventPayload) throws {
        currentUser = try response.value(at: \.currentUser)
        createdAt = try response.value(at: \.createdAt)
        payload = response
    }

    func toDomainEvent(session: DatabaseSession) -> Event? {
        guard let currentUserDTO = session.currentUser else { return nil }

        return try? NotificationChannelMutesUpdatedEvent(
            currentUser: currentUserDTO.asModel(payload.getProjectId()),
            createdAt: createdAt
        )
    }
}

/// Triggered when current user is invited to a channel.
public struct NotificationInvitedEvent: MemberEvent, ChannelSpecificEvent {
    /// The inviter.
    public let user: ChatUser

    /// The channel identifier the current user was invited to.
    public let cid: ChannelId

    /// The membership information of the current user.
    public let member: ChannelMember

    /// The event timestamp.
    public let createdAt: Date
}

class NotificationInvitedEventDTO: EventDTO {
    let user: UserPayload
    let cid: ChannelId
    // This `member` field is equal to the `membership` field in channel query
    let member: MemberPayload
    let createdAt: Date
    let payload: EventPayload

    init(from response: EventPayload) throws {
        user = try response.value(at: \.user)
        cid = try response.value(at: \.cid)
        member = try response.value(at: \.memberContainer?.member)
        createdAt = try response.value(at: \.createdAt)
        payload = response
    }

    func toDomainEvent(session: DatabaseSession) -> Event? {
        guard
            let userDTO = session.user(id: user.id, projectId: cid.projectId),
            let memberDTO = session.member(userId: member.userId, cid: cid)
        else { return nil }

        return try? NotificationInvitedEvent(
            user: userDTO.asModel(),
            cid: cid,
            member: memberDTO.asModel(),
            createdAt: createdAt
        )
    }
}

public enum InvitationRespondBackType {
    case accept
    case skip
    case reject
    case messagingReject
}

/// Triggered when the current user respond back to an invite to a channel.
public struct NotificationInviteRespondBackEvent: MemberEvent, ChannelSpecificEvent {
    /// The channel identifier the current user has become a member of.
    public var cid: ChannelId { channel.cid }

    /// The channel the current user has become a member of.
    public let channel: Channel

    /// The membership information of the current user.
    public let member: ChannelMember

    /// The respondback type.
    public let respondBackType: InvitationRespondBackType

    /// The event timestamp.
    public let createdAt: Date
}

class NotificationInviteAcceptedEventDTO: EventDTO {
    let cid: ChannelId
    // This `member` field is equal to the `membership` field in channel query
    let member: MemberPayload
    let createdAt: Date
    let payload: EventPayload

    init(from response: EventPayload) throws {
        cid = try response.value(at: \.cid)
        member = try response.value(at: \.memberContainer?.member)
        createdAt = try response.value(at: \.createdAt)
        payload = response
    }

    func toDomainEvent(session: DatabaseSession) -> Event? {
        guard
            let channelDTO = session.channel(cid: cid),
            let memberDTO = session.member(userId: member.userId, cid: cid)
        else { return nil }

        return try? NotificationInviteRespondBackEvent(
            channel: channelDTO.asModel(),
            member: memberDTO.asModel(),
            respondBackType: .accept,
            createdAt: createdAt
        )
    }
}

class NotificationInviteSkippedEventDTO: EventDTO {
    let cid: ChannelId
    // This `member` field is equal to the `membership` field in channel query
    let member: MemberPayload
    let createdAt: Date
    let payload: EventPayload

    init(from response: EventPayload) throws {
        cid = try response.value(at: \.cid)
        member = try response.value(at: \.memberContainer?.member)
        createdAt = try response.value(at: \.createdAt)
        payload = response
    }

    func toDomainEvent(session: DatabaseSession) -> Event? {
        guard
            let channelDTO = session.channel(cid: cid),
            let memberDTO = session.member(userId: member.userId, cid: cid)
        else { return nil }

        return try? NotificationInviteRespondBackEvent(
            channel: channelDTO.asModel(),
            member: memberDTO.asModel(),
            respondBackType: .skip,
            createdAt: createdAt
        )
    }
}

class NotificationInviteRejectedEventDTO: EventDTO {
    let cid: ChannelId
    // This `member` field is equal to the `membership` field in channel query
    let member: MemberPayload
    let createdAt: Date
    let payload: EventPayload

    init(from response: EventPayload) throws {
        cid = try response.value(at: \.cid)
        member = try response.value(at: \.memberContainer?.member)
        createdAt = try response.value(at: \.createdAt)
        payload = response
    }

    func toDomainEvent(session: DatabaseSession) -> Event? {
        guard
            let channelDTO = session.channel(cid: cid),
            let memberDTO = session.member(userId: member.userId, cid: cid)
        else { return nil }

        return try? NotificationInviteRespondBackEvent(
            channel: channelDTO.asModel(),
            member: memberDTO.asModel(),
            respondBackType: .reject,
            createdAt: createdAt
        )
    }
}

class NotificationInviteMessagingRejectedEventDTO: EventDTO {
    //    let user: UserPayload
    let cid: ChannelId
    // This `member` field is equal to the `membership` field in channel query
    let member: MemberPayload
    let createdAt: Date
    let payload: EventPayload

    init(from response: EventPayload) throws {
        cid = try response.value(at: \.cid)
        member = try response.value(at: \.memberContainer?.member)
        createdAt = try response.value(at: \.createdAt)
        payload = response
    }

    func toDomainEvent(session: DatabaseSession) -> Event? {
        guard
            let channelDTO = session.channel(cid: cid),
            let memberDTO = session.member(userId: member.userId, cid: cid)
        else { return nil }

        return try? NotificationInviteRespondBackEvent(
            channel: channelDTO.asModel(),
            member: memberDTO.asModel(),
            respondBackType: .messagingReject,
            createdAt: createdAt
        )
    }
}

/// Triggered when a channel is deleted, this event is delivered to all channel members
public struct NotificationChannelDeletedEvent: ChannelSpecificEvent {
    /// The cid of the deleted channel
    public let cid: ChannelId

    /// The channel that was deleted
    public let channel: Channel

    /// The event timestamp.
    public let createdAt: Date
}

class NotificationChannelDeletedEventDTO: EventDTO {
    let cid: ChannelId
    let channel: ChannelDetailPayload
    let createdAt: Date
    let payload: EventPayload

    init(from response: EventPayload) throws {
        cid = try response.value(at: \.cid)
        channel = try response.value(at: \.channel)
        createdAt = try response.value(at: \.createdAt)
        payload = response
    }

    func toDomainEvent(session: DatabaseSession) -> Event? {
        guard let channelDTO = session.channel(cid: channel.cid) else { return nil }
        return try? NotificationChannelDeletedEvent(
            cid: cid,
            channel: channelDTO.asModel(),
            createdAt: createdAt
        )
    }
}
