//
// Copyright 2025 Ermis Inc.
//

public struct CloseAndReopenTopic: Codable {
    enum CodingKeys: String, CodingKey {
        case projectId = "project_id"
        case topicId = "topic_cid"
    }
    
    public let projectId: String
    public let topicId: String

    init(projectId: String, topicId: String) {
        self.projectId = projectId
        self.topicId = topicId
    }

    public
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.projectId, forKey: .projectId)
        try container.encode(self.topicId, forKey: .topicId)
    }
}
