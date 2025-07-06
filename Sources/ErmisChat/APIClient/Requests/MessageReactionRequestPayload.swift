//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// The type describes the outgoing JSON to `message/[message_id]/reaction` endpoint
struct MessageReactionRequestPayload: Encodable {
    enum CodingKeys: String, CodingKey {
        case enforceUnique = "enforce_unique"
        case reaction
    }

    let enforceUnique: Bool
    let reaction: ReactionRequestPayload

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enforceUnique, forKey: .enforceUnique)
        try container.encode(reaction, forKey: .reaction)
    }
}

struct ReactionRequestPayload: Encodable {
    private enum CodingKeys: String, CodingKey {
        case type
        case score
    }

    let type: MessageReactionType
    let score: Int

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(score, forKey: .score)
    }
}
