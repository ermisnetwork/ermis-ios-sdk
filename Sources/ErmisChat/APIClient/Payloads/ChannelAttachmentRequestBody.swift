//
// Copyright 2025 Ermis Inc.
//

import Foundation

public struct ChannelAttachmentRequestBody: Encodable {
    public let attachmentTypes: [ChannelAttachmentType]

    public init(attachmentTypes: [ChannelAttachmentType]) {
        self.attachmentTypes = attachmentTypes
    }

    enum CodingKeys: String, CodingKey {
        case attachmentTypes = "attachment_types"
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.attachmentTypes, forKey: .attachmentTypes)
    }
}

public enum ChannelAttachmentType: String, Codable {
    case image
    case video
    case file
    case linkPreview
    case voiceRecording
}
