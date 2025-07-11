//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// An object describing the incoming current user JSON payload.
class CurrentUserPayload: UserPayload {
    /// A list of devices.
    let devices: [DevicePayload]
    /// Muted users.
    let mutedUsers: [MutedUserPayload]
    /// Unread channel and message counts
    let unreadCount: UnreadCount?

    init(
        id: String,
        projectId: String,
        name: String?,
        imageURL: URL?,
        phone: String?,
        email: String?,
        role: UserRole,
        createdAt: Date,
        updatedAt: Date,
        deactivatedAt: Date?,
        lastActiveAt: Date?,
        isOnline: Bool?,
        isInvisible: Bool,
        isBanned: Bool,
        isBlocked: Bool,
        teams: [TeamId] = [],
        language: String?,
        devices: [DevicePayload] = [],
        mutedUsers: [MutedUserPayload] = [],
        unreadCount: UnreadCount? = nil,
        isEmailVerified: Bool,
        bellBoyId: String,
        aboutMe: String
    ) {
        self.devices = devices
        self.mutedUsers = mutedUsers
        self.unreadCount = unreadCount

        super.init(
            id: id,
            projectId: projectId,
            name: name,
            imageURL: imageURL,
            phone: phone,
            email: email,
            role: role,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deactivatedAt: deactivatedAt,
            lastActiveAt: lastActiveAt,
            isOnline: isOnline ?? true,
            isInvisible: isInvisible,
            isBanned: isBanned,
            teams: teams,
            language: language,
            isEmailVerified: isEmailVerified,
            bellBoyId: bellBoyId,
            aboutMe: aboutMe
        )
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: UserPayloadsCodingKeys.self)
        devices = try container.decodeIfPresent([DevicePayload].self, forKey: .devices) ?? []
        mutedUsers = try container.decodeIfPresent([MutedUserPayload].self, forKey: .mutedUsers) ?? []
        unreadCount = try? UnreadCount(from: decoder)

        try super.init(from: decoder)
    }
}

/// An object describing the incoming muted-user JSON payload.
struct MutedUserPayload: Decodable {
    private enum CodingKeys: String, CodingKey {
        case mutedUser = "target"
        case created = "created_at"
        case updated = "updated_at"
    }

    let mutedUser: UserPayload
    let created: Date
    let updated: Date
}

extension MutedUserPayload: Equatable {
    static func == (lhs: MutedUserPayload, rhs: MutedUserPayload) -> Bool {
        lhs.mutedUser.id == rhs.mutedUser.id && lhs.created == rhs.created
    }
}

/// A muted users response.
struct MutedUsersResponse: Decodable {
    private enum CodingKeys: String, CodingKey {
        case mutedUser = "mute"
        case currentUser = "own_user"
    }

    /// A muted user.
    public let mutedUser: MutedUserPayload
    /// The current user.
    public let currentUser: CurrentUserPayload
}
