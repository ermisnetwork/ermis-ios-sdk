//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// Triggered when a new member is added to a channel.
public struct MemberAddedEvent: MemberEvent, ChannelSpecificEvent {
    public let memberId: UserId
    /// The user who added a member to a channel.
    public let user: ChatUser

    /// The channel identifier a member was added to.
    public let cid: ChannelId

    /// The memeber that was added to a channel.
    public let member: ChannelMember?

    /// The event timestamp.
    public let createdAt: Date
}

class MemberAddedEventDTO: EventDTO {
    let user: UserPayload
    let cid: ChannelId
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
            let userDTO = session.user(id: user.id, projectId: cid.projectId)
        else { return nil }
        let memberDTO = session.member(userId: member.userId, cid: cid)

        return try? MemberAddedEvent(
            memberId: member.userId,
            user: userDTO.asModel(),
            cid: cid,
            member: memberDTO?.asModel(),
            createdAt: createdAt
        )
    }
}

/// Triggered when a new member is joinned to a channel.
public struct MemberJoinnedEvent: MemberEvent, ChannelSpecificEvent {
    /// The user who join a channel.
    public let user: ChatUser

    /// The channel identifier a member was added to.
    public let cid: ChannelId

    /// The memeber that was joinned to a channel.
    public let member: ChannelMember

    /// The event timestamp.
    public let createdAt: Date
}

class MemberJoinnedEventDTO: EventDTO {
    let user: UserPayload
    let cid: ChannelId
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

        return try? MemberJoinnedEvent(
            user: userDTO.asModel(),
            cid: cid,
            member: memberDTO.asModel(),
            createdAt: createdAt
        )
    }
}

/// Triggered when a channel member is updated.
public struct MemberUpdatedEvent: MemberEvent, ChannelSpecificEvent {
    /// The user who updated a member.
    public let user: ChatUser

    /// The channel identifier a member was updated in.
    public let cid: ChannelId

    /// The updated member.
    public let member: ChannelMember

    /// The event timestamp.
    public let createdAt: Date
}

/// Triggle when a member update.
class MemberUpdatedEventDTO: EventDTO {
    let user: UserPayload
    let cid: ChannelId
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

        return try? MemberUpdatedEvent(
            user: userDTO.asModel(),
            cid: cid,
            member: memberDTO.asModel(),
            createdAt: createdAt
        )
    }
}

/// Triggle when a member update.
class MemberBannedEventDTO: EventDTO {
    let user: UserPayload
    let cid: ChannelId
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

        return try? MemberUpdatedEvent(
            user: userDTO.asModel(),
            cid: cid,
            member: memberDTO.asModel(),
            createdAt: createdAt
        )
    }
}

/// Triggle when a member update.
class MemberUnbannedEventDTO: EventDTO {
    let user: UserPayload
    let cid: ChannelId
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

        return try? MemberUpdatedEvent(
            user: userDTO.asModel(),
            cid: cid,
            member: memberDTO.asModel(),
            createdAt: createdAt
        )
    }
}

/// Triggered when a member is removed from a channel.
public struct MemberRemovedEvent: MemberEvent, ChannelSpecificEvent {
    /// The user who stopped being a member.
    public let member: ChatUser

    /// The channel identifier a member was removed from.
    public let cid: ChannelId

    /// The event timestamp.
    public let createdAt: Date
}

class MemberRemovedEventDTO: EventDTO {
    let member: MemberPayload
    let cid: ChannelId
    let createdAt: Date
    let payload: EventPayload

    init(from response: EventPayload) throws {
        member = try response.value(at: \.memberContainer?.member)
        cid = try response.value(at: \.cid)
        createdAt = try response.value(at: \.createdAt)
        payload = response
    }

    func toDomainEvent(session: DatabaseSession) -> Event? {
        guard let memberDTO = session.member(userId: member.userId, cid: cid) else { return nil }

        return try? MemberRemovedEvent(
            member: memberDTO.asModel(),
            cid: cid,
            createdAt: createdAt
        )
    }
}

/// Triggered when a member is promoted in a channel.
public struct MemberPromotedEvent: MemberEvent, ChannelSpecificEvent {
    public var memberUserId: UserId {
        return user.id
    }

    /// The user who stopped being a member.
    public let user: ChatUser

    /// The channel identifier a member was removed from.
    public let cid: ChannelId

    /// The event timestamp.
    public let createdAt: Date
}

class MemberPromotedEventDTO: EventDTO {
    let user: UserPayload
    let cid: ChannelId
    let createdAt: Date
    let payload: EventPayload

    init(from response: EventPayload) throws {
        user = try response.value(at: \.user)
        cid = try response.value(at: \.cid)
        createdAt = try response.value(at: \.createdAt)
        payload = response
    }

    func toDomainEvent(session: DatabaseSession) -> Event? {
        guard let userDTO = session.user(id: user.id, projectId: cid.projectId) else { return nil }

        return try? MemberPromotedEvent(
            user: userDTO.asModel(),
            cid: cid,
            createdAt: createdAt
        )
    }
}

/// Triggered when a member is demoted in a channel.
public struct MemberDemotedEvent: MemberEvent, ChannelSpecificEvent {
    public var memberUserId: UserId {
        return user.id
    }

    /// The user who stopped being a member.
    public let user: ChatUser

    /// The channel identifier a member was removed from.
    public let cid: ChannelId

    /// The event timestamp.
    public let createdAt: Date
}

class MemberDemotedEventDTO: EventDTO {
    let user: UserPayload
    let cid: ChannelId
    let createdAt: Date
    let payload: EventPayload

    init(from response: EventPayload) throws {
        user = try response.value(at: \.user)
        cid = try response.value(at: \.cid)
        createdAt = try response.value(at: \.createdAt)
        payload = response
    }

    func toDomainEvent(session: DatabaseSession) -> Event? {
        guard let userDTO = session.user(id: user.id, projectId: cid.projectId) else { return nil }

        return try? MemberDemotedEvent(
            user: userDTO.asModel(),
            cid: cid,
            createdAt: createdAt
        )
    }
}
