//
// Copyright 2025 Ermis Inc.
//

import Foundation

public 
struct ChannelSearchRequestPayload: Encodable {
    let cid: String
    let searchTerm: String
    let limit: Int
    let offset: Int

    enum CodingKeys: String, CodingKey {
        case cid
        case searchTerm = "search_term"
        case limit
        case offset
    }

    public
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.cid, forKey: .cid)
        try container.encode(self.searchTerm, forKey: .searchTerm)
        try container.encode(self.limit, forKey: .limit)
        try container.encode(self.offset, forKey: .offset)
    }
}
