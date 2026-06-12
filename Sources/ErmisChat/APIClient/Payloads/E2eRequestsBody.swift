//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// Request body for uploading GroupInfo after a successful MLS commit.
public struct UploadGroupInfoRequestBody: Encodable {
    /// TLS-serialized GroupInfo bytes.
    public let groupInfo: [UInt8]
    /// New epoch after the commit.
    public let epoch: Int

    public init(groupInfo: Data, epoch: Int) {
        self.groupInfo = groupInfo.uint8Array
        self.epoch = epoch
    }

    enum CodingKeys: String, CodingKey {
        case groupInfo = "group_info"
        case epoch
    }
}

/// Request body for performing an External Join on an MLS group.
public struct ExternalJoinRequestBody: Encodable {
    /// TLS-serialized external commit bytes.
    public let commit: [UInt8]
    /// New epoch after the external join.
    public let epoch: Int
    /// Project ID (required for ermis app).
    public let projectId: String?
    /// Two member IDs used to compute `channel_id` via hash (Messaging channels only).
    public let members: [String]?

    public init(commit: Data, epoch: Int, projectId: String? = nil, members: [String]? = nil) {
        self.commit = commit.uint8Array
        self.epoch = epoch
        self.projectId = projectId
        self.members = members
    }

    enum CodingKeys: String, CodingKey {
        case commit
        case epoch
        case projectId = "project_id"
        case members
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(commit, forKey: .commit)
        try container.encode(epoch, forKey: .epoch)
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
        try container.encode(self.commit, forKey: .commit)
        try container.encode(self.welcome, forKey: .welcome)
        try container.encode(self.ratchetTree, forKey: .ratchetTree)
        try container.encode(self.epoch, forKey: .epoch)
        try container.encode(self.groupInfo, forKey: .groupInfo)
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
}
