//
// Copyright 2025 Ermis Inc.
//

import Foundation

extension Endpoint {
    /// Create the endpoint to get channel list with a query.
    ///
    /// - Parameters:
    ///   - query: The `ChannelListQuery` to filter channel.
    /// - Returns: The endpoint to get channel list.
    static func channels(query: ChannelListQuery) -> Endpoint<ChannelListPayload> {
        return .init(
            path: .channels,
            method: .post,
            query: nil,
            body: query
        )
    }

    /// Create the endpoint to create channel.
    ///
    /// - Parameters:
    ///   - query: The `ChannelQuery` to create channel.
    /// - Returns: The endpoint to create new channel.
    static func createChannel(query: ChannelQuery) -> Endpoint<ChannelPayload> {
        createOrUpdateChannel(path: .createChannel(query.apiPath), query: query)
    }

    /// Create the endpoint for update channel.
    ///
    /// - Parameters:
    ///   - query: The `ChannelQuery` to update channel.
    /// - Returns: The endpoint to update the channel.
    static func updateChannel(query: ChannelQuery) -> Endpoint<ChannelPayload> {
        createOrUpdateChannel(path: .updateChannel(query.apiPath), query: query)
    }

    /// Create the endpoint for create or update channel.
    ///
    /// - Parameters:
    ///   - path: If we want to create a new channel, using `createChannel` path.
    ///   And using `updateChannel` path for update channel.
    ///   - query: The `ChannelQuery` to create or update channel.
    /// - Returns: The endpoint to create or update the channel.
    private static func createOrUpdateChannel(path: EndpointPath, query: ChannelQuery) -> Endpoint<ChannelPayload> {
        .init(
            path: path,
            method: .post,
            query: nil,
            body: query,
            needConnectionId: true
        )
    }

    /// Create the endpoint for update channel detail.
    ///
    /// - Parameters:
    ///   - channelPayload: The new detail of channel for update.
    /// - Returns: The endpoint to update the channel detail.
    static func updateChannel(channelPayload: ChannelEditDetailPayload)
    -> Endpoint<ChannelPayload> {
        return .init(
            path: .channelDetailUpdate(cid: channelPayload.cid!),
            method: .post,
            query: nil,
            body: [
                "data": channelPayload
            ]
        )
    }

    /// Create the endpoint for delete channel.
    ///
    /// - Parameters:
    ///   - cid: The identifier of channel.
    /// - Returns: The endpoint to delete the channel.
    static func deleteChannel(cid: ChannelId) -> Endpoint<EmptyResponse> {
        .init(
            path: .deleteChannel(cid.apiPath),
            method: .delete,
            body: nil
        )
    }

    /// Create the endpoint for delete all messages of the channel..
    ///
    /// - Parameters:
    ///   - cid: The identifier of channel.
    /// - Returns: The endpoint to delete  all messages of the channel.
    static func truncatedChannel(cid: ChannelId) -> Endpoint<EmptyResponse> {
        .init(path: .truncatedChannel(channelId: cid),
              method: .delete,
              body: nil)
    }

    /// Create the endpoint to send a message to channel.
    ///
    /// - Parameters:
    ///   - cid: The channel identifier.
    ///   - messagePayload: the message payload to send.
    /// - Returns: The endpoint to send a message to channel.
    static func sendMessage(cid: ChannelId, messagePayload: MessageRequestBody)
    -> Endpoint<MessagePayload.Boxed> {
        let body: [String: AnyEncodable] = [
            "message": AnyEncodable(messagePayload),
        ]
        return .init(
            path: .sendMessage(cid),
            method: .post,
            body: body
        )
    }

    /// Create the endpoint to add members to channel.
    ///
    /// - Parameters:
    ///   - cid: The channel identifier.
    ///   - userIds: The list of user identifier to add.
    /// - Returns: The endpoint to add members to channel.
    static func addMembers(
        cid: ChannelId,
        userIds: Set<UserId>
    ) -> Endpoint<EmptyResponse> {
        var body: [String: AnyEncodable] = [
            "add_members": AnyEncodable(userIds),
        ]
        return .init(
            path: .channelUpdate(cid.apiPath),
            method: .post,
            body: body
        )
    }

    /// Create the endpoint to remove channel members.
    ///
    /// - Parameters:
    ///   - cid: The channel identifier.
    ///   - userIds: The list of user identifier to remove.
    /// - Returns: The endpoint to remove channel members.
    static func removeMembers(
        cid: ChannelId,
        userIds: Set<UserId>
    ) -> Endpoint<EmptyResponse> {
        let body = [
            "remove_members": AnyEncodable(userIds)
        ]
        return .init(
            path: .channelUpdate(cid.apiPath),
            method: .post,
            body: body
        )
    }

    /// Create the endpoint to accept invitation to direct channel.
    ///
    /// - Parameters:
    ///   - cid: The channel identifier.
    /// - Returns: The endpoint to accept invitation to a direct channel.
    static func acceptInvite(cid: ChannelId) -> Endpoint<EmptyResponse> {
        .init(
            path: .joinChannel(channelType: cid.type.rawValue),
            method: .post,
            query: [
                "channel_id": cid.id,
                "action": "accept"
            ],
            needConnectionId: true,
            isAuth: true
        )
    }

    /// Create the endpoint to skip invitation to direct channel.
    ///
    /// - Parameters:
    ///   - cid: The channel identifier.
    /// - Returns: The endpoint to skip invitation to a direct channel.
    static func skipInvite(cid: ChannelId) -> Endpoint<EmptyResponse> {
        .init(
            path: .invite(cid: cid,
                          type: "skip"),
            method: .post
        )
    }

    /// Create the endpoint to reject invitation to direct channel.
    ///
    /// - Parameters:
    ///   - cid: The channel identifier.
    /// - Returns: The endpoint to reject invitation to a direct channel.
    static func rejectInvite(cid: ChannelId) -> Endpoint<EmptyResponse> {
        .init(
            path: .invite(cid: cid,
                          type: "reject"),
            method: .post
        )
    }

    /// Create the endpoint to join a public channel.
    ///
    /// - Parameters:
    ///   - cid: The channel identifier.
    /// - Returns: The endpoint to join a public channel.
    static func joinPublicChannel(cid: ChannelId) -> Endpoint<EmptyResponse> {
        .init(
            path: .joinChannel(channelType: cid.type.rawValue),
            method: .post,
            query: [
                "channel_id": cid.id,
                "action": "join"
            ],
            needConnectionId: true,
            isAuth: true
        )
    }

    /// Create the endpoint to mark a channel as read.
    ///
    /// - Parameters:
    ///   - cid: The channel identifier.
    ///   - messageId: The message id to mark read.
    /// - Returns: The endpoint to mark a channel as read.
    static func markRead(cid: ChannelId, messageId: String?) -> Endpoint<EmptyResponse> {
        .init(
            path: .markChannelRead(cid.apiPath, messageId),
            method: .post
        )
    }

    /// Create the endpoint to mark a channel as read.
    ///
    /// - Parameters:
    ///   - cid: The channel identifier.
    ///   - messageId: The message id to mark read.
    ///   - userId: The user identifier.
    /// - Returns: The endpoint to mark a channel as read.
    static func markUnread(cid: ChannelId, messageId: MessageId, userId: UserId) -> Endpoint<EmptyResponse> {
        .init(
            path: .markChannelUnread(cid.apiPath),
            method: .post,
            body: [
                "message_id": messageId,
                "user_id": userId
            ]
        )
    }

    /// Create the endpoint to mark all channels as read.
    ///
    /// - Returns: The endpoint to mark all channels as read.
    static func markAllRead() -> Endpoint<EmptyResponse> {
        .init(
            path: .markAllChannelsRead,
            method: .post
        )
    }

    /// Create the endpoint to send typing event.
    ///
    /// - Parameters:
    ///   - cid: The channel identifier.
    ///   - parentMessageId: The parent message id.
    /// - Returns: The endpoint to send typing event.
    static func startTypingEvent(cid: ChannelId, parentMessageId: MessageId?) -> Endpoint<EmptyResponse> {
        let eventType = EventType.userStartTyping
        let body: Encodable
        if let parentMessageId = parentMessageId {
            body = ["event": ["type": eventType.rawValue, "parent_id": parentMessageId]]
        } else {
            body = ["event": ["type": eventType]]
        }
        return .init(
            path: .channelEvent(cid.apiPath),
            method: .post,
            body: body
        )
    }

    /// Create the endpoint to send stop typing event.
    ///
    /// - Parameters:
    ///   - cid: The channel identifier.
    ///   - parentMessageId: The parent message id.
    /// - Returns: The endpoint to send stop typing event.
    static func stopTypingEvent(cid: ChannelId, parentMessageId: MessageId?) -> Endpoint<EmptyResponse> {
        let eventType = EventType.userStopTyping
        let body: Encodable
        if let parentMessageId = parentMessageId {
            body = ["event": ["type": eventType.rawValue, "parent_id": parentMessageId]]
        } else {
            body = ["event": ["type": eventType]]
        }
        return .init(
            path: .channelEvent(cid.apiPath),
            method: .post,
            body: body
        )
    }

    /// Create the endpoint to set cooldown duration for a channel.
    ///
    /// - Parameters:
    ///   - cid: The channel identifier.
    ///   - cooldownDuration: The cooldown duration value.
    /// - Returns: The endpoint to set cooldown duration for a channel.
    static func coolDownDuration(cid: ChannelId, cooldownDuration: Int) -> Endpoint<EmptyResponse> {
        .init(
            path: .channelUpdate(cid.apiPath),
            method: .post,
            body: ["data": ["member_message_cooldown": cooldownDuration]]
        )
    }

    static func stopWatching(cid: ChannelId) -> Endpoint<EmptyResponse> {
        .init(
            path: .stopWatchingChannel(cid.apiPath),
            method: .post,
            needConnectionId: true
        )
    }

    static func channelWatchers(query: ChannelWatcherListQuery) -> Endpoint<ChannelPayload> {
        .init(
            path: .updateChannel(query.cid.apiPath),
            method: .post,
            body: query,
            needConnectionId: true
        )
    }

    /// Create the endpoint to promote members to moder.
    ///
    /// - Parameters:
    ///   - cid: The channel identifier.
    ///   - memberIds: The list of member identifier to promote.
    /// - Returns: The endpoint to promote members to moder.
    static func promoteMembers(cid: ChannelId, memberIds: [String]) -> Endpoint<EmptyResponse> {
        .init(
            path: .channelDetailUpdate(cid: cid),
            method: .post,
            body: [
                "promote_members": memberIds
            ],
            needConnectionId: true
        )
    }

    /// Create the endpoint to demote moder to member.
    ///
    /// - Parameters:
    ///   - cid: The channel identifier.
    ///   - memberIds: The list of member identifier to demote.
    /// - Returns: The endpoint to demote moder to member.
    static func demoteMembers(cid: ChannelId, memberIds: [String]) -> Endpoint<EmptyResponse> {
        .init(path: .channelDetailUpdate(cid: cid),
              method: .post,
              body: ["demote_members": memberIds])
    }

    /// Create the endpoint to update capabilities of channel members.
    ///
    /// - Parameters:
    ///   - cid: The channel identifier.
    ///   - capabilities: New capabilities for channel members.
    /// - Returns: The endpoint to update capabilities of channel members.
    static func updateChannelCapabilities(cid: ChannelId,
                                          capabilities: [String]) -> Endpoint<ChannelPayload> {
        .init(path: .channelDetailUpdate(cid: cid),
              method: .post,
              body: [
                "capabilities": capabilities
              ]
        )
    }

    /// Create the endpoint to get list of attachment in a channel.
    ///
    /// - Parameters:
    ///   - cid: The channel identifier.
    ///   - body: The `ChannelAttachmentRequestBody` intance.
    /// - Returns: The endpoint to get list of attachment in a channel.
    static func channelAttachment(cid: ChannelId, body: ChannelAttachmentRequestBody) -> Endpoint<ChannelAttachmentListPayload> {
        .init(path: .getAttachments(cid: cid),
              method: .post,
              body: body)
    }

    /// Create the endpoint to search message in a channel.
    ///
    /// - Parameters:
    ///   - body: The `ChannelSearchRequestPayload` intance.
    /// - Returns: The endpoint to search message in a channel.
    static func channelSearch(body: ChannelSearchRequestPayload) -> Endpoint<ChannelSearchResultPayload> {
        .init(
            path: .channelSearch,
            method: .post,
            body: body,
            needToken: true
        )
    }

    /// Create the endpoint to search public channel.
    ///
    /// - Parameters:
    ///   - body: The `ChannelPublicSearchRequestBody` intance.
    /// - Returns: The endpoint to search public channel.
    static func channelPublicSearch(body: ChannelPublicSearchRequestBody) -> Endpoint<ChannelListPublicSearchPayload.Boxed> {
        .init(path: .channelPublicSearch,
              method: .post,
              body: body,
              needToken: true)
    }

    /// Create the endpoint to get list member of a channel.
    ///
    /// - Parameters:
    ///   - query: The `ChannelMemberListQuery` intance.
    /// - Returns: The endpoint to get list member of a channel.
    static func channelMembers(
        query: ChannelMemberListQuery
    ) -> Endpoint<ChannelMemberListPayload> {
        .init(
            path: .members,
            method: .get,
            body: ["payload": query]
        )
    }

    /// Create the endpoint to block/unblock a channel.
    ///
    /// - Parameters:
    ///   - cid: The channel identifier.
    ///   - isBlocked: Boolean value true if user want to block a channel and otherwise.
    /// - Returns: The endpoint to block/unblock a channel.
    static func blockChannel(cid: ChannelId, isBlocked: Bool) -> Endpoint<ChannelPayload> {
        .init(
            path: .channelDetailUpdate(cid: cid),
            method: .post,
            body: [
                "action": isBlocked ? "block" : "unblock"
            ]
        )
    }

    /// Create the endpoint to mute/unmute a channel.
    ///
    /// - Parameters:
    ///   - cid: The channel identifier.
    ///   - muteType: Mute type want to set for channel.
    /// - Returns: The endpoint to mute/unMute a channel.
    static func muteChannel(cid: ChannelId, muteType: ChannelMuteType) -> Endpoint<EmptyResponse> {
        return .init(
            path: .muteChannel(channelId: cid),
            method: .post,
            query: nil,
            body: ChannelMutepayload(from: muteType),
            needConnectionId: true
        )
    }

    /// Create the endpoint to pin/unPin a channel.
    ///
    /// - Parameters:
    ///   - cid: The channel identifier.
    ///   - isPinned: The boolean value, `true` if we want to pin the channel with given `cid`.
    /// - Returns: The endpoint to pin/unpin a channel.
    static func pinnedChannel(cid: ChannelId, isPinned: Bool) -> Endpoint<EmptyResponse> {
        return .init(
            path: isPinned ? .pinChannel(channelId: cid) : .unPinChannel(channelId: cid),
            method: .post,
            query: nil,
            body: nil,
            needConnectionId: true
        )
    }
    
    /// Create the endpoint to enable/disable topics in a channel.
    /// /// - Parameters:
    ///  - cid: The channel identifier.
    ///  - isEnable: The boolean value, `true` if we want to enable topics in the channel with given `cid`.
    ///  /// - Returns: The endpoint to enable/disable topics in a channel.
    static func enableTopic(cid: ChannelId,
                            projectId: String,
                            isEnable: Bool) -> Endpoint<EmptyResponse> {
        return .init(
            path: isEnable ? .enableTopics(channelId: cid) : .disableTopics(channelId: cid),
            method: .post,
            query: nil,
            body: [
                "project_id": projectId,
            ],
            needConnectionId: true
        )
    }
    
    static func closeTopic(cid: ChannelId, data: CloseAndReopenTopic) -> Endpoint<EmptyResponse> {
        return .init(
            path: .closeTopic(channelId: cid),
            method: .post,
            query: nil,
            body: data,
            needConnectionId: true
        )
    }
    
    static func reopenTopic(cid: ChannelId, data: CloseAndReopenTopic) -> Endpoint<EmptyResponse> {
        return .init(
            path: .reopenTopic(channelId: cid),
            method: .post,
            query: nil,
            body: data,
            needConnectionId: true
        )
    }
    
    /// Create the endpoint to create channel.
    ///
    /// - Parameters:
    ///   - query: The `ChannelQuery` to create channel.
    /// - Returns: The endpoint to create new channel.
    static func createTopic(isUpdate: Bool, query: ChannelQuery) -> Endpoint<ChannelPayload> {
        return createOrUpdateTopic(path: isUpdate ? .editTopic(query.apiPath) : .createTopic(query.apiPath), query: query)
    }
    
    
    /// Create the endpoint for update topic.
    ///
    /// - Parameters:
    ///  - path: If we want to create a new topic, using `createTopic` path.
    ///  - query: The `ChannelQuery` to update topic.
    ///  - Returns: The endpoint to update the topic.
    private static func createOrUpdateTopic(path: EndpointPath, query: ChannelQuery) -> Endpoint<ChannelPayload> {
        .init(
            path: path,
            method: .post,
            query: nil,
            body: query,
            needConnectionId: true
        )
    }
}
