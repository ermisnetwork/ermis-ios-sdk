//
// Copyright 2025 Ermis Inc.
//

import Foundation

public struct ErmisProjectPayload: Codable {
    public let projectName: String
    public let projectId: String
    public let display: String
    public let image: String?
    public let description: String

    enum CodingKeys: String, CodingKey {
        case projectName = "project_name"
        case projectId = "project_id"
        case display
        case image
        case description
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.projectName = try container.decode(String.self, forKey: .projectName)
        self.projectId = try container.decode(String.self, forKey: .projectId)
        self.display = try container.decode(String.self, forKey: .display)
        self.image = try container.decodeIfPresent(String.self, forKey: .image)
        self.description = try container.decode(String.self, forKey: .description)
    }
}
