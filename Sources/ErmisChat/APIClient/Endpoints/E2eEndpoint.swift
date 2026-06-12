//
// Copyright 2025 Ermis Inc.
//

import Foundation

extension Endpoint {

    /// Create the endpoint to upload TLS-serialized KeyPackages for the current device.
    ///
    /// - Parameter keyPackages: An array of byte arrays, each representing one serialized KeyPackage.
    /// - Returns: The endpoint to upload KeyPackages.
    static func uploadKeyPackages(keyPackages: [[UInt8]]) -> Endpoint<UploadKeyPackagesPayload> {
        .init(
            path: .uploadKeyPackages,
            method: .post,
            body: UploadKeyPackagesRequestBody(keyPackages: keyPackages),
            needDeviceId: true
        )
    }

    /// Create the endpoint to check how many KeyPackages remain for the current device.
    ///
    /// - Returns: The endpoint to fetch the remaining KeyPackages count.
    static func keyPackagesCount() -> Endpoint<KeyPackagesCountPayload> {
        .init(
            path: .keyPackagesCount,
            method: .get,
            needDeviceId: true
        )
    }

    /// Create the endpoint to consume one KeyPackage per device of a target user.
    ///
    /// Fetches and consumes KeyPackages. Used before adding a user to an MLS group.
    ///
    /// - Parameter cid: The identifier of the channel that all KeyPackages of users on it should be consumed.
    /// - Returns: The endpoint to consume KeyPackages for the target user.
    static func consumeKeyPackages(cid: ChannelId, targetUserIds: [String] = []) -> Endpoint<ConsumeKeyPackagesPayload> {
        .init(
            path: .consumeKeyPackages(cid),
            method: .post,
            body: targetUserIds.isEmpty ? [:] : ["target_user_ids": targetUserIds],
            needDeviceId: true
        )
    }

    /// Create the endpoint to batch-consume one KeyPackage per device for a list of users.
    ///
    /// Fetches and consumes KeyPackages for multiple users in a single request, identified by
    /// their user IDs rather than a channel. Used when adding users to an MLS group without
    /// an existing channel context.
    ///
    /// - Parameter userIds: The list of user IDs whose KeyPackages should be consumed.
    /// - Returns: The endpoint to batch-consume KeyPackages by user IDs.
    static func consumeKeyPackagesBatch(userIds: [String]) -> Endpoint<ConsumeKeyPackagesPayload> {
        .init(
            path: .consumeKeyPackagesBatch,
            method: .post,
            body: ConsumeKeyPackagesBatchRequestBody(userIds: userIds),
            needDeviceId: true
        )
    }

    static func enableEncryption(cid: ChannelId, body: EnableEncryptionRequestBody) -> Endpoint<EmptyResponse> {
        .init(
            path: .enableEncryption(cid),
            method: .post,
            body: body,
            needDeviceId: true
        )
    }

    /// Create the endpoint to upload GroupInfo after a successful MLS commit.
    ///
    /// Called by any member after every successful commit (enableE2ee, addMembers, removeMember,
    /// keyRotation, externalJoin). The server upserts — only the latest GroupInfo is stored.
    ///
    /// - Parameters:
    ///   - cid: The channel identifier.
    ///   - body: The GroupInfo bytes and the new epoch.
    /// - Returns: The endpoint to upload GroupInfo.
    static func uploadGroupInfo(cid: ChannelId, body: UploadGroupInfoRequestBody) -> Endpoint<ChannelPayload> {
        .init(
            path: .uploadGroupInfo(cid),
            method: .post,
            body: body,
            needDeviceId: true
        )
    }

    /// Create the endpoint to fetch the current GroupInfo for a channel.
    ///
    /// Authorization: member (multi-device) or anyone (public channel).
    /// The response includes `is_stale: true` when the stored GroupInfo is behind the current
    /// MLS epoch, meaning an existing member must upload a fresh GroupInfo.
    ///
    /// - Parameter cid: The channel identifier.
    /// - Returns: The endpoint to get GroupInfo.
    static func getGroupInfo(cid: ChannelId) -> Endpoint<GroupInfoPayload> {
        .init(
            path: .getGroupInfo(cid),
            method: .get,
            needDeviceId: true
        )
    }

    /// Create the endpoint to join an MLS group via an External Commit.
    ///
    /// No Welcome message is needed. If the sender is already a member the server only broadcasts
    /// the external commit (multi-device). If the sender is not a member the server inserts them,
    /// sends a SystemMessage, fires a MemberJoined event, and broadcasts the external commit.
    ///
    /// - Parameters:
    ///   - cid: The channel identifier.
    ///   - body: The external commit bytes, new epoch, optional projectId and members list.
    /// - Returns: The endpoint to perform an external join.
    static func externalJoin(cid: ChannelId, body: ExternalJoinRequestBody) -> Endpoint<ChannelPayload> {
        .init(
            path: .externalJoin(cid),
            method: .post,
            body: body,
            needDeviceId: true
        )
    }

    /// Create the endpoint to fetch missed E2EE events for every sync scope in one call
    /// via POST /v1/e2ee/scope_sync.
    ///
    /// Pass a per-scope composite cursor map (`{created_at, event_id}`) to receive only events
    /// after each cursor. If `has_more` is `true` for any scope in the response, resend with
    /// that scope's `next_cursor` and repeat the call.
    ///
    /// - Parameter body: Composite cursors and optional limit for the scope sync request.
    /// - Returns: The endpoint to perform a bulk E2EE scope sync.
    static func e2eSync(body: E2eSyncRequestBody) -> Endpoint<E2eSyncPayload> {
        .init(
            path: .e2eSync,
            method: .post,
            body: body,
            needDeviceId: true
        )
    }

    /// Create the endpoint to fetch protocol events and E2EE application messages for a single channel.
    ///
    /// Returns merged, time-sorted events created after the given `since` timestamp.
    /// If `has_more` is `true` in the response, advance `since` to the last event's `created_at`
    /// and repeat the call.
    ///
    /// - Parameters:
    ///   - cid: The channel identifier.
    ///   - since: Fetch events after this timestamp (milliseconds since Unix epoch). Required.
    ///   - limit: Maximum number of events to return (capped at 200). Defaults to 100.
    /// - Returns: The endpoint to perform a single-channel E2EE sync.
    static func e2eChannelSync(cid: ChannelId, since: Int64, limit: Int = 100) -> Endpoint<E2eChannelSyncPayload> {
        .init(
            path: .e2eChannelSync(cid),
            method: .get,
            query: E2eChannelSyncQuery(since: since, limit: limit),
            needDeviceId: true
        )
    }

    /// Create the endpoint to commit an MLS eviction for users who self-left a channel.
    ///
    /// Only performs MLS group cleanup (removing ghost members from the MLS roster).
    /// Does NOT change channel membership — the members were already removed by the self-leave.
    ///
    /// - Parameters:
    ///   - cid: The channel identifier.
    ///   - body: The eviction commit payload (target user IDs, commit bytes, group_info, epoch).
    /// - Returns: The endpoint to commit an eviction.
    static func commitEviction(cid: ChannelId, body: CommitEvictionRequestBody) -> Endpoint<EmptyResponse> {
        .init(
            path: .commitEviction(cid),
            method: .post,
            body: body,
            needDeviceId: true
        )
    }
}
