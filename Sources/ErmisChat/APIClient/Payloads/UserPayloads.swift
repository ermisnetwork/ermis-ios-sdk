//
// Copyright 2025 Ermis Inc.
//

import Foundation

enum UserPayloadsCodingKeys: String, CodingKey, CaseIterable {
    case id
    case projectId = "project_id"
    case name
    case imageURL = "avatar"
    case role
    case isOnline = "online"
    case isBanned = "banned"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case deactivatedAt = "deactivated_at"
    case lastActiveAt = "last_active"
    case isInvisible = "invisible"
    case teams
    case unreadChannelsCount = "unread_channels"
    case unreadMessagesCount = "total_unread_count"
    case mutedUsers = "mutes"
    case isAnonymous = "anon"
    case devices
    case unreadCount = "unread_count"
    case language
    case isEmailVerified
    case bellBoyId = "bellboy_id"
    case aboutMe = "about_me"
    case phone
    case email
}

// MARK: - GET users

/// An object describing the incoming user JSON payload.
class UserPayload: Decodable {
    let id: String
    let projectId: String
    let name: String?
    let imageURL: URL?
    var phone: String?
    let email: [String]?
    let role: UserRole?
    let createdAt: Date?
    let updatedAt: Date?
    let deactivatedAt: Date?
    let lastActiveAt: Date?
    let isOnline: Bool?
    let isInvisible: Bool?
    let isBanned: Bool?
    let teams: [TeamId]
    let language: String?
    let isEmailVerified: Bool
    let bellBoyId: String
    let aboutMe: String

    var userId: String {
        if id.hasSuffix(projectId) {
            return String(id.dropLast(projectId.count))
        }
        return id
    }

    init(
        id: String,
        projectId: String,
        name: String?,
        imageURL: URL?,
        phone: String?,
        email: [String],
        role: UserRole,
        createdAt: Date?,
        updatedAt: Date?,
        deactivatedAt: Date?,
        lastActiveAt: Date?,
        isOnline: Bool?,
        isInvisible: Bool,
        isBanned: Bool,
        teams: [TeamId] = [],
        language: String?,
        isEmailVerified: Bool,
        bellBoyId: String,
        aboutMe: String
    ) {
        self.id = id
        self.projectId = projectId
        self.name = name
        self.imageURL = imageURL
        self.role = role
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deactivatedAt = deactivatedAt
        self.lastActiveAt = lastActiveAt
        self.isOnline = isOnline
        self.isInvisible = isInvisible
        self.isBanned = isBanned
        self.teams = teams
        self.language = language
        self.isEmailVerified = false
        self.bellBoyId = bellBoyId
        self.aboutMe = aboutMe
        self.phone = phone
        self.email = email
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: UserPayloadsCodingKeys.self)
        
        id = try container.decode(String.self, forKey: .id)
        projectId = try container.decodeIfPresent(String.self, forKey: .projectId) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name)
        imageURL = try container.decodeIfPresent(String.self, forKey: .imageURL).flatMap(URL.init(string:))
        phone = try container.decodeIfPresent(String.self, forKey: .phone)
        email = try container.decodeIfPresent([String].self, forKey: .email)
        role = try container.decodeIfPresent(UserRole.self, forKey: .role)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        deactivatedAt = try container.decodeIfPresent(Date.self, forKey: .deactivatedAt)
        lastActiveAt = try? container.decodeIfPresent(Date.self, forKey: .lastActiveAt)
        isOnline = try container.decodeIfPresent(Bool.self, forKey: .isOnline)
        isInvisible = try container.decodeIfPresent(Bool.self, forKey: .isInvisible)
        isBanned = try container.decodeIfPresent(Bool.self, forKey: .isBanned)
        teams = try container.decodeIfPresent([String].self, forKey: .teams) ?? []
        language = try container.decodeIfPresent(String.self, forKey: .language)
        isEmailVerified = try container.decodeIfPresent(Bool.self, forKey: .isEmailVerified) ?? false
        bellBoyId = try container.decodeIfPresent(String.self, forKey: .bellBoyId) ?? ""
        aboutMe = try container.decodeIfPresent(String.self, forKey: .aboutMe) ?? ""
    }
}

/// An object describing the outgoing user JSON payload.
class UserRequestBody: Encodable {
    let id: String
    let name: String?
    let imageURL: URL?

    init(id: String, name: String?, imageURL: URL?) {
        self.id = id
        self.name = name
        self.imageURL = imageURL
    }

    init(from chatUser: ChatUser) {
        self.id = chatUser.userId
        self.name = chatUser.name
        self.imageURL = chatUser.imageURL
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: UserPayloadsCodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(imageURL, forKey: .imageURL)
    }
}

// MARK: - PATCH users

/// An object describing the incoming user JSON payload.
struct UserUpdateResponse: Decodable {
    let user: UserPayload

    enum CodingKeys: String, CodingKey {
        case users
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let users = try container.decode([String: UserPayload].self, forKey: .users)
        guard let user = users.first?.value else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [CodingKeys.users], debugDescription: "Missing updated user.")
            )
        }
        self.user = user
    }

    init(user: UserPayload) {
        self.user = user
    }
}

/// An object describing the outgoing user JSON payload.
struct UserUpdateRequestBody: Encodable {
    let name: String?
    let imageURL: URL?
    let phone: String?

    init(name: String? = nil,
         imageURL: URL? = nil,
         phone: String? = nil) {

        self.name = name
        self.imageURL = imageURL
        self.phone = phone
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: UserPayloadsCodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(imageURL, forKey: .imageURL)
        try container.encodeIfPresent(phone, forKey: .phone)
    }
}
