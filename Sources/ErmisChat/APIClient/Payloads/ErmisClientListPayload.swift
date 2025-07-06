//
// Copyright 2025 Ermis Inc.
//

import Foundation

public struct ErmisClientPayload: Codable {
    public var clientName: String
    public var clientId: String
    public var clientImage: String?
    public var projects: [ErmisProjectPayload]

    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case clientName = "client_name"
        case clientImage = "client_image"
        case projects
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.clientId = try container.decode(String.self, forKey: .clientId)
        self.clientName = try container.decode(String.self, forKey: .clientName)
        self.clientImage = try container.decodeIfPresent(String.self, forKey: .clientImage)
        self.projects = try container.decode([ErmisProjectPayload].self, forKey: .projects)
    }
}
