//
// Copyright 2025 Ermis Inc.
//

import Foundation

// MARK: - Temporary

/// The DTO object mirroring the JSON representation of an event.
class EventPayload: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case eventType = "type"
        case connectionId = "connection_id"
        case cid
        case parentCid = "parent_cid"
        case topicCids = "topic_cids"
        case channelType = "channel_type"
        case channelId = "channel_id"
        case currentUser = "me"
        case user
        case userId = "user_id"
        case createdBy = "created_by"
        case memberContainer = "member"
        case channel
        case message
        case reaction
        case watcherCount = "watcher_count"
        case createdAt = "created_at"
        case isChannelHistoryCleared = "clear_history"
        case banReason = "reason"
        case banExpiredAt = "expiration"
        case parentId = "parent_id"
        case hardDelete = "hard_delete"
        case firstUnreadMessageId = "first_unread_message_id"
        case lastReadAt = "last_read_at"
        case lastReadMessageId = "last_read_message_id"
        case unreadMessagesCount = "unread_messages"
        case shadow
        case projectId = "project_id"
        case sessionId = "session_id"
        case callId = "call_id"
        case signal = "signal"
        case isVideo = "is_video"
        case callAction = "action"
    }

    let eventType: EventType
    let connectionId: String?
    let cid: ChannelId?
    let parentCid: ChannelId?
    let channelType: ChannelType?
    let channelId: String?
    let currentUser: CurrentUserPayload?
    let user: UserPayload?
    let userId: String?
    let createdBy: UserPayload?
    let memberContainer: MemberContainerPayload?
    let channel: ChannelDetailPayload?
    let message: MessagePayload?
    let reaction: MessageReactionPayload?
    let watcherCount: Int?
    let unreadCount: UnreadCount?
    let createdAt: Date?
    let isChannelHistoryCleared: Bool?
    let banReason: String?
    let banExpiredAt: Date?
    let parentId: MessageId?
    let topicCids: [ChannelId]?
    let hardDelete: Bool
    let shadow: Bool?
    // Mark as unread properties
    let firstUnreadMessageId: MessageId?
    let lastReadMessageId: MessageId?
    let lastReadAt: Date?
    let unreadMessagesCount: Int?
    let projectId: String
    let sessionId: String?
    let callId: String?
    let isVideo: Bool?
    let signal: CallSignal?
    let callAction: CallAction?
    init(
        eventType: EventType,
        connectionId: String? = nil,
        cid: ChannelId? = nil,
        parentCid: ChannelId? = nil,
        topicCids: [ChannelId] = [],
        channelType: ChannelType? = nil,
        channelId: String? = nil,
        projectId: String = "",
        currentUser: CurrentUserPayload? = nil,
        user: UserPayload? = nil,
        userId: String? = nil,
        createdBy: UserPayload? = nil,
        memberContainer: MemberContainerPayload? = nil,
        channel: ChannelDetailPayload? = nil,
        message: MessagePayload? = nil,
        reaction: MessageReactionPayload? = nil,
        watcherCount: Int? = nil,
        unreadCount: UnreadCount? = nil,
        createdAt: Date? = nil,
        isChannelHistoryCleared: Bool? = nil,
        banReason: String? = nil,
        banExpiredAt: Date? = nil,
        parentId: MessageId? = nil,
        hardDelete: Bool = false,
        shadow: Bool? = nil,
        firstUnreadMessageId: MessageId? = nil,
        lastReadAt: Date? = nil,
        lastReadMessageId: MessageId? = nil,
        unreadMessagesCount: Int? = nil,
        sessionId: String? = nil,
        callId: String? = nil,
        isVideo: Bool? = nil,
        signal: CallSignal? = nil,
        callAction: CallAction? = nil
    ) {
        self.eventType = eventType
        self.connectionId = connectionId
        self.cid = cid
        self.parentCid = parentCid
        self.topicCids = topicCids
        self.projectId = projectId
        self.currentUser = currentUser
        self.user = user
        self.userId = userId
        self.createdBy = createdBy
        self.memberContainer = memberContainer
        self.channel = channel
        self.message = message
        self.reaction = reaction
        self.watcherCount = watcherCount
        self.unreadCount = unreadCount
        self.createdAt = createdAt
        self.isChannelHistoryCleared = isChannelHistoryCleared
        self.banReason = banReason
        self.banExpiredAt = banExpiredAt
        self.parentId = parentId
        self.hardDelete = hardDelete
        self.shadow = shadow
        self.firstUnreadMessageId = firstUnreadMessageId
        self.lastReadAt = lastReadAt
        self.lastReadMessageId = lastReadMessageId
        self.unreadMessagesCount = unreadMessagesCount
        self.sessionId = sessionId
        self.callId = callId
        self.isVideo = isVideo
        self.signal = signal
        self.callAction = callAction
        self.channelType = channelType
        self.channelId = channelId
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventType = try container.decode(EventType.self, forKey: .eventType)
        connectionId = try container.decodeIfPresent(String.self, forKey: .connectionId)
        // In healthCheck event we can receive invalid id containing "*".
        // We don't need to throw error in that case and can treat it like missing cid.
        cid = try? container.decodeIfPresent(ChannelId.self, forKey: .cid)
        currentUser = try container.decodeIfPresent(CurrentUserPayload.self, forKey: .currentUser)
        user = try container.decodeIfPresent(UserPayload.self, forKey: .user)
        userId = try container.decodeIfPresent(String.self, forKey: .userId)
        projectId = try container.decodeIfPresent(String.self, forKey: .projectId) ?? ""
        createdBy = try container.decodeIfPresent(UserPayload.self, forKey: .createdBy)
        memberContainer = try container.decodeIfPresent(MemberContainerPayload.self, forKey: .memberContainer)
        channel = try? container.decodeIfPresent(ChannelDetailPayload.self, forKey: .channel)
        message = try container.decodeIfPresent(MessagePayload.self, forKey: .message)
        reaction = try container.decodeIfPresent(MessageReactionPayload.self, forKey: .reaction)
        watcherCount = try container.decodeIfPresent(Int.self, forKey: .watcherCount)
        unreadCount = try? UnreadCount(from: decoder)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        isChannelHistoryCleared = try container.decodeIfPresent(Bool.self, forKey: .isChannelHistoryCleared)
        banReason = try container.decodeIfPresent(String.self, forKey: .banReason)
        banExpiredAt = try container.decodeIfPresent(Date.self, forKey: .banExpiredAt)
        parentId = try container.decodeIfPresent(MessageId.self, forKey: .parentId)
        hardDelete = try container.decodeIfPresent(Bool.self, forKey: .hardDelete) ?? true
        shadow = try container.decodeIfPresent(Bool.self, forKey: .shadow)
        firstUnreadMessageId = try container.decodeIfPresent(MessageId.self, forKey: .firstUnreadMessageId)
        lastReadAt = try container.decodeIfPresent(Date.self, forKey: .lastReadAt)
        lastReadMessageId = try container.decodeIfPresent(MessageId.self, forKey: .lastReadMessageId)
        unreadMessagesCount = try container.decodeIfPresent(Int.self, forKey: .unreadMessagesCount)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        callId = try container.decodeIfPresent(String.self, forKey: .callId)
        isVideo = try container.decodeIfPresent(Bool.self, forKey: .isVideo)
        signal = try container.decodeIfPresent(CallSignal.self, forKey: .signal)
        callAction = try container.decodeIfPresent(CallAction.self, forKey: .callAction)
        parentCid = try container.decodeIfPresent(ChannelId.self, forKey: .parentCid)
        topicCids = try container.decodeIfPresent([ChannelId].self, forKey: .topicCids)
        channelType = try container.decodeIfPresent(ChannelType.self, forKey: .channelType)
        channelId = try container.decodeIfPresent(String.self, forKey: .channelId)
    }

    func event() throws -> Event {
        try eventType.event(from: self)
    }

    func getProjectId() -> String {
        return cid?.projectId ?? projectId
    }
}

private extension PartialKeyPath where Root == EventPayload {
    var stringValue: String {
        switch self {
        case \EventPayload.eventType: return "eventType"
        case \EventPayload.connectionId: return "connectionId"
        case \EventPayload.cid: return "cid"
        case \EventPayload.parentCid: return "parentCid"
        case \EventPayload.topicCids: return "topicCids"
        case \EventPayload.currentUser: return "currentUser"
        case \EventPayload.user: return "user"
        case \EventPayload.createdBy: return "createdBy"
        case \EventPayload.memberContainer: return "memberContainer"
        case \EventPayload.channel: return "channel"
        case \EventPayload.message: return "message"
        case \EventPayload.reaction: return "reaction"
        case \EventPayload.watcherCount: return "watcherCount"
        case \EventPayload.unreadCount: return "unreadCount"
        case \EventPayload.createdAt: return "createdAt"
        case \EventPayload.isChannelHistoryCleared: return "isChannelHistoryCleared"
        case \EventPayload.banReason: return "banReason"
        case \EventPayload.banExpiredAt: return "banExpiredAt"
        case \EventPayload.parentId: return "parentId"
        case \EventPayload.hardDelete: return "hardDelete"
        case \EventPayload.shadow: return "shadow"
        case \EventPayload.signal: return "signal"
        case \EventPayload.callAction: return "action"
        default: return String(describing: self)
        }
    }
}

extension EventPayload {
    /// Get an unwrapped value from the payload or throw an error.
    func value<Value>(at keyPath: KeyPath<EventPayload, Value?>) throws -> Value {
        guard let value = self[keyPath: keyPath] else {
            throw ClientError.EventDecoding(missingValue: keyPath.stringValue, for: eventType)
        }

        return value
    }
}

extension Array where Element == EventPayload {
    /// Decodes events from event payloads. If decoding of some event fails the error is logged without interrupting the chain.
    ///
    /// - Returns: The array of successfully decoded events.
    func asEvents() -> [Event] {
        compactMap {
            do {
                return try $0.event()
            } catch {
                if error is ClientError.IgnoredEventType {
                    log.info("Skipping unsupported event type: \($0.eventType)")
                } else {
                    log.error("Failed to decode event from event payload: \($0), error: \(error)")
                }
                return nil
            }
        }
    }
}
