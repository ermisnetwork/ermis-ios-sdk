//
// Copyright 2025 Ermis Inc.
//

import Foundation

// MARK: - User muting

extension Endpoint {
    /// Create the endpoint to mute a user.
    ///
    /// - Parameters:
    ///   - userId: The user identifier.
    /// - Returns: The endpoint to mute a user.
    static func muteUser(_ userId: UserId) -> Endpoint<EmptyResponse> {
        muteUser(true, with: userId)
    }

    /// Create the endpoint to unmute a user.
    ///
    /// - Parameters:
    ///   - userId: The user identifier.
    /// - Returns: The endpoint to unmute a user.
    static func unmuteUser(_ userId: UserId) -> Endpoint<EmptyResponse> {
        muteUser(false, with: userId)
    }
}

// MARK: - User banning

extension Endpoint {
    /// Create the endpoint to ban a member in channel.
    ///
    /// - Parameters:
    ///   - members: The member identifier list.
    ///   - cid: The channel identifier.
    /// - Returns: The endpoint to ban a member in channel.
    static func banMember(
        _ members: [UserId],
        cid: ChannelId
    ) -> Endpoint<EmptyResponse> {
        .init(
            path: .channelDetailUpdate(cid: cid),
            method: .post,
            body: [
                "ban_members": members
            ]
        )
    }

    /// Create the endpoint to unban a member in channel.
    ///
    /// - Parameters:
    ///   - members: The member identifier list.
    ///   - cid: The channel identifier.
    /// - Returns: The endpoint to unban a member in channel.
    static func unbanMember(_ members: [UserId], cid: ChannelId) -> Endpoint<EmptyResponse> {
        .init(
            path: .channelDetailUpdate(cid: cid),
            method: .post,
            body: [
                "unban_members": members
            ]
        )
    }
}

// MARK: - Private

private extension Endpoint {
    static func muteUser(_ mute: Bool, with userId: UserId) -> Endpoint<EmptyResponse> {
        .init(
            path: .muteUser(mute),
            method: .post,
            body: ["target_id": userId]
        )
    }
}
