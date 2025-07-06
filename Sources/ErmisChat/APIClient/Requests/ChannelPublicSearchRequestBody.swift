//
// Copyright 2025 Ermis Inc.
//

import Foundation

public
struct ChannelPublicSearchRequestBody: Encodable {
    let projectId: String
    let searchTerm: String
    let limit: Int
    let offset: Int

    enum CodingKeys: String, CodingKey {
        case projectId = "project_id"
        case searchTerm = "search_term"
        case limit
        case offset
    }

    public
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.projectId, forKey: .projectId)
        try container.encode(self.searchTerm, forKey: .searchTerm)
        try container.encode(self.limit, forKey: .limit)
        try container.encode(self.offset, forKey: .offset)
    }
}
