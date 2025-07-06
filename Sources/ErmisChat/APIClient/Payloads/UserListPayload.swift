//
// Copyright 2025 Ermis Inc.
//

import Foundation

struct UserListPayload: Decodable {
    /// A list of users response (see `UserListQuery`).
    let users: [UserPayload]
    let page: Int
    let count: Int
    let pageCount: Int
    let resultCount: Int

    enum CodingKeys: String, CodingKey {
        case users = "data"
        case page
        case count
        case pageCount = "page_count"
        case resultCount = "total"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.users = try container.decode([UserPayload].self, forKey: .users)
        self.page = try container.decode(Int.self, forKey: .page)
        self.count = try container.decode(Int.self, forKey: .count)
        self.pageCount = try container.decode(Int.self, forKey: .pageCount)
        self.resultCount = try container.decode(Int.self, forKey: .resultCount)
    }
}
