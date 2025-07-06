//
// Copyright 2025 Ermis Inc.
//

import Foundation

public class FriendContactListPayload: Decodable {

    public let projectUserIds: [String: [FriendContactPayload]]

    enum CodingKeys: String, CodingKey {
        case projectUserIds = "project_id_user_ids"
    }

    required public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.projectUserIds = try container.decode([String: [FriendContactPayload]].self, forKey: .projectUserIds)
    }

}

public class FriendContactPayload: Decodable {
    public let userId: String
    public let otherId: String
    public let projectId: String
    public let relationStatus: RelationStatus
    public let createdAt: Date
    public let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case otherId = "other_id"
        case projectId = "project_id"
        case relationStatus = "relation_status"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    required public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.userId = try container.decode(String.self, forKey: .userId)
        self.otherId = try container.decode(String.self, forKey: .otherId)
        self.projectId = try container.decode(String.self, forKey: .projectId)
        self.relationStatus = try container.decode(RelationStatus.self, forKey: .relationStatus)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

public
enum RelationStatus: String, Decodable {
    case normal
    case blocked
}
