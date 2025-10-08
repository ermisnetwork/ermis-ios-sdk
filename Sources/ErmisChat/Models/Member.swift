//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// A type representing a chat channel member. `ChannelMember` is an immutable snapshot of a channel entity at the given time.
public class ChannelMember: ChatUser {
    /// The role of the user within the channel.
    public let memberRole: MemberRole

    /// The date the user was added to the channel.
    public let memberCreatedAt: Date?

    /// The date the membership was updated for the last time.
    public let memberUpdatedAt: Date?

    /// Returns `true` if the member has been invited to the channel.
    public var isInvited: Bool {
        return memberRole != .pending
    }

    /// If the member accepted a channel invitation, this field contains date of when the invitation was accepted,
    /// otherwise it's `nil`.
    public let inviteAcceptedAt: Date?

    /// If the member rejected a channel invitation, this field contains date of when the invitation was rejected,
    /// otherwise it's `nil`.
    public let inviteRejectedAt: Date?

    /// `true` if the member if banned from the channel.
    public let isBannedFromChannel: Bool

    /// `true` if the member is blocked from the channel.
    public let isBlockedFromChannel: Bool

    /// If the member is banned from the channel, this field contains the date when the ban expires.
    ///
    public let banExpiresAt: Date?

    /// `true` if the member if shadow banned from the channel.
    ///
    public let isShadowBannedFromChannel: Bool

    /// A date that channel will umMute.
    public var muted: Date?

    /// A boolean value that returns whether the user has enable notification for this channel or not.
    public var notificationEnable: Bool {
        guard let muted else {
            return true
        }
        return Date() > muted
    }

    init(
        id: String,
        projectId: String,
        name: String?,
        imageURL: URL?,
        phone: String?,
        email: String?,
        isOnline: Bool,
        isBanned: Bool,
        isFlaggedByCurrentUser: Bool,
        userRole: UserRole,
        userCreatedAt: Date?,
        userUpdatedAt: Date?,
        deactivatedAt: Date?,
        lastActiveAt: Date?,
        teams: Set<TeamId>,
        language: TranslationLanguage?,
        memberRole: MemberRole,
        memberCreatedAt: Date?,
        memberUpdatedAt: Date?,
//        isInvited: Bool,
        inviteAcceptedAt: Date?,
        inviteRejectedAt: Date?,
        isBannedFromChannel: Bool,
        isBlockedFromChannel: Bool,
        banExpiresAt: Date?,
        isShadowBannedFromChannel: Bool,
        muted: Date?
    ) {
        self.memberRole = memberRole
        self.memberCreatedAt = memberCreatedAt
        self.memberUpdatedAt = memberUpdatedAt
        self.inviteAcceptedAt = inviteAcceptedAt
        self.inviteRejectedAt = inviteRejectedAt
        self.isBannedFromChannel = isBannedFromChannel
        self.isBlockedFromChannel = isBlockedFromChannel
        self.isShadowBannedFromChannel = isShadowBannedFromChannel
        self.banExpiresAt = banExpiresAt
        self.muted = muted

        super.init(
            id: id,
            projectId: projectId,
            name: name,
            imageURL: imageURL,
            phone: phone,
            email: email,
            isOnline: isOnline,
            isBanned: isBanned,
            isFlaggedByCurrentUser: isFlaggedByCurrentUser,
            userRole: userRole,
            createdAt: userCreatedAt,
            updatedAt: userUpdatedAt,
            deactivatedAt: deactivatedAt,
            lastActiveAt: lastActiveAt,
            teams: teams,
            language: language
        )
    }

    // Equaltable
    public override func isEqual(to chatUser: ChatUser) -> Bool {
        var result = super.isEqual(to: chatUser)
        if let member = chatUser as? ChannelMember {
            result = result && muted == member.muted
        }
        return result
    }
}

/// A  `struct` describing roles of a member in a channel.
/// There are some predefined types but any type can be introduced and sent by the backend.
public struct MemberRole: RawRepresentable, Codable, Hashable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}

public extension MemberRole {
    /// This is the default role assigned to any member.
    static let member = Self(rawValue: "member")

    /// Allows the member to perform moderation, e.g. ban users, add/remove users, etc.
    static let moderator = Self(rawValue: "moder")

    /// This role allows the member to perform more advanced actions. This role should be granted only to staff users.
    static let admin = Self(rawValue: "admin")

    /// This role allows the member to perform destructive actions on the channel.
    static let owner = Self(rawValue: "owner")

    /// This role when the member is invited to the channel.
    static let pending = Self(rawValue: "pending")

    /// This role when member skip invitation.
    static let skipped = Self(rawValue: "skipped")

    /// This role when the member rejected invite to the direct channel.
    static let rejected = Self(rawValue: "rejected")

    static let allMembers: [MemberRole] = [
        .member,
        .moderator,
        .admin,
        .owner
    ]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "member", "channel_member":
            self = .member
        case "moderator", "channel_moderator":
            self = .moderator
        case "admin":
            self = .admin
        case "owner":
            self = .owner
        case "pending":
            self = .pending
        case "skipped":
            self = .skipped
        case "rejected":
            self = .rejected
        default:
            self = MemberRole(rawValue: value)
        }
    }
}

public
extension ChannelMember {
    var isModerator: Bool {
        return memberRole == .admin || memberRole == .moderator || memberRole == .owner
    }

    var isJoined: Bool {
        return isModerator || memberRole == .member
    }
}
