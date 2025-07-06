//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// The type describes the incoming message-reaction JSON.
struct MessageReactionPayload: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case type
        case score
        case messageId = "message_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case user
        case userId = "user_id"
    }

    let type: MessageReactionType
    let score: Int
    let messageId: String
    let createdAt: Date
    let updatedAt: Date
    let user: UserPayload

    init(
        type: MessageReactionType,
        score: Int,
        messageId: String,
        createdAt: Date,
        updatedAt: Date,
        user: UserPayload
    ) {
        self.type = type
        self.score = score
        self.messageId = messageId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.user = user
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.init(
            type: try container.decode(MessageReactionType.self, forKey: .type),
            score: try container.decodeIfPresent(Int.self, forKey: .score) ?? 1,
            messageId: try container.decode(MessageId.self, forKey: .messageId),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            user: try container.decode(UserPayload.self, forKey: .user)
        )
    }
}
