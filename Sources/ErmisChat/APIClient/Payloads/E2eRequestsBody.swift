//
// Copyright 2025 Ermis Inc.
//

import Foundation

struct E2eeMlsRolloutTelemetryRequestBody: Encodable {
    let platform = "ios"
    let observations: [E2eeMlsRolloutMetricObservation]
}

/// Request body for uploading GroupInfo after a successful MLS commit.
public struct UploadGroupInfoRequestBody: Encodable {
    /// TLS-serialized GroupInfo bytes.
    public let groupInfo: [UInt8]
    /// New epoch after the commit.
    public let epoch: Int
    public let requestId: String?
    public let leaseToken: String?

    public init(groupInfo: Data, epoch: Int, requestId: String? = nil, leaseToken: String? = nil) {
        self.groupInfo = groupInfo.uint8Array
        self.epoch = epoch
        self.requestId = requestId
        self.leaseToken = leaseToken
    }

    enum CodingKeys: String, CodingKey {
        case groupInfo = "group_info"
        case epoch
        case requestId = "request_id"
        case leaseToken = "lease_token"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeE2eeBytes(groupInfo, forKey: .groupInfo)
        try container.encode(epoch, forKey: .epoch)
        try container.encodeIfPresent(requestId, forKey: .requestId)
        try container.encodeIfPresent(leaseToken, forKey: .leaseToken)
    }
}

struct ClaimGroupInfoRefreshRequestBody: Encodable {
    let requestId: String

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
    }
}

struct ReportGroupInfoFailureRequestBody: Encodable {
    let reason: String
    let observedEpoch: Int
    let observedHash: String

    enum CodingKeys: String, CodingKey {
        case reason
        case observedEpoch = "observed_epoch"
        case observedHash = "observed_hash"
    }
}

struct ClaimMlsRebootstrapRequestBody: Encodable, Equatable {
    let operationKey: String
    let expectedGeneration: Int
    let expectedEpoch: Int
    let protocolVersion: Int

    enum CodingKeys: String, CodingKey {
        case operationKey = "operation_key"
        case expectedGeneration = "expected_generation"
        case expectedEpoch = "expected_epoch"
        case protocolVersion = "protocol_version"
    }
}

struct MlsRebootstrapRecipientBody: Codable, Equatable {
    let userId: String
    let deviceId: String
    let keyPackageId: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case deviceId = "device_id"
        case keyPackageId = "key_package_id"
    }
}

struct CompleteMlsRebootstrapRequestBody: Codable, Equatable {
    let operationId: String
    let operationKey: String
    let leaseToken: String
    let expectedGeneration: Int
    let expectedEpoch: Int
    let newGeneration: Int
    let newEpoch: Int
    let membershipVersion: String
    let groupId: [UInt8]
    let groupInfo: [UInt8]
    let ratchetTree: [UInt8]
    let welcome: [UInt8]?
    let recipients: [MlsRebootstrapRecipientBody]

    enum CodingKeys: String, CodingKey {
        case operationId = "operation_id"
        case operationKey = "operation_key"
        case leaseToken = "lease_token"
        case expectedGeneration = "expected_generation"
        case expectedEpoch = "expected_epoch"
        case newGeneration = "new_generation"
        case newEpoch = "new_epoch"
        case membershipVersion = "membership_version"
        case groupId = "group_id"
        case groupInfo = "group_info"
        case ratchetTree = "ratchet_tree"
        case welcome
        case recipients
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(operationId, forKey: .operationId)
        try container.encode(operationKey, forKey: .operationKey)
        try container.encode(leaseToken, forKey: .leaseToken)
        try container.encode(expectedGeneration, forKey: .expectedGeneration)
        try container.encode(expectedEpoch, forKey: .expectedEpoch)
        try container.encode(newGeneration, forKey: .newGeneration)
        try container.encode(newEpoch, forKey: .newEpoch)
        try container.encode(membershipVersion, forKey: .membershipVersion)
        try container.encodeE2eeBytes(groupId, forKey: .groupId)
        try container.encodeE2eeBytes(groupInfo, forKey: .groupInfo)
        try container.encodeE2eeBytes(ratchetTree, forKey: .ratchetTree)
        if let welcome {
            try container.encodeE2eeBytes(welcome, forKey: .welcome)
        }
        try container.encode(recipients, forKey: .recipients)
    }

    init(
        operationId: String,
        operationKey: String,
        leaseToken: String,
        expectedGeneration: Int,
        expectedEpoch: Int,
        newGeneration: Int,
        newEpoch: Int,
        membershipVersion: String,
        groupId: [UInt8],
        groupInfo: [UInt8],
        ratchetTree: [UInt8],
        welcome: [UInt8]?,
        recipients: [MlsRebootstrapRecipientBody]
    ) {
        self.operationId = operationId
        self.operationKey = operationKey
        self.leaseToken = leaseToken
        self.expectedGeneration = expectedGeneration
        self.expectedEpoch = expectedEpoch
        self.newGeneration = newGeneration
        self.newEpoch = newEpoch
        self.membershipVersion = membershipVersion
        self.groupId = groupId
        self.groupInfo = groupInfo
        self.ratchetTree = ratchetTree
        self.welcome = welcome
        self.recipients = recipients
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        operationId = try container.decode(String.self, forKey: .operationId)
        operationKey = try container.decode(String.self, forKey: .operationKey)
        leaseToken = try container.decode(String.self, forKey: .leaseToken)
        expectedGeneration = try container.decode(Int.self, forKey: .expectedGeneration)
        expectedEpoch = try container.decode(Int.self, forKey: .expectedEpoch)
        newGeneration = try container.decode(Int.self, forKey: .newGeneration)
        newEpoch = try container.decode(Int.self, forKey: .newEpoch)
        membershipVersion = try container.decode(String.self, forKey: .membershipVersion)
        groupId = try container.decodeE2eeBytes(forKey: .groupId)
        groupInfo = try container.decodeE2eeBytes(forKey: .groupInfo)
        ratchetTree = try container.decodeE2eeBytes(forKey: .ratchetTree)
        welcome = try container.decodeE2eeBytesIfPresent(forKey: .welcome)
        recipients = try container.decode([MlsRebootstrapRecipientBody].self, forKey: .recipients)
    }
}

/// Request body for performing an External Join on an MLS group.
public struct ExternalJoinRequestBody: Encodable {
    /// TLS-serialized external commit bytes.
    public let commit: [UInt8]
    /// New epoch after the external join.
    public let epoch: Int
    public let groupGeneration: Int
    public let groupId: [UInt8]?
    /// Project ID (required for ermis app).
    public let projectId: String?
    /// Two member IDs used to compute `channel_id` via hash (Messaging channels only).
    public let members: [String]?

    public init(
        commit: Data,
        epoch: Int,
        groupGeneration: Int = 0,
        groupId: Data? = nil,
        projectId: String? = nil,
        members: [String]? = nil
    ) {
        self.commit = commit.uint8Array
        self.epoch = epoch
        self.groupGeneration = groupGeneration
        self.groupId = groupId?.uint8Array
        self.projectId = projectId
        self.members = members
    }

    enum CodingKeys: String, CodingKey {
        case commit
        case epoch
        case groupGeneration = "group_generation"
        case groupId = "group_id"
        case projectId = "project_id"
        case members
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeE2eeBytes(commit, forKey: .commit)
        try container.encode(epoch, forKey: .epoch)
        try container.encode(groupGeneration, forKey: .groupGeneration)
        if let groupId {
            try container.encodeE2eeBytes(groupId, forKey: .groupId)
        }
        try container.encodeIfPresent(projectId, forKey: .projectId)
        try container.encodeIfPresent(members, forKey: .members)
    }
}

/// Request body for POST /v1/e2ee/scope_sync.
///
/// Fetches all protocol + application + metadata events for each sync scope since the given
/// composite cursor. Each cursor is `{created_at, event_id}` where `created_at` is an RFC3339
/// timestamp string and `event_id` breaks ties between events sharing the same timestamp, so
/// pagination never skips or replays a same-timestamp event.
public struct E2eSyncRequestBody: Encodable {
    /// Per-scope composite cursors keyed by raw scope CID string (e.g. "team:ch001").
    /// For a parent channel scope this one cursor covers the parent channel, its non-gated
    /// topics, metadata, and the parent MLS protocol stream.
    public let cursors: [String: ScopeSyncCursorPayload]
    /// Maximum number of events to return across all scopes.
    public let limit: Int
    /// Cursor for the user-scoped `removed_channels` stream. Only removals after this
    /// `{removed_at, event_id}` are returned. `nil` on the first sync.
    public let removedCursor: RemovedSyncCursorPayload?

    public init(cursors: [String: ScopeSyncCursorPayload], limit: Int = 100, removedCursor: RemovedSyncCursorPayload? = nil) {
        self.cursors = cursors
        self.limit = limit
        self.removedCursor = removedCursor
    }

    enum CodingKeys: String, CodingKey {
        case cursors
        case limit
        case removedCursor = "removed_cursor"
    }
}

/// Query parameters for GET /v1/e2ee/channels/{type}/{id}/sync.
public struct E2eChannelSyncQuery: Encodable {
    /// Fetch events after this timestamp (milliseconds since Unix epoch). Required.
    public let since: Int64
    /// Maximum number of events to return (capped at 200 server-side).
    public let limit: Int

    public init(since: Int64, limit: Int = 100) {
        self.since = since
        self.limit = limit
    }
}

/// Request body for adding members to an MLS-enabled channel.
///
/// Carries both the member list and the MLS commit bundle produced by `addMember(to:memberKeyPackages:)`.
public struct AddMembersRequestBody: Encodable {
    /// User IDs to add to the channel.
    public let addMembers: [String]
    /// TLS-serialized commit bytes.
    public let commit: [UInt8]
    /// TLS-serialized welcome bytes.
    public let welcome: [UInt8]
    /// TLS-serialized ratchet tree bytes.
    public let ratchetTree: [UInt8]
    /// MLS group epoch after the commit.
    public let epoch: Int
    /// TLS-serialized GroupInfo bytes.
    public let groupInfo: [UInt8]

    public init(
        addMembers: [String],
        commit: Data,
        welcome: Data,
        ratchetTree: Data,
        epoch: Int,
        groupInfo: Data
    ) {
        self.addMembers = addMembers
        self.commit = commit.uint8Array
        self.welcome = welcome.uint8Array
        self.ratchetTree = ratchetTree.uint8Array
        self.epoch = epoch
        self.groupInfo = groupInfo.uint8Array
    }

    enum CodingKeys: String, CodingKey {
        case addMembers = "add_members"
        case commit
        case welcome
        case ratchetTree = "ratchet_tree"
        case epoch
        case groupInfo = "group_info"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(addMembers, forKey: .addMembers)
        try container.encodeE2eeBytes(commit, forKey: .commit)
        try container.encodeE2eeBytes(welcome, forKey: .welcome)
        try container.encodeE2eeBytes(ratchetTree, forKey: .ratchetTree)
        try container.encode(epoch, forKey: .epoch)
        try container.encodeE2eeBytes(groupInfo, forKey: .groupInfo)
    }
}

public struct RemoveMembersRequestBody: Encodable {
    /// User IDs to remove from the channel.
    public let removeMembers: [String]
    /// Is leave group or admin kick, true if user leave group.
    public let selfRemove: Bool
    /// TLS-serialized commit bytes.
    public let commit: [UInt8]
    /// MLS group epoch after the commit.
    public let epoch: Int
    /// TLS-serialized GroupInfo bytes.
    public let groupInfo: [UInt8]

    public init(
        removeMembers: [String],
        selfRemove: Bool,
        commit: Data,
        epoch: Int,
        groupInfo: Data
    ) {
        self.removeMembers = removeMembers
        self.selfRemove = selfRemove
        self.commit = commit.uint8Array
        self.epoch = epoch
        self.groupInfo = groupInfo.uint8Array
    }

    enum CodingKeys: String, CodingKey {
        case removeMembers = "remove_members"
        case selfRemove = "self_remove"
        case commit
        case epoch
        case groupInfo = "group_info"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(removeMembers, forKey: .removeMembers)
        try container.encode(selfRemove, forKey: .selfRemove)
        try container.encodeE2eeBytes(commit, forKey: .commit)
        try container.encode(epoch, forKey: .epoch)
        try container.encodeE2eeBytes(groupInfo, forKey: .groupInfo)
    }
}

public struct LeaveChannelRequestBody: Encodable {
    /// User IDs to remove from the channel.
    public let removeMembers: [String]
    /// Is leave group or admin kick, true if user leave group.
    public let selfRemove: Bool

    public init(
        removeMembers: [String],
        selfRemove: Bool,
    ) {
        self.removeMembers = removeMembers
        self.selfRemove = selfRemove
    }

    enum CodingKeys: String, CodingKey {
        case removeMembers = "remove_members"
        case selfRemove = "self_remove"
    }
}


public struct EnableEncryptionRequestBody: Encodable {
    public let commit: [UInt8]
    public let welcome: [UInt8]
    public let ratchetTree: [UInt8]
    public let epoch: Int
    public let groupInfo: [UInt8]

    public init(commit: Data, welcome: Data, ratchetTree: Data, epoch: Int, groupInfo: Data) {
        self.commit = commit.uint8Array
        self.welcome = welcome.uint8Array
        self.ratchetTree = ratchetTree.uint8Array
        self.epoch = epoch
        self.groupInfo = groupInfo.uint8Array
    }

    enum CodingKeys: String, CodingKey {
        case commit
        case welcome
        case ratchetTree = "ratchet_tree"
        case epoch
        case groupInfo = "group_info"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeE2eeBytes(self.commit, forKey: .commit)
        try container.encodeE2eeBytes(self.welcome, forKey: .welcome)
        try container.encodeE2eeBytes(self.ratchetTree, forKey: .ratchetTree)
        try container.encode(self.epoch, forKey: .epoch)
        try container.encodeE2eeBytes(self.groupInfo, forKey: .groupInfo)
    }
}

/// Request body for committing an MLS eviction (ghost cleanup) after a self-leave.
///
/// Only performs MLS group cleanup — does NOT change channel membership.
/// The target users were already removed from the channel by the self-leave event.
public struct CommitEvictionRequestBody: Encodable {
    /// User IDs of the ghost members to remove from the MLS group.
    public let targetUserIds: [String]
    /// TLS-serialized commit bytes for the member removal.
    public let commit: [UInt8]
    /// TLS-serialized GroupInfo bytes after the commit.
    public let groupInfo: [UInt8]
    /// MLS group epoch before the commit (pre-merge epoch).
    public let epoch: Int

    public init(
        targetUserIds: [String],
        commit: Data,
        groupInfo: Data,
        epoch: Int
    ) {
        self.targetUserIds = targetUserIds
        self.commit = commit.uint8Array
        self.groupInfo = groupInfo.uint8Array
        self.epoch = epoch
    }

    enum CodingKeys: String, CodingKey {
        case targetUserIds = "target_user_ids"
        case commit
        case groupInfo = "group_info"
        case epoch
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(targetUserIds, forKey: .targetUserIds)
        try container.encodeE2eeBytes(commit, forKey: .commit)
        try container.encodeE2eeBytes(groupInfo, forKey: .groupInfo)
        try container.encode(epoch, forKey: .epoch)
    }
}
