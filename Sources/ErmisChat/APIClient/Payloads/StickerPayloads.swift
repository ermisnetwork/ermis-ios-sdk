//
// Copyright 2025 Ermis Inc.
//

import Foundation

enum CodingKeys: String, CodingKey {
    case id
    case packs
    case url
    case body
    case data
    case title
    case telegram
    case shortName = "short_name"
    case stickers
    case hash
}

public struct StickerPackListPayload: Decodable {
    let packs: [String]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        packs = try container.decodeArrayIfPresentIgnoringFailures([String].self, forKey: .packs) ?? []
    }
}


public struct StickerPackPayload: Decodable {
    let id: String
    let title: String
    var stickers: [StickerPayload]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let telegram = try container.decode(TelegramPayload.self, forKey: .telegram)
        id = telegram.sortName + ".json"
        title = try container.decode(String.self, forKey: .title)
        stickers = try container.decodeArrayIgnoringFailures([StickerPayload].self, forKey: .stickers)
    }

    public init (id: String, title: String, stickers: [StickerPayload]) {
        self.id = id
        self.title = title
        self.stickers = stickers
    }
}

public struct TelegramPayload: Decodable {
    let sortName: String
    let hash: String

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sortName = try container.decode(String.self, forKey: .shortName)
        hash = try container.decode(String.self, forKey: .hash)
    }
}


public struct StickerPayload: Decodable {
    let id: String
    var url: String?
    let body: String?
    var data: Data?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        data = try container.decodeIfPresent(Data.self, forKey: .data)
    }
}
