//
// Copyright 2025 Ermis Inc.
//

import Foundation

extension Endpoint {
    /// Create the endpoint to fetch a message.
    ///
    /// - Parameters:
    ///   - messageId: The message's identifier.
    /// - Returns: The endpoint to fetch a message.
    static func getMessage(messageId: MessageId) -> Endpoint<MessagePayload.Boxed> {
        .init(
            path: .message(messageId),
            method: .get
        )
    }

    /// Create the endpoint to delete a message in a channel.
    ///
    /// - Parameters:
    ///   - message: The `ChatMessage` instance to delete.
    ///   - cid: The channel identifier.
    ///   - onlyForMe: The `Boolean` value, true if delete only for me, otherwhise delete for all users.
    /// - Returns: The endpoint to delete message in a channel.
    static func deleteMessage(message: ChatMessage, cid: ChannelId, onlyForMe: Bool) -> Endpoint<MessagePayload.Boxed> {

        .init(
            path: .deleteMessage(message.id, cid),
            method: .delete,
            query: [
                "for_me": onlyForMe ? "true" : "false"
            ],
            body: UpdateMessageRequestBody(chatMessage: message)
        )
    }

    /// Create the endpoint to edit a message in a channel.
    ///
    /// - Parameters:
    ///   - payload: The edited message payload.
    ///   - message: The message before edit.
    ///   - cid: The channel identifier.
    /// - Returns: The endpoint to edit a message in a channel.
    static func editMessage(payload: MessageRequestBody,
                            oldMessage: MessageRequestBody?,
                            channelId: ChannelId)
        -> Endpoint<EmptyResponse> {
        .init(
            path: .editMessage(payload.id, channelId),
            method: .post,
            body: ["message": payload,
                   "old_message": oldMessage]
        )
    }

    /// Create the endpoint to fetch reply messages of a message.
    ///
    /// - Parameters:
    ///   - messageId: The message identifier.
    ///   - pagination: The `MessagesPagination` instance provide infomation about pagination.
    /// - Returns: The endpoint to fetch reply messages of a message.
    static func loadReplies(messageId: MessageId, pagination: MessagesPagination)
        -> Endpoint<MessageRepliesPayload> {
        .init(
            path: .replies(messageId),
            method: .get,
            body: pagination
        )
    }

    /// Create the endpoint to load reactions of a message.
    ///
    /// - Parameters:
    ///   - messageId: The message identifier.
    ///   - pagination: The `Pagination` instance provide infomation about pagination.
    /// - Returns: The endpoint to load reactions of a message.
    static func loadReactions(messageId: MessageId, pagination: Pagination) -> Endpoint<MessageReactionsPayload> {
        .init(
            path: .reactions(messageId),
            method: .get,
            query: nil,
            body: pagination
        )
    }

    /// Create the endpoint to add reaction to a message.
    ///
    /// - Parameters:
    ///   - type: The `MessageReactionType` to add.
    ///   - cid: The channel identifier.
    ///   - messageId: The message identifier.
    /// - Returns: The endpoint to add reaction to a message.
    static func addReaction(
        _ type: MessageReactionType,
        cid: ChannelId,
        messageId: MessageId
    ) -> Endpoint<EmptyResponse> {
        return .init(
            path: .addReaction(cid: cid,
                               messageId: messageId,
                               reactionType: type),
            method: .post
        )
    }

    /// Create the endpoint to delete reaction on a message.
    ///
    /// - Parameters:
    ///   - type: The `MessageReactionType` to add.
    ///   - cid: The channel identifier.
    ///   - messageId: The message identifier.
    /// - Returns: The endpoint to delete reaction on a message.
    static func deleteReaction(_ type: MessageReactionType, cid: ChannelId, messageId: MessageId) -> Endpoint<EmptyResponse> {
        .init(
            path: .deleteReaction(cid: cid,
                                  messageId: messageId,
                                  reactionType: type),
            method: .delete
        )
    }

    /// Create the endpoint to pin a message in a channel.
    ///
    /// - Parameters:
    ///   - messageId: The message identifier.
    ///   - cid: The channel identifier.
    /// - Returns: The endpoint to pin a message in a channel.
    static func pinMessage(with messageId: MessageId, in cid: ChannelId) -> Endpoint<EmptyResponse> {
        .init(path: .pinMessage(messageId, cid), method: .post)
    }

    /// Create the endpoint to unpin a message in a channel.
    ///
    /// - Parameters:
    ///   - messageId: The message identifier.
    ///   - cid: The channel identifier.
    /// - Returns: The endpoint to unpin a message in a channel.
    static func unpinMessage(with messageId: MessageId, in cid: ChannelId) -> Endpoint<EmptyResponse> {
        .init(path: .unPinMessage(messageId, cid), method: .post)
    }

    /// Create the endpoint to search message.
    ///
    /// - Parameters:
    ///   - query: The `MessageSearchQuery` instance.
    /// - Returns: The endpoint to search message.
    static func search(query: MessageSearchQuery) -> Endpoint<MessageSearchResultsPayload> {
        .init(path: .search, method: .get, body: ["payload": query])
    }
}
