//
// Copyright 2025 Ermis Inc.
//

import Foundation

public struct UserBatchRequestPayload: Encodable {
    let users: [String]
    let projectId: String

    init(users: [String], projectId: String) {
        self.users = users
        self.projectId = projectId
    }

    public enum CodingKeys: String, CodingKey {
        case users
        case projectId = "project_id"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.users, forKey: .users)
        try container.encode(self.projectId, forKey: .projectId)
    }
}
