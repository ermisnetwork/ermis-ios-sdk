//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// Triggered when a channel is updated.
public struct ChannelUpdatedEvent: ChannelSpecificEvent {
    /// The identifier of updated channel.
    public var cid: ChannelId { channel.cid }

    /// The identifier of updated parrent channel
    public var parentCid: ChannelId? { channel.parentCid }

    /// The updated channel.
    public let channel: Channel

    /// The user who updated the channel.
    public let user: ChatUser?

    /// The message which updated the channel.
    public let message: ChatMessage?

    /// The event timestamp.
    public let createdAt: Date
}

class ChannelUpdatedEventDTO: EventDTO {
    let channel: ChannelDetailPayload
    let user: UserPayload?
    let message: MessagePayload?
    let createdAt: Date
    let payload: EventPayload

    init(from response: EventPayload) throws {
        channel = try response.value(at: \.channel)
        user = try? response.value(at: \.user)
        message = try? response.value(at: \.message)
        createdAt = try response.value(at: \.createdAt)
        payload = response
    }

    func toDomainEvent(session: DatabaseSession) -> Event? {
        guard let channelDTO = session.channel(cid: channel.cid) else { return nil }

        let userDTO = user.flatMap { session.user(id: $0.id, projectId: channel.cid.projectId) }
        let messageDTO = message.flatMap { session.message(id: $0.id) }

        return try? ChannelUpdatedEvent(
            channel: channelDTO.asModel(),
            user: userDTO?.asModel(),
            message: messageDTO?.asModel(),
            createdAt: createdAt
        )
    }
}

/// Triggered when a channel is deleted.
public struct ChannelDeletedEvent: ChannelSpecificEvent {
    /// The identifier of deleted channel.
    public var cid: ChannelId { channel.cid }

    /// The identifier of parent channel of deleted topic.
    public var parentCid: ChannelId? { channel.parentCid }

    /// The deleted channel.
    public let channel: Channel

    /// The user who deleted the channel.
    public let user: ChatUser?

    /// The event timestamp.
    public let createdAt: Date
}

class ChannelDeletedEventDTO: EventDTO {
    let user: UserPayload?
    let createdAt: Date
    let payload: EventPayload
    let cid: ChannelId

    init(from response: EventPayload) throws {
        user = try? response.value(at: \.user)
        createdAt = try response.value(at: \.createdAt)
        cid = try response.value(at: \.cid)
        payload = response
    }

    func toDomainEvent(session: DatabaseSession) -> Event? {
        guard let channelDTO = session.channel(cid: cid) else { return nil }

        let userDTO = user.flatMap { session.user(id: $0.id, projectId: cid.projectId) }

        return try? ChannelDeletedEvent(
            channel: channelDTO.asModel(),
            user: userDTO?.asModel(),
            createdAt: createdAt
        )
    }
}



/// Triggered when a channel is truncated.
public struct ChannelTruncatedEvent: ChannelSpecificEvent {
    /// The identifier of truncated channel.
    public var cid: ChannelId { channel.cid }

    /// The identifier of parent channel of truncated topic.
    public var parentCid: ChannelId? { channel.parentCid }

    /// The truncated channel.
    public let channel: Channel

    /// The user who truncated a channel.
    public let user: ChatUser?

    /// The event timestamp.
    public let createdAt: Date
}

class ChannelTruncatedEventDTO: EventDTO {
    let cid: ChannelId
    let user: UserPayload?
    let createdAt: Date
    let payload: EventPayload

    init(from response: EventPayload) throws {
        cid = try response.value(at: \.cid)
        user = try? response.value(at: \.user)
        createdAt = try response.value(at: \.createdAt)
        payload = response
    }

    func toDomainEvent(session: DatabaseSession) -> Event? {
        guard let channelDTO = session.channel(cid: cid) else { return nil }

        let userDTO = user.flatMap { session.user(id: $0.id, projectId: cid.projectId) }

        return try? ChannelTruncatedEvent(
            channel: channelDTO.asModel(),
            user: userDTO?.asModel(),
            createdAt: createdAt
        )
    }
}

/// Triggered when a channel is made visible.
public struct ChannelVisibleEvent: ChannelSpecificEvent {
    /// The channel identifier.
    public let cid: ChannelId

    /// The parent channel idetifier if this event belong to a topic.
    public let parentCid: ChannelId?

    /// The user who made the channel visible.
    public let user: ChatUser

    /// The event timestamp.
    public let createdAt: Date
}

class ChannelVisibleEventDTO: EventDTO {
    let cid: ChannelId
    let parentCid: ChannelId?
    let user: UserPayload
    let createdAt: Date
    let payload: EventPayload

    init(from response: EventPayload) throws {
        cid = try response.value(at: \.cid)
        parentCid = try? response.value(at: \.parentCid)
        user = try response.value(at: \.user)
        createdAt = try response.value(at: \.createdAt)
        payload = response
    }

    func toDomainEvent(session: DatabaseSession) -> Event? {
        guard let userDTO = session.user(id: user.id, projectId: cid.projectId) else { return nil }

        return try? ChannelVisibleEvent(
            cid: cid,
            parentCid: parentCid,
            user: userDTO.asModel(),
            createdAt: createdAt
        )
    }
}

/// Triggered when a channel is hidden.
public struct ChannelHiddenEvent: ChannelSpecificEvent {
    /// The hidden channel identifier.
    public let cid: ChannelId

    /// The parent channel idetifier if this event belong to a topic.
    public let parentCid: ChannelId?

    /// The user who hide the channel.
    public let user: ChatUser

    /// The flag saying that channel history was cleared.
    public let isHistoryCleared: Bool

    /// The date a channel was hidden.
    public let createdAt: Date
}

class ChannelHiddenEventDTO: EventDTO {
    let cid: ChannelId
    let parentCid: ChannelId?
    let user: UserPayload
    let isHistoryCleared: Bool
    let createdAt: Date
    let payload: EventPayload

    init(from response: EventPayload) throws {
        cid = try response.value(at: \.cid)
        parentCid = try? response.value(at: \.cid)
        createdAt = try response.value(at: \.createdAt)
        user = try response.value(at: \.user)
        isHistoryCleared = (try? response.value(at: \.isChannelHistoryCleared)) ?? false
        payload = response
    }

    func toDomainEvent(session: DatabaseSession) -> Event? {
        guard let userDTO = session.user(id: user.id, projectId: cid.projectId) else { return nil }

        return try? ChannelHiddenEvent(
            cid: cid,
            parentCid: parentCid,
            user: userDTO.asModel(),
            isHistoryCleared: isHistoryCleared,
            createdAt: createdAt
        )
    }
}

class ChannelPinnedEventDTO: EventDTO {
    let cid: ChannelId
    let parentCid: ChannelId?
    let createdAt: Date
    let user: UserPayload
    let payload: EventPayload

    init(from response: EventPayload) throws {
        cid = try response.value(at: \.cid)
        parentCid = try? response.value(at: \.parentCid)
        createdAt = try response.value(at: \.createdAt)
        user = try response.value(at: \.user)
        payload = response
    }

    func toDomainEvent(session: DatabaseSession) -> Event? {
        guard let userDTO = session.user(id: user.id, projectId: cid.projectId) else { return nil }

        return try? ChannelPinnedEvent(
            cid: cid,
            parentCid: parentCid,
            user: userDTO.asModel(),
            isPinned: true,
            createdAt: createdAt
        )
    }
}

class ChannelUnpinnedEventDTO: EventDTO {
    let cid: ChannelId
    let parentCid: ChannelId?
    let createdAt: Date
    let user: UserPayload
    let payload: EventPayload

    init(from response: EventPayload) throws {
        cid = try response.value(at: \.cid)
        parentCid = try? response.value(at: \.parentCid)
        createdAt = try response.value(at: \.createdAt)
        user = try response.value(at: \.user)
        payload = response
    }

    func toDomainEvent(session: DatabaseSession) -> Event? {
        guard let userDTO = session.user(id: user.id, projectId: cid.projectId) else { return nil }

        return try? ChannelPinnedEvent(
            cid: cid,
            parentCid: parentCid,
            user: userDTO.asModel(),
            isPinned: false,
            createdAt: createdAt
        )
    }
}

/// Triggered when a channel is hidden.
public struct ChannelPinnedEvent: ChannelSpecificEvent {
    /// The hidden channel identifier.
    public let cid: ChannelId
    
    /// The parent channel identifier, if applicable.
    public let parentCid: ChannelId?

    /// The user who pinned the channel.
    public let user: ChatUser

    /// Is channel pinned or unpinned
    public let isPinned: Bool

    /// The date a channel was hidden.
    public let createdAt: Date
}

class ChannelTopicEnableEventDTO: EventDTO {
    let cid: ChannelId
    let parentCid: ChannelId?
    let createdAt: Date
    let user: UserPayload
    let payload: EventPayload

    init(from response: EventPayload) throws {
        cid = try response.value(at: \.cid)
        parentCid = try? response.value(at: \.parentCid)
        createdAt = try response.value(at: \.createdAt)
        user = try response.value(at: \.user)
        payload = response
    }

    func toDomainEvent(session: DatabaseSession) -> Event? {
        guard let userDTO = session.user(id: user.id, projectId: cid.projectId) else { return nil }

        return try? ChannelEnableTopicEvent(
            cid: cid,
            parentCid: parentCid,
            user: userDTO.asModel(),
            isEnableTopic: true,
            createdAt: createdAt
        )
    }
}


class ChannelTopicDisableEventDTO: EventDTO {
    let cid: ChannelId
    let parentCid: ChannelId?
    let createdAt: Date
    let user: UserPayload
    let payload: EventPayload

    init(from response: EventPayload) throws {
        cid = try response.value(at: \.cid)
        parentCid = try? response.value(at: \.cid)
        createdAt = try response.value(at: \.createdAt)
        user = try response.value(at: \.user)
        payload = response
    }

    func toDomainEvent(session: DatabaseSession) -> Event? {
        guard let userDTO = session.user(id: user.id, projectId: cid.projectId) else { return nil }

        return try? ChannelEnableTopicEvent(
            cid: cid,
            parentCid: parentCid,
            user: userDTO.asModel(),
            isEnableTopic: false,
            createdAt: createdAt
        )
    }
}

/// Triggered when a channel is enable / disable topic.
public struct ChannelEnableTopicEvent: ChannelSpecificEvent {
    /// The hidden channel identifier.
    public let cid: ChannelId

    /// The parent channel idetifier if this event belong to a topic.
    public let parentCid: ChannelId?

    /// The user who enabled topic of  the channel.
    public let user: ChatUser

    /// Is topic enabled or disabled
    public let isEnableTopic: Bool

    /// The date a channel was hidden.
    public let createdAt: Date
}

class ChannelTopicCreatedEventDTO: EventDTO {
    let cid: ChannelId
    let parentCid: ChannelId
    let channelId: String
    let channelType: ChannelType
    let createdAt: Date
    let user: UserPayload
    let channel: ChannelDetailPayload
    let payload: EventPayload

    init(from response: EventPayload) throws {
        cid = try response.value(at: \.cid)
        createdAt = try response.value(at: \.createdAt)
        user = try response.value(at: \.user)
        parentCid = try response.value(at: \.parentCid)
        channelId = try response.value(at: \.channelId)
        channelType = try response.value(at: \.channelType)
        channel = try response.value(at: \.channel)
        payload = response
    }

    func toDomainEvent(session: DatabaseSession) -> Event? {
        
        guard let channelDTO = session.channel(cid: channel.cid),
              let userDTO = session.user(id: user.id, projectId: cid.projectId) else { return nil }

        return try? ChannelTopicCreatedEvent(cid: cid,
                                             parentCid: parentCid,
                                             user: userDTO.asModel(),
                                             channelId: channelId,
                                             channelType: channelType,
                                             channel: channelDTO.asModel(),
                                             createdAt: createdAt)
    }
}

public struct ChannelTopicCreatedEvent: TopicSpecificEvent {
    /// The channel identifier.
    /// The hidden channel identifier.
    public let cid: ChannelId
    
    public let parentCid: ChannelId

    /// The user who enabled topic of  the channel.
    public let user: ChatUser
    
    public let channelId: String
    
    public let channelType: ChannelType
    
    public let channel: Channel

    /// The date a channel was hidden.
    public let createdAt: Date
}


class ChannelTopicClosedEventDTO: TopicSpecificEvent {
    let cid: ChannelId
    let parentCid: ChannelId
    let channelId: String
    let channelType: ChannelType
    let createdAt: Date
    let user: UserPayload
    let payload: EventPayload

    init(from response: EventPayload) throws {
        cid = try response.value(at: \.cid)
        createdAt = try response.value(at: \.createdAt)
        user = try response.value(at: \.user)
        parentCid = try response.value(at: \.parentCid)
        channelId = try response.value(at: \.channelId)
        channelType = try response.value(at: \.channelType)
        payload = response
    }

    func toDomainEvent(session: DatabaseSession) -> Event? {
        
        guard let channelDTO = session.channel(cid: cid),
              let userDTO = session.user(id: user.id, projectId: cid.projectId) else { return nil }

        return try? ChannelTopicClosedEvent(cid: cid,
                                             parentCid: parentCid,
                                             user: userDTO.asModel(),
                                             channelId: channelId,
                                             channelType: channelType,
                                             createdAt: createdAt)
    }
}

public struct ChannelTopicClosedEvent: TopicSpecificEvent {
    /// The channel identifier.
    /// The hidden channel identifier.
    public let cid: ChannelId
    
    public let parentCid: ChannelId
    
    /// The user who enabled topic of  the channel.
    public let user: ChatUser
    
    public let channelId: String
    
    public let channelType: ChannelType
    
    /// The date a channel was hidden.
    public let createdAt: Date
}


class ChannelTopicReopenedEventDTO: TopicSpecificEvent {
    let cid: ChannelId
    let parentCid: ChannelId
    let channelId: String
    let channelType: ChannelType
    let createdAt: Date
    let user: UserPayload
    let payload: EventPayload

    init(from response: EventPayload) throws {
        cid = try response.value(at: \.cid)
        createdAt = try response.value(at: \.createdAt)
        user = try response.value(at: \.user)
        parentCid = try response.value(at: \.parentCid)
        channelId = try response.value(at: \.channelId)
        channelType = try response.value(at: \.channelType)
        payload = response
    }

    func toDomainEvent(session: DatabaseSession) -> Event? {
        
        guard let channelDTO = session.channel(cid: cid),
              let userDTO = session.user(id: user.id, projectId: cid.projectId) else { return nil }

        return try? ChannelTopicReopenedEvent(cid: cid,
                                             parentCid: parentCid,
                                             user: userDTO.asModel(),
                                             channelId: channelId,
                                             channelType: channelType,
                                             createdAt: createdAt)
    }
}

public struct ChannelTopicReopenedEvent: TopicSpecificEvent {
    /// The channel identifier.
    /// The hidden channel identifier.
    public let cid: ChannelId
    
    public let parentCid: ChannelId
    
    /// The user who enabled topic of  the channel.
    public let user: ChatUser
    
    public let channelId: String
    
    public let channelType: ChannelType
    
    /// The date a channel was hidden.
    public let createdAt: Date
}
