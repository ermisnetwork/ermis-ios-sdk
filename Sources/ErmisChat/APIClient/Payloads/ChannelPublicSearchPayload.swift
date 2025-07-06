//
// Copyright 2025 Ermis Inc.
//

import UIKit

public struct ChannelListPublicSearchPayload: Codable {
    let channels: [ChannelPublicSearchPayload]
    let total: Int
    let limit: Int
    let offset: Int

    enum CodingKeys: CodingKey {
        case channels
        case total
        case limit
        case offset
    }

    public
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.channels = try container.decode([ChannelPublicSearchPayload].self, forKey: .channels)
        self.total = try container.decode(Int.self, forKey: .total)
        self.limit = try container.decode(Int.self, forKey: .limit)
        self.offset = try container.decode(Int.self, forKey: .offset)
    }

    struct Boxed: Decodable {
        let searchResult: ChannelListPublicSearchPayload

        enum CodingKeys: String, CodingKey {
            case searchResult = "search_result"
        }

        init(from decoder: any Decoder) throws {
            let container: KeyedDecodingContainer<ChannelListPublicSearchPayload.Boxed.CodingKeys> = try decoder.container(keyedBy: ChannelListPublicSearchPayload.Boxed.CodingKeys.self)
            self.searchResult = try container.decode(ChannelListPublicSearchPayload.self, forKey: ChannelListPublicSearchPayload.Boxed.CodingKeys.searchResult)
        }
    }
}

public struct ChannelPublicSearchPayload: Codable {
    let cid: ChannelId
    let name: String
    let image: String
    let description: String
    let createdAt: Date
    let ceratedBy: String

    enum CodingKeys: String, CodingKey {
        case cid
        case name
        case image
        case description
        case createdAt = "created_at"
        case ceratedBy = "created_by"
    }

    public
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.cid = try container.decode(ChannelId.self, forKey: .cid)
        self.name = try container.decode(String.self, forKey: .name)
        self.image = try container.decode(String.self, forKey: .image)
        self.description = try container.decode(String.self, forKey: .description)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.ceratedBy = try container.decode(String.self, forKey: .ceratedBy)
    }
}
