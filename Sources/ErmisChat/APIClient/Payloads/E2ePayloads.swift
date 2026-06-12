//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// Request body for uploading KeyPackages.
public struct UploadKeyPackagesRequestBody: Encodable {
    /// TLS-serialized KeyPackages as arrays of bytes.
    public let keyPackages: [[UInt8]]

    public init(keyPackages: [[UInt8]]) {
        self.keyPackages = keyPackages
    }

    enum CodingKeys: String, CodingKey {
        case keyPackages = "key_packages"
    }
}

/// Response payload after uploading KeyPackages.
public class UploadKeyPackagesPayload: Decodable {
    /// Number of KeyPackages stored in this request.
    public let stored: Int
    /// Total remaining KeyPackages available for the device.
    public let totalRemaining: Int

    enum CodingKeys: String, CodingKey {
        case stored
        case totalRemaining = "total_remaining"
    }
}

/// Response payload for remaining KeyPackages count.
public class KeyPackagesCountPayload: Decodable {
    /// Number of remaining KeyPackages available for the current device.
    public let remaining: Int
}

/// A single KeyPackage entry returned when consuming KeyPackages for a user.
public class KeyPackageEntry: Decodable {
    /// TLS-serialized KeyPackage as an array of bytes.
    public let keyPackage: [UInt8]
    /// The device identifier this KeyPackage belongs to.
    public let deviceId: String

    enum CodingKeys: String, CodingKey {
        case keyPackage = "key_package"
        case deviceId = "device_id"
    }
}

/// KeyPackages grouped by user, as returned when consuming KeyPackages for multiple members.
public class MemberKeyPackages: Decodable {
    /// The user's identifier.
    public let userId: String
    /// One KeyPackage per device of the user.
    public let keyPackages: [KeyPackageEntry]

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case keyPackages = "key_packages"
    }
}

/// Request body for batch-consuming KeyPackages by user IDs.
public struct ConsumeKeyPackagesBatchRequestBody: Encodable {
    /// The list of user IDs whose KeyPackages should be consumed.
    public let userIds: [String]

    public init(userIds: [String]) {
        self.userIds = userIds
    }

    enum CodingKeys: String, CodingKey {
        case userIds = "user_ids"
    }
}

/// Response payload when consuming KeyPackages for multiple target users.
public class ConsumeKeyPackagesPayload: Decodable {
    /// KeyPackages grouped per member.
    public let members: [MemberKeyPackages]
}

/// Response payload for GET /group_info.
/// Extends the standard ChannelPayload with GroupInfo-specific fields.
public class GroupInfoPayload: Decodable {
    /// The full channel state (channel details, messages, members, etc.).
    let channel: ChannelPayload
    /// TLS-serialized GroupInfo bytes stored for this channel.
    public let groupInfo: [UInt8]
    /// The MLS epoch at which this GroupInfo was produced.
    public let epoch: Int
    /// `true` when `groupInfo.epoch < channel.mlsEpoch`, meaning the stored GroupInfo is outdated.
    public let isStale: Bool

    enum CodingKeys: String, CodingKey {
        case groupInfo = "group_info"
        case epoch
        case isStale = "is_stale"
    }

    public required init(from decoder: any Decoder) throws {
        self.channel = try ChannelPayload(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.groupInfo = try container.decode([UInt8].self, forKey: .groupInfo)
        self.epoch = try container.decode(Int.self, forKey: .epoch)
        self.isStale = try container.decodeIfPresent(Bool.self, forKey: .isStale) ?? false
    }
}

public struct E2ePayload: Codable, Equatable {
    let text: String
    let attachments: [MessageAttachmentPayload]
    let stickerUrl: URL?

    public static func == (lhs: E2ePayload, rhs: E2ePayload) -> Bool {
        lhs.text == rhs.text && lhs.attachments == rhs.attachments && lhs.stickerUrl == rhs.stickerUrl
    }

    init(text: String, attachments: [MessageAttachmentPayload], stickerUrl: URL?) {
        self.text = text
        self.attachments = attachments
        self.stickerUrl = stickerUrl
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try container.decode(String.self, forKey: .text)
        self.attachments = try container.decodeIfPresent([MessageAttachmentPayload].self, forKey: .attachments) ?? []
        self.stickerUrl = try container.decodeIfPresent(URL.self, forKey: .stickerUrl)
    }
}

// MARK: - E2eSync response

/// Composite cursor for POST /v1/e2ee/scope_sync: `{created_at, event_id}`.
///
/// `created_at` is an RFC3339 timestamp string; `event_id` breaks ties between events that
/// share the same timestamp so pagination never skips or replays a same-timestamp event.
/// Kept as strings end-to-end so the exact server cursor is echoed back verbatim.
public struct ScopeSyncCursorPayload: Codable, Equatable {
    public let createdAt: String
    public let eventId: String

    public init(createdAt: String, eventId: String) {
        self.createdAt = createdAt
        self.eventId = eventId
    }

    enum CodingKeys: String, CodingKey {
        case createdAt = "created_at"
        case eventId = "event_id"
    }
}

/// Top-level response for POST /v1/e2ee/scope_sync.
///
/// Scope sync nests the per-scope results under a `channels` map (keyed by raw scope CID
/// string, e.g. "team:ch001") and returns the user-scoped cleanup stream — channels the
/// current user was removed from, or that were deleted for everyone — under
/// `removed_channels`.
struct E2eSyncPayload: Decodable {
    /// Per-scope results, keyed by raw scope CID string.
    let channels: [String: E2eSyncChannelPayload]
    /// User-scoped removal stream — delete local group + cached messages for each cid.
    let removedChannels: RemovedChannelsPayload?

    enum CodingKeys: String, CodingKey {
        case channels
        case removedChannels = "removed_channels"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channels = (try? container.decode([String: E2eSyncChannelPayload].self, forKey: .channels)) ?? [:]
        removedChannels = try? container.decode(RemovedChannelsPayload.self, forKey: .removedChannels)
    }
}

/// The `removed_channels` stream returned by sync: channels the current user was removed
/// from (self-leave, kicked, invite rejected) or that were deleted for everyone. For each
/// entry the client deletes the local MLS group + cached messages for `cid`, then advances
/// the removal cursor to `nextCursor`.
struct RemovedChannelsPayload: Decodable {
    let events: [RemovedChannelEventPayload]
    let hasMore: Bool
    let nextCursor: RemovedSyncCursorPayload?

    enum CodingKeys: String, CodingKey {
        case events
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        events = (try? container.decode([RemovedChannelEventPayload].self, forKey: .events)) ?? []
        hasMore = (try? container.decode(Bool.self, forKey: .hasMore)) ?? false
        nextCursor = try? container.decode(RemovedSyncCursorPayload.self, forKey: .nextCursor)
    }
}

/// A single entry in the `removed_channels` stream (one row from `member_removal_history`).
struct RemovedChannelEventPayload: Decodable {
    /// The channel the current user was removed from / that was deleted.
    let cid: String
    let eventId: String?
    let channelId: String?
    let channelType: String?
    /// Parent cid for a removed topic; may be null.
    let parentCid: String?
    let removedAt: String?
    let removedBy: String?
    /// One of: `self_remove`, `kicked`, `invite_rejected`, `channel_deleted`.
    let removalType: String?
    let reason: String?
    let selfRemove: Bool?

    enum CodingKeys: String, CodingKey {
        case cid
        case eventId = "event_id"
        case channelId = "channel_id"
        case channelType = "channel_type"
        case parentCid = "parent_cid"
        case removedAt = "removed_at"
        case removedBy = "removed_by"
        case removalType = "removal_type"
        case reason
        case selfRemove = "self_remove"
    }
}

/// Cursor for the `removed_channels` stream: `{removed_at, event_id}` with an RFC3339
/// `removed_at`. Kept as a string end-to-end so sub-millisecond precision is not lost.
public struct RemovedSyncCursorPayload: Codable {
    public let removedAt: String
    public let eventId: String

    public init(removedAt: String, eventId: String) {
        self.removedAt = removedAt
        self.eventId = eventId
    }

    enum CodingKeys: String, CodingKey {
        case removedAt = "removed_at"
        case eventId = "event_id"
    }
}

/// Events and pagination info for a single scope returned by /v1/e2ee/scope_sync.
struct E2eSyncChannelPayload: Decodable {
    /// Ordered list of protocol, application, and metadata events for this scope.
    let events: [E2eSyncEventPayload]
    /// `true` when more events are available; resend with `nextCursor` to fetch the rest.
    let hasMore: Bool
    /// Composite cursor to resend on the next sync for this scope. Echo it back verbatim.
    /// Present when the scope returned events; may be absent for an empty scope result.
    let nextCursor: ScopeSyncCursorPayload?

    enum CodingKeys: String, CodingKey {
        case events
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        events = (try? container.decode([E2eSyncEventPayload].self, forKey: .events)) ?? []
        hasMore = (try? container.decode(Bool.self, forKey: .hasMore)) ?? false
        nextCursor = try? container.decode(ScopeSyncCursorPayload.self, forKey: .nextCursor)
    }
}

/// A single event entry inside a channel's sync result.
enum E2eSyncEventPayload: Decodable {
    /// An MLS protocol message (commit, welcome, proposal, external_commit).
    case `protocol`(E2eSyncProtocolData)
    /// An encrypted application message.
    case application(E2eSyncApplicationData)
    /// A reaction event (reaction.new, reaction.updated, reaction.deleted).
    /// Overwrites the reaction snapshot for the referenced message.
    case reaction(ReactionSyncData)
    /// A message deletion event. Removes the local message/cache entry.
    case messageDeleted(MessageDeletedSyncData)
    /// A message update event. The latest edited snapshot should be decrypted and upserted.
    case messageUpdated(MessageUpdatedSyncData)
    /// A message pin/unpin event. Patches the pin state on the message.
    case messagePin(MessagePinSyncData)
    /// A member removal event.
    /// `selfRemove == true` → queue pending ghost for composite cleanup.
    /// `selfRemove == false` → treat as admin kick.
    /// The `Date` is the envelope-level `created_at` (not inside the data payload).
    case memberRemoved(MemberRemovedSyncData, Date)
    /// An invite accepted event. Triggers E2E channel sync when MLS is enabled.
    case inviteAccepted(InviteRespondSyncData, Date)
    /// An invite rejected event. Triggers E2E channel sync when MLS is enabled.
    case inviteRejected(InviteRespondSyncData, Date)
    /// A messaging invite rejected event.
    case inviteMessagingRejected(InviteRespondSyncData, Date)
    /// A messaging invite skipped event. Triggers E2E channel sync when MLS is enabled.
    case inviteMessagingSkipped(InviteRespondSyncData, Date)
    /// A websocket event (message.new, member.added, etc.).
    case websocketEvent(EventPayload)
    /// An unknown or undecodable event type. Stored for logging/debugging purposes.
    /// Contains the type string and the raw JSON string of the `data` field.
    case unknown(type: String, rawData: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case data
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let typeString = try container.decode(String.self, forKey: .type)

        do {
            switch typeString {
            case "protocol":
                self = .protocol(try container.decode(E2eSyncProtocolData.self, forKey: .data))
            case "application":
                self = .application(try container.decode(E2eSyncApplicationData.self, forKey: .data))
            case "reaction":
                self = .reaction(try container.decode(ReactionSyncData.self, forKey: .data))
            case "message_deleted":
                self = .messageDeleted(try container.decode(MessageDeletedSyncData.self, forKey: .data))
            case "message_updated":
                self = .messageUpdated(try container.decode(MessageUpdatedSyncData.self, forKey: .data))
            case "message_pin":
                self = .messagePin(try container.decode(MessagePinSyncData.self, forKey: .data))
            case "member_removed":
                let data = try container.decode(MemberRemovedSyncData.self, forKey: .data)
                let envelopeCreatedAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
                self = .memberRemoved(data, envelopeCreatedAt)
            case "invite_accepted":
                let data = try container.decode(InviteRespondSyncData.self, forKey: .data)
                let envelopeCreatedAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
                self = .inviteAccepted(data, envelopeCreatedAt)
            case "invite_rejected":
                let data = try container.decode(InviteRespondSyncData.self, forKey: .data)
                let envelopeCreatedAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
                self = .inviteRejected(data, envelopeCreatedAt)
            case "invite_messaging_rejected":
                let data = try container.decode(InviteRespondSyncData.self, forKey: .data)
                let envelopeCreatedAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
                self = .inviteMessagingRejected(data, envelopeCreatedAt)
            case "invite_messaging_skipped":
                let data = try container.decode(InviteRespondSyncData.self, forKey: .data)
                let envelopeCreatedAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
                self = .inviteMessagingSkipped(data, envelopeCreatedAt)
            default:
                let rawData = Self.extractRawDataString(from: container)
                self = .unknown(type: typeString, rawData: rawData)
            }
        } catch {
            // If decoding a known type's data fails, fall back to unknown so the
            // rest of the event array can still be decoded.
            let rawData = Self.extractRawDataString(from: container)
            self = .unknown(type: typeString, rawData: rawData)
        }
    }

    /// Attempts to extract the raw JSON string of the `data` field for logging.
    private static func extractRawDataString(from container: KeyedDecodingContainer<CodingKeys>) -> String {
        if let rawJSON = try? container.decode(RawJSON.self, forKey: .data) {
            return String(describing: rawJSON)
        }
        return "<unable to read raw data>"
    }

    /// The `created_at` timestamp of the underlying event, used for cursor advancement.
    var createdAt: Date {
        switch self {
        case .protocol(let data): return data.createdAt
        case .application(let data): return data.createdAt
        case .reaction(let data): return data.createdAt
        case .messageDeleted(let data): return data.createdAt
        case .messageUpdated(let data): return data.createdAt
        case .messagePin(let data): return data.createdAt
        case .memberRemoved(_, let createdAt): return createdAt
        case .inviteAccepted(_, let createdAt): return createdAt
        case .inviteRejected(_, let createdAt): return createdAt
        case .inviteMessagingRejected(_, let createdAt): return createdAt
        case .inviteMessagingSkipped(_, let createdAt): return createdAt
        case .websocketEvent(let data): return data.createdAt ?? Date()
        case .unknown: return Date()
        }
    }
}

/// The `data` payload for a `protocol` sync event.
struct E2eSyncProtocolData: Decodable {
    let epoch: Int
    let user: UserPayload
    let type: MLSProtocolType
    let commit: [UInt8]?
    let welcome: [UInt8]?
    let ratchetTree: [UInt8]?
    let proposal: [UInt8]?
    let deviceId: String?
    let targetUserIds: [String]?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case epoch
        case user
        case type
        case commit
        case welcome
        case ratchetTree = "ratchet_tree"
        case proposal
        case deviceId = "device_id"
        case targetUserIds = "target_user_ids"
        case createdAt = "created_at"
    }
}

/// Message type inside an application sync event.
enum E2eSyncApplicationMessageType: String, Decodable {
    /// A regular encrypted application message.
    case regular
    /// A system-generated message (e.g. member join/leave notifications).
    case system
}

/// The `data` payload for an `application` sync event.
struct E2eSyncApplicationData: Decodable {
    let id: String
    let cid: String?
    let user: UserPayload?
    /// The message type — `regular` (encrypted) or `system` (plain-text).
    let type: E2eSyncApplicationMessageType
    /// Plain-text content; populated for system messages, empty for E2EE messages.
    let text: String?
    /// TLS-serialized MLS ciphertext bytes. Present only for regular (encrypted) messages.
    let mlsCiphertext: [UInt8]?
    let contentType: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case cid
        case user
        case type
        case text
        case mlsCiphertext = "mls_ciphertext"
        case contentType = "content_type"
        case createdAt = "created_at"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        cid = try container.decodeIfPresent(String.self, forKey: .cid)
        user = try container.decodeIfPresent(UserPayload.self, forKey: .user)
        type = try container.decodeIfPresent(E2eSyncApplicationMessageType.self, forKey: .type) ?? .regular
        text = try container.decodeIfPresent(String.self, forKey: .text)
        mlsCiphertext = try container.decodeIfPresent([UInt8].self, forKey: .mlsCiphertext)
        contentType = try container.decode(String.self, forKey: .contentType)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    /// Whether this is a system message rather than an encrypted application message.
    var isSystemMessage: Bool {
        type == .system
    }
}

/// Top-level response for GET /v1/e2ee/channels/{type}/{id}/sync.
/// Contains time-sorted, merged protocol and application events for a single channel.
struct E2eChannelSyncPayload: Decodable {
    /// Ordered list of protocol and application events for this channel.
    let events: [E2eSyncEventPayload]
    /// `true` when more events are available; advance the `since` cursor and repeat the request.
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case events
        case hasMore = "has_more"
    }
}

// MARK: - Sync Data Payloads for E2eSyncEventPayload

/// The `data` payload for a `reaction` sync event.
/// Overwrites the reaction snapshot for the given message.
struct ReactionSyncData: Decodable {
    let cid: ChannelId
    let message: MessagePayload
    let reaction: MessageReactionPayload
    let user: UserPayload
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case cid
        case message
        case reaction
        case user
        case createdAt = "created_at"
    }
}

/// The `data` payload for a `message_deleted` sync event.
/// Signals that a message should be removed from local cache.
struct MessageDeletedSyncData: Decodable {
    let cid: ChannelId
    let message: MessagePayload
    let user: UserPayload?
    let hardDelete: Bool
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case cid
        case message
        case user
        case hardDelete = "hard_delete"
        case createdAt = "created_at"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cid = try container.decode(ChannelId.self, forKey: .cid)
        message = try container.decode(MessagePayload.self, forKey: .message)
        user = try container.decodeIfPresent(UserPayload.self, forKey: .user)
        hardDelete = try container.decodeIfPresent(Bool.self, forKey: .hardDelete) ?? true
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

/// The `data` payload for a `message_updated` sync event.
/// Contains the latest edited snapshot that should be decrypted and upserted.
struct MessageUpdatedSyncData: Decodable {
    let cid: ChannelId
    let message: MessagePayload
    let user: UserPayload
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case cid
        case message
        case user
        case createdAt = "created_at"
    }
}

/// The `data` payload for a `message_pin` sync event.
/// Patches the pin/unpin state on the message.
struct MessagePinSyncData: Decodable {
    let cid: ChannelId
    let message: MessagePayload
    let user: UserPayload
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case cid
        case message
        case user
        case createdAt = "created_at"
    }
}

/// The `data` payload for a `member_removed` sync event.
/// If `selfRemove` is true, the member left voluntarily — queue a pending ghost for composite cleanup.
/// If `selfRemove` is false, the member was kicked by an admin.
struct MemberRemovedSyncData: Decodable {
    let memberContainer: MemberContainerPayload
    let selfRemove: Bool

    enum CodingKeys: String, CodingKey {
        case memberContainer = "member"
        case selfRemove = "self_remove"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        memberContainer = try container.decode(MemberContainerPayload.self, forKey: .memberContainer)
        selfRemove = try container.decodeIfPresent(Bool.self, forKey: .selfRemove) ?? false
    }
}

/// The `data` payload for invite respond-back sync events
/// (`invite_accepted`, `invite_rejected`, `invite_messaging_rejected`, `invite_messaging_skipped`).
/// All four types share the same shape; the type string determines the respond-back semantics.
struct InviteRespondSyncData: Decodable {
    let mlsEnabled: Bool
    let memberContainer: MemberContainerPayload
    let topicCids: [ChannelId]?

    enum CodingKeys: String, CodingKey {
        case mlsEnabled = "mls_enabled"
        case memberContainer = "member"
        case topicCids = "topic_cids"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mlsEnabled = try container.decodeIfPresent(Bool.self, forKey: .mlsEnabled) ?? false
        memberContainer = try container.decode(MemberContainerPayload.self, forKey: .memberContainer)
        topicCids = try container.decodeIfPresent([ChannelId].self, forKey: .topicCids)
    }
}

public struct MlsSyncPayload: Decodable {

}


public enum MLSProtocolType: String, Decodable {
    case commit
    case externalCommit = "external_commit"
    case welcome
    case proposal
}

public struct MLSProtocolMessagePayload: Decodable {
    let type: MLSProtocolType
    let epoch: Int
    let user: UserPayload
    let deviceId: String?
    let commit: [UInt8]?
    let welcome: [UInt8]?
    let ratchetTree: [UInt8]?
    let targetUserIds: [String]?
    let proposal: [UInt8]?

    var processData: Data? {
        switch type {
        case .commit, .externalCommit:
            return commit != nil ? Data(commit!) : nil
        case .welcome:
            return welcome != nil ? Data(welcome!) : nil
        case .proposal:
            return proposal != nil ? Data(proposal!) : nil
        default:
            return nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case type
        case epoch
        case user
        case deviceId = "device_id"
        case commit
        case welcome
        case ratchetTree = "ratchet_tree"
        case targetUserIds = "target_user_ids"
        case proposal
    }
}
