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

/// Top-level response for POST /v1/e2ee/sync.
/// Keyed by raw CID string (e.g. "team:ch001").
public struct E2eSyncPayload: Decodable {
    /// Per-channel results, keyed by raw CID string.
    public let channels: [String: E2eSyncChannelPayload]

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        channels = try container.decode([String: E2eSyncChannelPayload].self)
    }
}

/// Events and pagination info for a single channel returned by /v1/e2ee/sync.
public struct E2eSyncChannelPayload: Decodable {
    /// Ordered list of protocol and application events for this channel.
    public let events: [E2eSyncEventPayload]
    /// `true` when more events are available; update the cursor and repeat the request.
    public let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case events
        case hasMore = "has_more"
    }
}

/// A single event entry inside a channel's sync result.
public enum E2eSyncEventPayload: Decodable {
    /// An MLS protocol message (commit, welcome, proposal, external_commit).
    case `protocol`(E2eSyncProtocolData)
    /// An encrypted application message.
    case application(E2eSyncApplicationData)

    private enum TypeKey: String, Decodable {
        case `protocol`
        case application
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case data
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type_ = try container.decode(TypeKey.self, forKey: .type)
        switch type_ {
        case .protocol:
            self = .protocol(try container.decode(E2eSyncProtocolData.self, forKey: .data))
        case .application:
            self = .application(try container.decode(E2eSyncApplicationData.self, forKey: .data))
        }
    }

    /// The `created_at` timestamp of the underlying event, used for cursor advancement.
    public var createdAt: Date {
        switch self {
        case .protocol(let data): return data.createdAt
        case .application(let data): return data.createdAt
        }
    }
}

/// The `data` payload for a `protocol` sync event.
public struct E2eSyncProtocolData: Decodable {
    public let epoch: Int
    let user: UserPayload
    public let type: MLSProtocolType
    public let commit: [UInt8]?
    public let welcome: [UInt8]?
    public let ratchetTree: [UInt8]?
    public let proposal: [UInt8]?
    public let deviceId: String?
    public let targetUserIds: [String]?
    public let createdAt: Date

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

/// The `data` payload for an `application` sync event.
public struct E2eSyncApplicationData: Decodable {
    public let id: String
    /// Plain-text content; always empty for E2EE messages.
    public let text: String?
    /// TLS-serialized MLS ciphertext bytes.
    public let mlsCiphertext: [UInt8]
    public let contentType: String
    public let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case mlsCiphertext = "mls_ciphertext"
        case contentType = "content_type"
        case createdAt = "created_at"
    }
}

/// Top-level response for GET /v1/e2ee/channels/{type}/{id}/sync.
/// Contains time-sorted, merged protocol and application events for a single channel.
public struct E2eChannelSyncPayload: Decodable {
    /// Ordered list of protocol and application events for this channel.
    public let events: [E2eSyncEventPayload]
    /// `true` when more events are available; advance the `since` cursor and repeat the request.
    public let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case events
        case hasMore = "has_more"
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
