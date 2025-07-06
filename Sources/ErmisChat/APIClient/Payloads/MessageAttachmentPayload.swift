//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// A type that describes attachment JSON payload.
struct MessageAttachmentPayload {
    private enum CodingKeys: String, CodingKey {
        case type
        case linkURL = "link_url"
    }

    /// An attachment type.
    let type: AttachmentType
    /// A raw attachment payload data.
    /// It's possible to have attachments of custom type with unknown structure
    /// so we need to keep in raw data form so it will be possible to decode later.
    let payload: RawJSON
}

extension MessageAttachmentPayload: Encodable {
    func encode(to encoder: Encoder) throws {
        var payload = self.payload
        payload[AttachmentCodingKeys.type.rawValue] = .string(type.rawValue)
        try payload.encode(to: encoder)
    }
}

extension MessageAttachmentPayload: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let attachmentType: AttachmentType = try {
            if container.contains(.linkURL) {
                return .linkPreview
            } else if let type = try container.decodeIfPresent(AttachmentType.self, forKey: .type) {
                return type
            } else {
                return .unknown
            }
        }()

        var payload = try decoder.singleValueContainer().decode(RawJSON.self)

        guard payload.dictionaryValue != nil else {
            throw ClientError.AttachmentDecoding("Payload must be keyed container")
        }

        payload[AttachmentCodingKeys.type.rawValue] = nil

        self.init(
            type: attachmentType,
            payload: payload
        )
    }
}
