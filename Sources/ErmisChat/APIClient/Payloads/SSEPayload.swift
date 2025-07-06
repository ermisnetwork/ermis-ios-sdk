//
// Copyright 2025 Ermis Inc.
//

import Foundation

struct SSEPayload: Decodable {
    let type: SSEMessageType
    let message: String?
    let user: UserPayload?

    enum CodingKeys: CodingKey {
        case type
        case message
        case user
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decode(SSEMessageType.self, forKey: .type)
        self.message = try container.decodeIfPresent(String.self, forKey: .message)
        self.user = try? UserPayload(from: decoder)
    }

}

enum SSEMessageType: String, Decodable {
    case healthcheck = "health.check"
    case account = "AccountUserChainProjects"
}
