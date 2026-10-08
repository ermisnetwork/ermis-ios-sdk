//
// Copyright 2025 Ermis Inc.
//

import Foundation

struct E2eeMlsRolloutTelemetryPayload: Decodable {
    let accepted: Int
}

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

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeE2eeByteVector(keyPackages, forKey: .keyPackages)
    }
}

/// Response payload after uploading KeyPackages.
public class UploadKeyPackagesPayload: Decodable {
    /// Number of KeyPackages stored in this request.
    public let stored: Int
    /// Total remaining KeyPackages available for the device.
    public let totalRemaining: Int
    /// Server-owned inventory target for this device.
    public let target: Int
    /// Server-owned threshold at or below which a durable refill demand exists.
    public let lowWatermark: Int
    /// Exact delta required to restore the current server target.
    public let requestedDelta: Int
    /// Durable demand generation. `nil` means no refill demand is active.
    public let refillGeneration: Int?
    public let batchId: String
    public let validationVersion: Int

    enum CodingKeys: String, CodingKey {
        case stored
        case totalRemaining = "total_remaining"
        case target
        case lowWatermark = "low_watermark"
        case requestedDelta = "requested_delta"
        case refillGeneration = "refill_generation"
        case batchId = "batch_id"
        case validationVersion = "validation_version"
    }
}

/// Response payload for remaining KeyPackages count.
public class KeyPackagesCountPayload: Decodable {
    /// Number of remaining KeyPackages available for the current device.
    public let remaining: Int
    public let target: Int
    public let lowWatermark: Int
    public let requestedDelta: Int
    public let refillGeneration: Int?

    enum CodingKeys: String, CodingKey {
        case remaining
        case target
        case lowWatermark = "low_watermark"
        case requestedDelta = "requested_delta"
        case refillGeneration = "refill_generation"
    }
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

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyPackage = try container.decodeE2eeBytes(forKey: .keyPackage)
        deviceId = try container.decode(String.self, forKey: .deviceId)
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
public struct ExternalJoinPrerequisitePayload: Decodable {
    public let reason: String
}

public class GroupInfoPayload: Decodable {
    /// The full channel state (channel details, messages, members, etc.).
    let channel: ChannelPayload
    /// TLS-serialized GroupInfo bytes stored for this channel.
    public let groupInfo: [UInt8]
    /// The MLS epoch at which this GroupInfo was produced.
    public let epoch: Int
    public let groupGeneration: Int
    public let groupId: [UInt8]?
    public let hash: String
    /// `true` when `groupInfo.epoch < channel.mlsEpoch`, meaning the stored GroupInfo is outdated.
    public let isStale: Bool
    public let externalJoinPrerequisite: ExternalJoinPrerequisitePayload?

    func isValidExternalJoinIdentity(installedGeneration: Int) -> Bool {
        groupGeneration >= installedGeneration && groupGeneration >= 0 &&
            groupGeneration <= 9_007_199_254_740_991 && epoch >= 0 && epoch < 9_007_199_254_740_991 &&
            (groupId.map { (1...255).contains($0.count) } ?? (groupGeneration == 0))
    }

    var authorizesActiveMemberRecovery: Bool {
        !isStale && externalJoinPrerequisite?.reason == "active_member_recovery"
    }

    enum CodingKeys: String, CodingKey {
        case groupInfo = "group_info"
        case epoch
        case groupGeneration = "group_generation"
        case groupId = "group_id"
        case hash
        case isStale = "is_stale"
        case externalJoinPrerequisite = "external_join_prerequisite"
    }

    public required init(from decoder: any Decoder) throws {
        self.channel = try ChannelPayload(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.groupInfo = try container.decodeE2eeBytes(forKey: .groupInfo)
        self.epoch = try container.decode(Int.self, forKey: .epoch)
        self.groupGeneration = try container.decodeIfPresent(Int.self, forKey: .groupGeneration) ?? 0
        self.groupId = try container.decodeE2eeBytesIfPresent(forKey: .groupId)
        self.hash = try container.decode(String.self, forKey: .hash)
        self.isStale = try container.decodeIfPresent(Bool.self, forKey: .isStale) ?? false
        self.externalJoinPrerequisite = try container.decodeIfPresent(
            ExternalJoinPrerequisitePayload.self, forKey: .externalJoinPrerequisite
        )
    }
}

enum MlsRebootstrapState: String, Codable, Equatable {
    case repairing
    case eligible
    case preparing
    case activated
    case cancelledRepairWon = "cancelled_repair_won"
    case preparationFailedRetryable = "preparation_failed_retryable"
    case deliveryFailedRetryable = "delivery_failed_retryable"
    case upgradeRequired = "upgrade_required"
    case incompatibleServerClient = "incompatible_server_client"
}

enum MlsRebootstrapReason: String, Codable, Equatable {
    case groupInfoMissing = "group_info_missing"
    case groupInfoStale = "group_info_stale"
    case groupInfoInvalid = "group_info_invalid"
    case repairWindowOpen = "repair_window_open"
    case repairTimeoutElapsed = "repair_timeout_elapsed"
    case repairWonRace = "repair_won_race"
    case leaseUnavailable = "lease_unavailable"
    case leaseExpired = "lease_expired"
    case membershipChanged = "membership_changed"
    case generationChanged = "generation_changed"
    case operationConflict = "operation_conflict"
    case featureDisabled = "feature_disabled"
    case clientUpgradeRequired = "client_upgrade_required"
    case unsupportedProtocolVersion = "unsupported_protocol_version"
    case infrastructureUnavailable = "infrastructure_unavailable"
    case deliveryPending = "delivery_pending"
    case historyIncomplete = "history_incomplete"
}

struct MlsRebootstrapCapabilityPayload: Decodable, Equatable {
    static let currentProtocolVersion = 1

    let protocolVersion: Int
    let automaticEnabled: Bool
    let repairTimeoutSeconds: Int
    let maxGroupInfoBytes: Int
    let maxRatchetTreeBytes: Int
    let maxWelcomeRecipients: Int
    let maxWelcomeBytes: Int

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case automaticEnabled = "automatic_enabled"
        case repairTimeoutSeconds = "repair_timeout_seconds"
        case maxGroupInfoBytes = "max_group_info_bytes"
        case maxRatchetTreeBytes = "max_ratchet_tree_bytes"
        case maxWelcomeRecipients = "max_welcome_recipients"
        case maxWelcomeBytes = "max_welcome_bytes"
    }
}

struct MlsGenerationStatePayload: Decodable, Equatable {
    let groupGeneration: Int
    let groupId: [UInt8]?
    let currentEpoch: Int
    let membershipVersion: String
    let state: MlsRebootstrapState
    let reason: MlsRebootstrapReason
    let retryable: Bool
    let firstUnresolvedAt: Date?
    let incidentDeadlineAt: Date?
    let capability: MlsRebootstrapCapabilityPayload

    func isValidIdentity(installedGeneration: Int) -> Bool {
        let maximumSafeInteger = 9_007_199_254_740_991
        return (0...maximumSafeInteger).contains(groupGeneration)
            && (0...maximumSafeInteger).contains(currentEpoch)
            && groupGeneration >= installedGeneration
            && (groupId.map { (1...255).contains($0.count) } ?? (groupGeneration == 0))
    }

    func requiresAuthoritativeJoin(installedGeneration: Int, groupLoaded: Bool) -> Bool {
        isValidIdentity(installedGeneration: installedGeneration)
            && [.activated, .deliveryFailedRetryable].contains(state)
            && (groupGeneration > installedGeneration || (groupGeneration > 0 && !groupLoaded))
    }

    enum CodingKeys: String, CodingKey {
        case groupGeneration = "group_generation"
        case groupId = "group_id"
        case currentEpoch = "current_epoch"
        case membershipVersion = "membership_version"
        case state
        case reason
        case retryable
        case firstUnresolvedAt = "first_unresolved_at"
        case incidentDeadlineAt = "incident_deadline_at"
        case capability
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        groupGeneration = try container.decode(Int.self, forKey: .groupGeneration)
        groupId = try container.decodeE2eeBytesIfPresent(forKey: .groupId)
        currentEpoch = try container.decode(Int.self, forKey: .currentEpoch)
        membershipVersion = try container.decode(String.self, forKey: .membershipVersion)
        state = try container.decode(MlsRebootstrapState.self, forKey: .state)
        reason = try container.decode(MlsRebootstrapReason.self, forKey: .reason)
        retryable = try container.decode(Bool.self, forKey: .retryable)
        firstUnresolvedAt = try container.decodeIfPresent(Date.self, forKey: .firstUnresolvedAt)
        incidentDeadlineAt = try container.decodeIfPresent(Date.self, forKey: .incidentDeadlineAt)
        capability = try container.decode(MlsRebootstrapCapabilityPayload.self, forKey: .capability)
    }
}

struct MlsRebootstrapKeyPackagePayload: Decodable, Equatable {
    let keyPackageId: String
    let userId: String
    let deviceId: String
    let keyPackage: [UInt8]

    enum CodingKeys: String, CodingKey {
        case keyPackageId = "key_package_id"
        case userId = "user_id"
        case deviceId = "device_id"
        case keyPackage = "key_package"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyPackageId = try container.decode(String.self, forKey: .keyPackageId)
        userId = try container.decode(String.self, forKey: .userId)
        deviceId = try container.decode(String.self, forKey: .deviceId)
        keyPackage = try container.decodeE2eeBytes(forKey: .keyPackage)
    }
}

struct MlsRebootstrapClaimPayload: Decodable, Equatable {
    let operationId: String
    let operationKey: String
    let expectedGeneration: Int
    let nextGeneration: Int
    let expectedEpoch: Int
    let membershipVersion: String
    let leaseToken: String
    let leaseExpiresAt: Date
    let incidentDeadlineAt: Date
    let state: MlsRebootstrapState
    let reason: MlsRebootstrapReason
    let retryable: Bool
    let recipientKeyPackages: [MlsRebootstrapKeyPackagePayload]

    enum CodingKeys: String, CodingKey {
        case operationId = "operation_id"
        case operationKey = "operation_key"
        case expectedGeneration = "expected_generation"
        case nextGeneration = "next_generation"
        case expectedEpoch = "expected_epoch"
        case membershipVersion = "membership_version"
        case leaseToken = "lease_token"
        case leaseExpiresAt = "lease_expires_at"
        case incidentDeadlineAt = "incident_deadline_at"
        case state
        case reason
        case retryable
        case recipientKeyPackages = "recipient_key_packages"
    }
}

struct MlsRebootstrapReceiptPayload: Decodable, Equatable {
    let operationId: String
    let operationKey: String
    let state: MlsRebootstrapState
    let reason: MlsRebootstrapReason
    let retryable: Bool
    let expectedGeneration: Int
    let currentGeneration: Int
    let currentEpoch: Int
    let groupId: [UInt8]?
    let membershipVersion: String
    let activatedAt: Date?
    let deliveryPending: Int

    enum CodingKeys: String, CodingKey {
        case operationId = "operation_id"
        case operationKey = "operation_key"
        case state
        case reason
        case retryable
        case expectedGeneration = "expected_generation"
        case currentGeneration = "current_generation"
        case currentEpoch = "current_epoch"
        case groupId = "group_id"
        case membershipVersion = "membership_version"
        case activatedAt = "activated_at"
        case deliveryPending = "delivery_pending"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        operationId = try container.decode(String.self, forKey: .operationId)
        operationKey = try container.decode(String.self, forKey: .operationKey)
        state = try container.decode(MlsRebootstrapState.self, forKey: .state)
        reason = try container.decode(MlsRebootstrapReason.self, forKey: .reason)
        retryable = try container.decode(Bool.self, forKey: .retryable)
        expectedGeneration = try container.decode(Int.self, forKey: .expectedGeneration)
        currentGeneration = try container.decode(Int.self, forKey: .currentGeneration)
        currentEpoch = try container.decode(Int.self, forKey: .currentEpoch)
        groupId = try container.decodeE2eeBytesIfPresent(forKey: .groupId)
        membershipVersion = try container.decode(String.self, forKey: .membershipVersion)
        activatedAt = try container.decodeIfPresent(Date.self, forKey: .activatedAt)
        deliveryPending = try container.decode(Int.self, forKey: .deliveryPending)
    }
}

struct GroupInfoRefreshRequestPayload: Codable, Equatable {
    let requestId: String
    let minimumEpoch: Int
    let deadlineAt: Date
    let expiresAt: Date
    let reason: String
    let attemptCount: Int
    let leaseToken: String?
    let leaseExpiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case minimumEpoch = "minimum_epoch"
        case deadlineAt = "deadline_at"
        case expiresAt = "expires_at"
        case reason
        case attemptCount = "attempt_count"
        case leaseToken = "lease_token"
        case leaseExpiresAt = "lease_expires_at"
    }
}

struct GroupInfoRefreshResponsePayload: Decodable {
    let request: GroupInfoRefreshRequestPayload?
}

public struct E2ePayload: Codable, Equatable {
    let text: String
    let attachments: [MessageAttachmentPayload]
    /// Attachment manifests encrypted inside the MLS application payload. This is a distinct
    /// lane from legacy `MessageAttachmentPayload`: mixing the two representations in one
    /// message is rejected so a malformed E2EE manifest cannot silently become `.unknown`.
    public let e2eeAttachments: [E2eeAttachmentManifestV1]
    let stickerUrl: URL?
    /// Local-only metadata recovered from OpenMLS-authenticated AAD. It is deliberately omitted
    /// from MLS payload coding; sending it twice would create two competing wire representations.
    let authenticatedMetadata: E2eeAuthenticatedMessageMetadata?

    private enum CodingKeys: String, CodingKey {
        case text
        case attachments
        case stickerUrl = "sticker_url"
    }

    /// iOS releases before the cross-platform payload contract was aligned used the synthesized
    /// Swift property name inside MLS ciphertext. Keep this decode-only lane so already-sent
    /// stickers remain readable, while every newly encrypted payload uses `sticker_url`.
    private enum LegacyCodingKeys: String, CodingKey {
        case stickerUrl
    }

    public static func == (lhs: E2ePayload, rhs: E2ePayload) -> Bool {
        lhs.text == rhs.text &&
            lhs.attachments == rhs.attachments &&
            lhs.e2eeAttachments == rhs.e2eeAttachments &&
            lhs.stickerUrl == rhs.stickerUrl &&
            lhs.authenticatedMetadata == rhs.authenticatedMetadata
    }

    init(
        text: String,
        attachments: [MessageAttachmentPayload],
        e2eeAttachments: [E2eeAttachmentManifestV1] = [],
        stickerUrl: URL?,
        authenticatedMetadata: E2eeAuthenticatedMessageMetadata? = nil
    ) {
        self.text = text
        self.attachments = attachments
        self.e2eeAttachments = e2eeAttachments
        self.stickerUrl = stickerUrl
        self.authenticatedMetadata = authenticatedMetadata
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try container.decode(String.self, forKey: .text)
        let wireAttachments = try container.decodeIfPresent(
            [E2ePayloadAttachmentWire].self,
            forKey: .attachments
        ) ?? []
        self.attachments = wireAttachments.compactMap(\.legacyAttachment)
        self.e2eeAttachments = wireAttachments.compactMap(\.e2eeManifest)
        guard attachments.isEmpty || e2eeAttachments.isEmpty else {
            throw E2ePayloadCodingError.mixedAttachmentLanes
        }
        if let canonicalStickerUrl = try container.decodeIfPresent(URL.self, forKey: .stickerUrl) {
            self.stickerUrl = canonicalStickerUrl
        } else {
            let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
            self.stickerUrl = try legacyContainer.decodeIfPresent(URL.self, forKey: .stickerUrl)
        }
        self.authenticatedMetadata = nil
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        guard attachments.isEmpty || e2eeAttachments.isEmpty else {
            throw E2ePayloadCodingError.mixedAttachmentLanes
        }
        if e2eeAttachments.isEmpty {
            try container.encode(attachments, forKey: .attachments)
        } else {
            try container.encode(e2eeAttachments, forKey: .attachments)
        }
        try container.encodeIfPresent(stickerUrl, forKey: .stickerUrl)
    }

    func withAuthenticatedMetadata(_ metadata: E2eeAuthenticatedMessageMetadata?) -> Self {
        Self(
            text: text,
            attachments: attachments,
            e2eeAttachments: e2eeAttachments,
            stickerUrl: stickerUrl,
            authenticatedMetadata: metadata
        )
    }
}

struct E2eeAuthenticatedMessageMetadata: Codable, Equatable {
    let forwardCid: String?
    let forwardMessageId: String?
    let forwardParentCid: String?
    let attachmentIds: [String]
}

enum E2ePayloadCodingError: Error, Equatable {
    case mixedAttachmentLanes
}

/// Decodes the shared `attachments` JSON field without allowing an E2EE manifest to fall through
/// to the permissive legacy custom-attachment decoder. Presence of any V1 manifest discriminator
/// makes manifest decoding authoritative and therefore fail-closed when the object is malformed.
private enum E2ePayloadAttachmentWire: Decodable {
    case legacy(MessageAttachmentPayload)
    case e2ee(E2eeAttachmentManifestV1)

    private enum ManifestKeys: String, CodingKey {
        case version
        case attachmentId = "attachment_id"
        case assets
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: ManifestKeys.self)
        if container.contains(.version) || container.contains(.attachmentId) || container.contains(.assets) {
            self = .e2ee(try E2eeAttachmentManifestV1(from: decoder))
        } else {
            self = .legacy(try MessageAttachmentPayload(from: decoder))
        }
    }

    var legacyAttachment: MessageAttachmentPayload? {
        guard case .legacy(let attachment) = self else { return nil }
        return attachment
    }

    var e2eeManifest: E2eeAttachmentManifestV1? {
        guard case .e2ee(let manifest) = self else { return nil }
        return manifest
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
        channels = try container.decodeIfPresent([String: E2eSyncChannelPayload].self, forKey: .channels) ?? [:]
        removedChannels = try container.decodeIfPresent(RemovedChannelsPayload.self, forKey: .removedChannels)
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
        events = try container.decodeIfPresent([RemovedChannelEventPayload].self, forKey: .events) ?? []
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        nextCursor = try container.decodeIfPresent(RemovedSyncCursorPayload.self, forKey: .nextCursor)
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
public struct RemovedSyncCursorPayload: Codable, Equatable {
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
    let events: [E2eSyncEventEnvelope]
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
        events = try container.decodeIfPresent([E2eSyncEventEnvelope].self, forKey: .events) ?? []
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        nextCursor = try container.decodeIfPresent(ScopeSyncCursorPayload.self, forKey: .nextCursor)
    }
}

/// Durable identity and raw bytes for one scope-sync event.
///
/// The typed event remains convenient for application code, while the raw envelope is what the
/// durable inbox persists for idempotent replay after process death.
struct E2eSyncEventEnvelope: Decodable {
    let eventId: String
    let createdAt: Date
    let createdAtRaw: String
    let rawEnvelope: Data
    let event: E2eSyncEventPayload

    private enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventId = try container.decode(String.self, forKey: .eventId)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        createdAtRaw = try container.decode(String.self, forKey: .createdAt)
        let rawEncoder = JSONEncoder()
        rawEncoder.outputFormatting = [.sortedKeys]
        let rawData = try rawEncoder.encode(RawJSON(from: decoder))
        // Typed field decoders already count a legacy wire representation. Canonicalizing this
        // second copy is for durable deduplication only and must not double-count the same event.
        rawEnvelope = try E2eeWireJSONCanonicalizer.canonicalizeJSONData(
            rawData,
            recordLegacyUsage: false
        )
        event = try E2eSyncEventPayload(from: decoder)
    }
}

extension E2eSyncEventEnvelope {
    /// Bellboy's `/scope_sync` canonical ordering is
    /// `(created_at, protocol/application/metadata rank, event_id)`.
    ///
    /// The rank must survive a process restart. Sorting durable rows by timestamp and UUID only
    /// can move an application message in front of the commit at the same timestamp, leaving the
    /// local group on the wrong epoch and permanently blocking the scope.
    var scopeSyncKindRank: Int {
        switch event {
        case .protocol:
            return 0
        case .application:
            return 1
        default:
            return 2
        }
    }

    static func canonicalScopeSyncOrder(
        _ lhs: E2eSyncEventEnvelope,
        _ rhs: E2eSyncEventEnvelope
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        if lhs.scopeSyncKindRank != rhs.scopeSyncKindRank {
            return lhs.scopeSyncKindRank < rhs.scopeSyncKindRank
        }
        // UUID's canonical textual order is equivalent to its raw 16-byte order. Normalize case
        // so a non-canonical producer cannot make replay ordering platform-dependent.
        return lhs.eventId.lowercased() < rhs.eventId.lowercased()
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
    let groupGeneration: Int
    let groupId: [UInt8]?
    let user: UserPayload
    let type: MLSProtocolType
    let commit: [UInt8]?
    let welcome: [UInt8]?
    let ratchetTree: [UInt8]?
    let proposal: [UInt8]?
    let deviceId: String?
    let targetUserIds: [String]?
    let targetDeviceIds: [String]?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case epoch
        case groupGeneration = "group_generation"
        case groupId = "group_id"
        case user
        case type
        case commit
        case welcome
        case ratchetTree = "ratchet_tree"
        case proposal
        case deviceId = "device_id"
        case targetUserIds = "target_user_ids"
        case targetDeviceIds = "target_device_ids"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        epoch = try container.decode(Int.self, forKey: .epoch)
        groupGeneration = try container.decodeIfPresent(Int.self, forKey: .groupGeneration) ?? 0
        groupId = try container.decodeE2eeBytesIfPresent(forKey: .groupId)
        user = try container.decode(UserPayload.self, forKey: .user)
        type = try container.decode(MLSProtocolType.self, forKey: .type)
        commit = try container.decodeE2eeBytesIfPresent(forKey: .commit)
        welcome = try container.decodeE2eeBytesIfPresent(forKey: .welcome)
        ratchetTree = try container.decodeE2eeBytesIfPresent(forKey: .ratchetTree)
        proposal = try container.decodeE2eeBytesIfPresent(forKey: .proposal)
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId)
        targetUserIds = try container.decodeIfPresent([String].self, forKey: .targetUserIds)
        targetDeviceIds = try container.decodeIfPresent([String].self, forKey: .targetDeviceIds)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

/// The `data` payload for an `application` sync event.
struct E2eSyncApplicationData: Decodable {
    let id: String
    let cid: String?
    let user: UserPayload?
    /// Bellboy message type. Keep the raw value so newly introduced or currently unsupported
    /// application variants (for example `poll`) remain decodable during a mixed-client window.
    /// Only `system` changes sync behavior; every other value follows the encrypted application
    /// path and can fail as an application repair without blocking the MLS protocol scope.
    let type: String
    /// Plain-text content; populated for system messages, empty for E2EE messages.
    let text: String?
    /// TLS-serialized MLS ciphertext bytes. Present only for regular (encrypted) messages.
    let mlsCiphertext: [UInt8]?
    let mlsEpoch: Int64?
    let groupGeneration: Int
    let contentType: String
    let createdAt: Date
    let forwardCid: String?
    let forwardMessageId: String?
    let forwardParentCid: String?
    let e2eeAttachmentIds: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case cid
        case user
        case type
        case text
        case mlsCiphertext = "mls_ciphertext"
        case mlsEpoch = "mls_epoch"
        case groupGeneration = "group_generation"
        case contentType = "content_type"
        case createdAt = "created_at"
        case forwardCid = "forward_cid"
        case forwardMessageId = "forward_message_id"
        case forwardParentCid = "forward_parent_cid"
        case e2eeAttachmentIds = "e2ee_attachment_ids"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        cid = try container.decodeIfPresent(String.self, forKey: .cid)
        user = try container.decodeIfPresent(UserPayload.self, forKey: .user)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? MessageType.regular.rawValue
        text = try container.decodeIfPresent(String.self, forKey: .text)
        mlsCiphertext = try container.decodeE2eeBytesIfPresent(forKey: .mlsCiphertext)
        mlsEpoch = try container.decodeIfPresent(Int64.self, forKey: .mlsEpoch)
        groupGeneration = try container.decodeIfPresent(Int.self, forKey: .groupGeneration) ?? 0
        contentType = try container.decode(String.self, forKey: .contentType)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        forwardCid = try container.decodeIfPresent(String.self, forKey: .forwardCid)
        forwardMessageId = try container.decodeIfPresent(String.self, forKey: .forwardMessageId)
        forwardParentCid = try container.decodeIfPresent(String.self, forKey: .forwardParentCid)
        e2eeAttachmentIds = try container.decodeIfPresent([String].self, forKey: .e2eeAttachmentIds) ?? []
    }

    /// Whether this is a system message rather than an encrypted application message.
    var isSystemMessage: Bool {
        type == MessageType.system.rawValue
    }


    var e2eeReceivedEnvelope: E2eeReceivedMessageEnvelope {
        .init(
            forwardCid: forwardCid,
            forwardMessageId: forwardMessageId,
            forwardParentCid: forwardParentCid,
            attachmentIds: e2eeAttachmentIds
        )
    }
}

/// Top-level response for GET /v1/e2ee/channels/{type}/{id}/sync.
/// Contains time-sorted, merged protocol and application events for a single channel.
struct E2eChannelSyncPayload: Decodable {
    /// Ordered list of protocol and application events for this channel.
    let events: [E2eSyncEventEnvelope]
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
    let action: String
    let message: MessagePayload
    let sender: UserPayload?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case action
        case message
        case sender
        case user
        case createdAt = "created_at"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Bellboy deliberately keeps the CID on the outer scope envelope. `user` was emitted
        // by an older iOS durable row, so retain it as a read-only compatibility alias.
        action = try container.decode(String.self, forKey: .action)
        message = try container.decode(MessagePayload.self, forKey: .message)
        sender = try container.decodeIfPresent(UserPayload.self, forKey: .sender)
            ?? (try container.decodeIfPresent(UserPayload.self, forKey: .user))
        createdAt = try container.decode(Date.self, forKey: .createdAt)
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
    let groupGeneration: Int
    let groupId: [UInt8]?
    let user: UserPayload
    let deviceId: String?
    let commit: [UInt8]?
    let welcome: [UInt8]?
    let ratchetTree: [UInt8]?
    let targetUserIds: [String]?
    let targetDeviceIds: [String]?
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
        case groupGeneration = "group_generation"
        case groupId = "group_id"
        case user
        case deviceId = "device_id"
        case commit
        case welcome
        case ratchetTree = "ratchet_tree"
        case targetUserIds = "target_user_ids"
        case targetDeviceIds = "target_device_ids"
        case proposal
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(MLSProtocolType.self, forKey: .type)
        epoch = try container.decode(Int.self, forKey: .epoch)
        groupGeneration = try container.decodeIfPresent(Int.self, forKey: .groupGeneration) ?? 0
        groupId = try container.decodeE2eeBytesIfPresent(forKey: .groupId)
        user = try container.decode(UserPayload.self, forKey: .user)
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId)
        commit = try container.decodeE2eeBytesIfPresent(forKey: .commit)
        welcome = try container.decodeE2eeBytesIfPresent(forKey: .welcome)
        ratchetTree = try container.decodeE2eeBytesIfPresent(forKey: .ratchetTree)
        targetUserIds = try container.decodeIfPresent([String].self, forKey: .targetUserIds)
        targetDeviceIds = try container.decodeIfPresent([String].self, forKey: .targetDeviceIds)
        proposal = try container.decodeE2eeBytesIfPresent(forKey: .proposal)
    }
}
