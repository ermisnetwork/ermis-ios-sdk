//
// Copyright 2025 Ermis Inc.
//

import Foundation

struct ChannelSearchResultPayload: Decodable {
    let searchResult: ChannelSearchPayload

    enum CodingKeys: String, CodingKey {
        case searchResult = "search_result"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.searchResult = try container.decode(ChannelSearchPayload.self, forKey: .searchResult)
    }
}

public struct ChannelSearchPayload: Decodable {
    public var messages: [ChannelSearchMessagePayload]
    public var limit: Int
    public var offset: Int
    public var total: Int

    public
    var hasFinished: Bool {
        return offset + limit >= total
    }

    public
    init() {
        self.messages = []
        self.limit = 25
        self.offset = 0
        self.total = 0
    }

    enum CodingKeys: String, CodingKey {
        case messages
        case limit
        case offset
        case total
    }

    public
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.messages = try container.decode([ChannelSearchMessagePayload].self, forKey: .messages)
        self.limit = try container.decode(Int.self, forKey: .limit)
        self.offset = try container.decode(Int.self, forKey: .offset)
        self.total = try container.decode(Int.self, forKey: .total)
    }
}

public
struct ChannelSearchMessagePayload: Decodable {
    public let id: String
    public let text: String
    public let userId: String
    public let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case userId = "user_id"
        case createdAt = "created_at"
    }

    public
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.text = try container.decode(String.self, forKey: .text)
        self.userId = try container.decode(String.self, forKey: .userId)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}
