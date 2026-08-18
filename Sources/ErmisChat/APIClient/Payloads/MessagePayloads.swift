//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// Coding keys for message-related JSON payloads
enum MessagePayloadsCodingKeys: String, CodingKey, CaseIterable {
    case id
    case cid
    case type
    case user
    case encryptedData = "mls_ciphertext"
    case mlsEpoch = "mls_epoch"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case deletedAt = "deleted_at"
    case text
    case oldTexts = "old_texts"
    case command
    case args
    case attachments
    case stickerUrl = "sticker_url"
    case parentId = "parent_id"
    case quotedMessageId = "quoted_message_id"
    case quotedMessage = "quoted_message"
    case mentionedUsers = "mentioned_users"
    case mentionedAll = "mentioned_all"
    case threadParticipants = "thread_participants"
    case replyCount = "reply_count"
    case latestReactions = "latest_reactions"
    case reaction = "reaction"
    case ownReactions = "own_reactions"
    case reactionScores = "reaction_scores"
    case reactionCounts = "reaction_counts"
    case isSilent = "silent"
    case channel
    case pinned
    case pinnedBy = "pinned_by"
    case pinnedAt = "pinned_at"
    case pinExpires = "pin_expires"
    case html
    case i18n
    case mml
    case imageLabels = "image_labels"
    case shadowed
    case moderationDetails = "moderation_details"
    case messageTextUpdatedAt = "message_text_updated_at"
    case forwardCid = "forward_cid"
    case forwardMessageId = "forward_message_id"
    case forwardParentCid = "forward_parent_cid"
    case e2eeGroupId = "e2ee_group_id"
    case e2eeAttachmentIds = "e2ee_attachment_ids"
}

extension MessagePayload {
    /// A object describing the incoming JSON format for message payload. Unfortunately, our backend is not consistent
    /// in this and the payload has the form: `{ "message": <message payload> }` rather than `{ <message payload> }`
    struct Boxed: Decodable {
        let message: MessagePayload
    }
}

struct MessageSearchResultsPayload: Decodable {
    let results: [MessagePayload.Boxed]
    let next: String?
}

/// An object describing the incoming message JSON payload.
class MessagePayload: Decodable {
    let id: String
    /// Only messages from `translate` endpoint contain `cid`
    let cid: ChannelId?
    let type: MessageType
    let user: UserPayload
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?
    let messageTextUpdatedAt: Date?
    let text: String
    let encryptedData: [UInt8]?
    let mlsEpoch: Int?
    let oldTexts: [MessageEditHistoryPayload]?
    let command: String?
    let args: String?
    let parentId: String?
    let quotedMessage: MessagePayload?
    let quotedMessageId: MessageId?
    let forwardChannelId: ChannelId?
    let forwardMessageId: String?
    let forwardParentCid: String?
    let e2eeAttachmentIds: [String]
    let mentionedUsers: [String]
    let threadParticipants: [UserPayload]
    let replyCount: Int
    let mentionedAll: Bool
    let pinnedAt: Date?
    let pinnedBy: UserPayload?
    let latestReactions: [MessageReactionPayload]
    let reactionScores: [MessageReactionType: Int]
    let reactionCounts: [MessageReactionType: Int]
    let attachments: [MessageAttachmentPayload]
    let stickerUrl: URL?
    let isSilent: Bool
    let isShadowed: Bool
    let translations: [TranslationLanguage: String]?
    let originalLanguage: String?
    let moderationDetails: MessageModerationDetailsPayload?

    var e2eeReceivedEnvelope: E2eeReceivedMessageEnvelope {
        .init(
            forwardCid: forwardChannelId?.rawValue,
            forwardMessageId: forwardMessageId,
            forwardParentCid: forwardParentCid,
            attachmentIds: e2eeAttachmentIds
        )
    }

    /// Only message payload from `getMessage` endpoint contains channel data. It's a convenience workaround for having to
    /// make an extra call do get channel details.
    let channel: ChannelDetailPayload?

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: MessagePayloadsCodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        cid = try container.decodeIfPresent(ChannelId.self, forKey: .cid)
        type = try container.decodeIfPresent(MessageType.self, forKey: .type) ?? .regular
        user = try container.decode(UserPayload.self, forKey: .user)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        text = try container.decodeIfPresent(String.self, forKey: .text)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        encryptedData = try container.decodeE2eeBytesIfPresent(forKey: .encryptedData)
        mlsEpoch = try container.decodeIfPresent(Int.self, forKey: .mlsEpoch)
        oldTexts = try container.decodeIfPresent([MessageEditHistoryPayload].self, forKey: .oldTexts)
        isSilent = try container.decodeIfPresent(Bool.self, forKey: .isSilent) ?? false
        isShadowed = try container.decodeIfPresent(Bool.self, forKey: .shadowed) ?? false
        command = try container.decodeIfPresent(String.self, forKey: .command)
        args = try container.decodeIfPresent(String.self, forKey: .args)
        parentId = try container.decodeIfPresent(String.self, forKey: .parentId)
        quotedMessage = try container.decodeIfPresent(MessagePayload.self, forKey: .quotedMessage)
        forwardChannelId = try container.decodeIfPresent(ChannelId.self, forKey: .forwardCid)
        forwardMessageId = try container.decodeIfPresent(String.self, forKey: .forwardMessageId)
        forwardParentCid = try container.decodeIfPresent(String.self, forKey: .forwardParentCid)
        e2eeAttachmentIds = try container.decodeIfPresent([String].self, forKey: .e2eeAttachmentIds) ?? []
        mentionedUsers = try container.decodeArrayIfPresentIgnoringFailures([String].self, forKey: .mentionedUsers) ?? []
        mentionedAll = try container.decodeIfPresent(Bool.self, forKey: .mentionedAll) ?? false
        pinnedAt = try container.decodeIfPresent(Date.self, forKey: .pinnedAt)
        pinnedBy = try container.decodeIfPresent(UserPayload.self, forKey: .pinnedBy)
        // backend returns `thread_participants` only if message is a thread, we are fine with to have it on all messages
        threadParticipants = try container.decodeIfPresent([UserPayload].self, forKey: .threadParticipants) ?? []
        replyCount = try container.decodeIfPresent(Int.self, forKey: .replyCount) ?? 0
        latestReactions = try container.decodeArrayIfPresentIgnoringFailures([MessageReactionPayload].self, forKey: .latestReactions) ?? []
        reactionCounts = try container
            .decodeIfPresent([String: Int].self, forKey: .reactionCounts)?
            .mapKeys { MessageReactionType(rawValue: $0) } ?? [:]

        reactionScores = reactionCounts


        // Because attachment objects can be malformed, we wrap those into `OptionalDecodable`
        // and if decoding of those fail, it assignes `nil` instead of throwing whole MessagePayload away.
        attachments = try container.decodeIfPresent([OptionalDecodable].self, forKey: .attachments)?
            .compactMap(\.base) ?? []
        stickerUrl = try container.decodeIfPresent(String.self, forKey: .stickerUrl).flatMap(URL.init(string:))
        // Some endpoints return also channel payload data for convenience
        channel = try container.decodeIfPresent(ChannelDetailPayload.self, forKey: .channel)
        quotedMessageId = try container.decodeIfPresent(MessageId.self, forKey: .quotedMessageId)
        let i18n = try container.decodeIfPresent(MessageTranslationsPayload.self, forKey: .i18n)
        translations = i18n?.translated
        originalLanguage = i18n?.originalLanguage
        moderationDetails = try container.decodeIfPresent(MessageModerationDetailsPayload.self, forKey: .moderationDetails)
        messageTextUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    init(
        id: String,
        cid: ChannelId? = nil,
        type: MessageType,
        user: UserPayload,
        createdAt: Date,
        updatedAt: Date,
        deletedAt: Date? = nil,
        text: String,
        encryptedData: [UInt8]? = nil,
        mlsEpoch: Int? = nil,
        oldTexts: [MessageEditHistoryPayload],
        command: String? = nil,
        args: String? = nil,
        parentId: String? = nil,
        quotedMessageId: String? = nil,
        quotedMessage: MessagePayload? = nil,
        forwardChannelId: ChannelId?,
        forwardMessageId: String? = nil,
        forwardParentCid: String? = nil,
        e2eeAttachmentIds: [String] = [],
        mentionedUsers: [String],
        mentionedAll: Bool = false,
        pinnedAt: Date? = nil,
        threadParticipants: [UserPayload] = [],
        replyCount: Int,
        latestReactions: [MessageReactionPayload] = [],
        reactionScores: [MessageReactionType: Int],
        reactionCounts: [MessageReactionType: Int],
        isSilent: Bool,
        isShadowed: Bool,
        attachments: [MessageAttachmentPayload],
        stickerUrl: URL,
        channel: ChannelDetailPayload? = nil,
        pinned: Bool = false,
        pinnedBy: UserPayload? = nil,
        pinExpires: Date? = nil,
        translations: [TranslationLanguage: String]? = nil,
        originalLanguage: String? = nil,
        moderationDetails: MessageModerationDetailsPayload? = nil,
        messageTextUpdatedAt: Date? = nil
    ) {
        self.id = id
        self.cid = cid
        self.type = type
        self.user = user
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.text = text
        self.encryptedData = encryptedData
        self.mlsEpoch = mlsEpoch
        self.oldTexts = oldTexts
        self.command = command
        self.args = args
        self.parentId = parentId
        self.quotedMessage = quotedMessage
        self.forwardChannelId = forwardChannelId
        self.forwardMessageId = forwardMessageId
        self.forwardParentCid = forwardParentCid
        self.e2eeAttachmentIds = e2eeAttachmentIds
        self.mentionedUsers = mentionedUsers
        self.mentionedAll = mentionedAll
        self.pinnedAt = pinnedAt
        self.pinnedBy = nil
        self.threadParticipants = threadParticipants
        self.replyCount = replyCount
        self.latestReactions = latestReactions
        self.reactionScores = reactionScores
        self.reactionCounts = reactionCounts
        self.isSilent = isSilent
        self.isShadowed = isShadowed
        self.attachments = attachments
        self.stickerUrl = stickerUrl
        self.channel = channel
        self.quotedMessageId = quotedMessageId
        self.translations = translations
        self.originalLanguage = originalLanguage
        self.moderationDetails = moderationDetails
        self.messageTextUpdatedAt = messageTextUpdatedAt
    }

    public func getReactions(of userId: String) -> [MessageReactionPayload] {
        return latestReactions.filter { $0.user.id == userId }
    }
}

/// An object describing the outgoing message JSON payload.
struct MessageRequestBody: Encodable {
    var id: String
    let user: UserRequestBody
    var text: String
    var encryptedData: [UInt8]?
    var mlsEpoch: Int?
    let type: MessageType?
    let oldTexts: [MessageEditHistoryPayload]?
    var cid: ChannelId?
    let command: String?
    let args: String?
    let parentId: String?
    let isSilent: Bool
    let quotedMessageId: String?
    var attachments: [MessageAttachmentPayload]
    var stickerUrl: URL?
    let mentionedUserIds: [UserId]
    let mentionedAll: Bool
    let createdAt: Date?
    var forwardCid: String?
    let forwardMessageId: String?
    var forwardParentCid: String?
    var e2eeGroupId: String?
    var e2eeAttachmentIds: [String]

    /// Core Data's historical `forwardCid` default is an empty string. Treat that sentinel as
    /// absent at the request boundary so an ordinary message cannot accidentally enter Bellboy's
    /// forwarding validation path.
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// The current no-AAD MLS lane is valid only for messages whose envelope carries no
    /// attachment/forward metadata. M2/M4 replace this fail-closed gate with the authenticated
    /// attachment/forward sender.
    var requiresE2eeAuthenticatedSendLane: Bool {
        !attachments.isEmpty ||
            !e2eeAttachmentIds.isEmpty ||
            forwardCid?.isEmpty == false ||
            forwardMessageId?.isEmpty == false ||
            forwardParentCid?.isEmpty == false
    }

    /// A sender retry must reuse this exact MLS generation. Creating another ciphertext for an
    /// unknown HTTP result can duplicate the logical message and consume another sender secret.
    var hasDurableE2eeNetworkIntent: Bool {
        encryptedData != nil && mlsEpoch != nil
    }

    mutating func bindE2eeNetworkIntent(ciphertext: [UInt8], epoch: Int) {
        encryptedData = ciphertext
        mlsEpoch = epoch
        text = ""
        attachments = []
        stickerUrl = nil
    }

    mutating func bindE2eeAuthenticatedEnvelope(
        destinationCid: ChannelId,
        groupId: String,
        attachmentIds: [String],
        forwardParentCid: String? = nil
    ) throws {
        // The AAD must authenticate the same destination that the send endpoint targets. A
        // locally-created MessageDTO does not always carry `cid` in its request snapshot, so bind
        // the already-validated destination explicitly instead of relying on optional DTO state.
        cid = destinationCid
        e2eeGroupId = groupId
        e2eeAttachmentIds = try E2eeMessageAADV1.canonicalAttachmentIds(attachmentIds)
        self.forwardParentCid = forwardParentCid
        _ = try authenticatedAAD()
    }

    func authenticatedAAD() throws -> E2eeMessageAADV1? {
        guard attachments.isEmpty else {
            // Standard attachment payloads have no encrypted V1 manifest and must remain on the
            // fail-closed lane in an effective-E2EE channel.
            throw E2eeMessageAADError.authenticatedSendLaneUnavailable
        }
        let requiresAAD = !e2eeAttachmentIds.isEmpty
            || forwardCid?.isEmpty == false
            || forwardMessageId?.isEmpty == false
            || forwardParentCid?.isEmpty == false
        guard requiresAAD else { return nil }
        guard let e2eeGroupId, !e2eeGroupId.isEmpty else {
            throw E2eeMessageAADError.missingE2eeGroupId
        }
        guard let cid else {
            throw E2eeMessageAADError.missingEnvelopeCid
        }
        return E2eeMessageAADV1(
            cid: cid.rawValue,
            e2eeGroupId: e2eeGroupId,
            messageId: id,
            forwardCid: forwardCid,
            forwardMessageId: forwardMessageId,
            forwardParentCid: forwardParentCid,
            attachmentIds: e2eeAttachmentIds
        )
    }

    init(
        id: String,
        user: UserRequestBody,
        text: String,
        encryptedData: [UInt8]? = nil,
        mslEpoch: Int? = nil,
        oldTexts: [MessageEditHistoryPayload]? = nil,
        type: MessageType? = nil,
        cid: ChannelId? = nil,
        command: String? = nil,
        args: String? = nil,
        parentId: String? = nil,
        isSilent: Bool = false,
        quotedMessageId: String? = nil,
        attachments: [MessageAttachmentPayload] = [],
        stickerUrl: URL? = nil,
        mentionedUserIds: [UserId] = [],
        mentionedAll: Bool = false,
        createdAt: Date? = nil,
        forwardCid: String? = nil,
        forwardMessageId: String? = nil,
        forwardParentCid: String? = nil,
        e2eeGroupId: String? = nil,
        e2eeAttachmentIds: [String] = []
    ) {
        self.id = id
        self.user = user
        self.text = text
        self.encryptedData = encryptedData
        self.mlsEpoch = mslEpoch
        self.oldTexts = oldTexts
        self.type = type
        self.cid = cid
        self.command = command
        self.args = args
        self.parentId = parentId
        self.isSilent = isSilent
        self.quotedMessageId = quotedMessageId
        self.mentionedAll = mentionedAll
        self.attachments = attachments
        self.stickerUrl = stickerUrl
        self.mentionedUserIds = mentionedUserIds
        self.createdAt = createdAt
        self.forwardCid = Self.nonEmpty(forwardCid)
        self.forwardMessageId = Self.nonEmpty(forwardMessageId)
        self.forwardParentCid = Self.nonEmpty(forwardParentCid)
        self.e2eeGroupId = e2eeGroupId
        self.e2eeAttachmentIds = e2eeAttachmentIds
    }

    init(with message: ChatMessage) {
        self.id = message.id
        self.user = UserRequestBody(from: message.author)
        self.text = message.text
        self.encryptedData = message.encryptedData != nil ? message.encryptedData!.uint8Array : nil
        self.mlsEpoch = message.mlsEpoch
        self.oldTexts = message.oldTexts?.map {
            MessageEditHistoryPayload(text: $0.text, createdAt: $0.createdAt)
        }
        self.command = message.command
        self.type = message.type
        self.cid = message.cid
        self.args = nil
        self.parentId = message.parentMessageId
        self.isSilent = message.isSilent
        self.quotedMessageId = message.quotedMessageId
        self.mentionedAll = message.mentionedAll
        self.attachments = message.allAttachments.compactMap({ attachment in
            let messageAttachment = try? JSONDecoder().decode(MessageAttachmentPayload.self, from: attachment.payload)
            if let payload = messageAttachment?.payload {
                return MessageAttachmentPayload(type: attachment.type, payload: payload)
            }
            return nil
        })
        self.stickerUrl = message.stickerUrl
        self.mentionedUserIds = message.mentionedUsers.map(\.userId)
        self.createdAt = message.createdAt
        self.forwardCid = nil
        self.forwardMessageId = nil
        self.forwardParentCid = nil
        self.e2eeGroupId = nil
        self.e2eeAttachmentIds = []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: MessagePayloadsCodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(user, forKey: .user)
        try container.encode(text, forKey: .text)
        try container.encodeE2eeBytesIfPresent(encryptedData, forKey: .encryptedData)
        try container.encodeIfPresent(mlsEpoch, forKey: .mlsEpoch)
        try container.encodeIfPresent(oldTexts, forKey: .oldTexts)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(cid, forKey: .cid)
        try container.encodeIfPresent(command, forKey: .command)
        try container.encodeIfPresent(args, forKey: .args)
        try container.encodeIfPresent(parentId, forKey: .parentId)
        try container.encodeIfPresent(quotedMessageId, forKey: .quotedMessageId)
        try container.encode(isSilent, forKey: .isSilent)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(Self.nonEmpty(forwardCid), forKey: .forwardCid)
        try container.encodeIfPresent(stickerUrl, forKey: .stickerUrl)
        try container.encodeIfPresent(Self.nonEmpty(forwardMessageId), forKey: .forwardMessageId)
        try container.encodeIfPresent(Self.nonEmpty(forwardParentCid), forKey: .forwardParentCid)
        try container.encodeIfPresent(e2eeGroupId, forKey: .e2eeGroupId)
        if !e2eeAttachmentIds.isEmpty {
            let canonicalIds = try E2eeMessageAADV1.canonicalAttachmentIds(e2eeAttachmentIds)
            try container.encode(canonicalIds, forKey: .e2eeAttachmentIds)
        }

        if !attachments.isEmpty {
            try container.encode(attachments, forKey: .attachments)
        }

        if !mentionedUserIds.isEmpty {
            try container.encode(mentionedUserIds, forKey: .mentionedUsers)
        }

        if mentionedAll {
            try container.encode(mentionedAll, forKey: .mentionedAll)
        }
    }

    static func forwardMessageBody(from message: ChatMessage) -> MessageRequestBody {
        return .init(id: .newUniqueId,
                     user: UserRequestBody(from: message.author),
                     text: message.textContentAfterParseMention ?? message.text,
                     attachments: message.allAttachments.compactMap({ attachment in
            if attachment.type == .linkPreview {
                return nil
            }
            let messageAttachment = try? JSONDecoder().decode(MessageAttachmentPayload.self, from: attachment.payload)
            if let payload = messageAttachment?.payload {
                return MessageAttachmentPayload(type: attachment.type, payload: payload)
            }
            return nil
        }), forwardCid: message.cid?.rawValue, forwardMessageId: message.id
        )
    }
}

/// An object describing pinned messages JSON payload.
typealias PinnedMessagesPayload = MessageListPayload

/// An object describing the message list JSON payload.
typealias MessageRepliesPayload = MessageListPayload

struct MessageListPayload: Decodable {
    let messages: [MessagePayload]
}

struct MessageReactionsPayload: Decodable {
    let reactions: [MessageReactionPayload]
}

/// A command in a message.
public struct Command: Codable, Hashable {
    /// A command name.
    public let name: String
    /// A description.
    public let description: String
    public let set: String
    /// Args for the command.
    public let args: String

    public init(name: String = "", description: String = "", set: String = "", args: String = "") {
        self.name = name
        self.description = description
        self.set = set
        self.args = args
    }
}

public struct MessageEditHistoryPayload: Codable {
    let text: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case text
        case createdAt = "created_at"
    }

    public init(text: String, createdAt: Date) {
        self.text = text
        self.createdAt = createdAt
    }

    public
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try container.decode(String.self, forKey: .text)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    public
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.text, forKey: .text)
        try container.encode(self.createdAt, forKey: .createdAt)
    }
}
