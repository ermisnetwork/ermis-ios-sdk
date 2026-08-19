//
// Copyright 2026 Ermis Inc.
//

import Foundation

struct StandardAttachmentPresignRequest: Encodable, Equatable {
    let fileName: String
    let contentType: String

    enum CodingKeys: String, CodingKey {
        case fileName = "file_name"
        case contentType = "content_type"
    }
}

struct StandardAttachmentPresignPayload: Decodable, Equatable {
    let attachmentId: String
    let uploadURL: URL
    let expiresInSeconds: Int

    enum CodingKeys: String, CodingKey {
        case attachmentId = "attachment_id"
        case uploadURL = "upload_url"
        case expiresInSeconds = "expires_in_secs"
    }
}

struct StandardAttachmentConfirmRequest: Encodable, Equatable {
    let attachmentId: String
    let fileName: String
    let contentType: String

    enum CodingKeys: String, CodingKey {
        case attachmentId = "attachment_id"
        case fileName = "file_name"
        case contentType = "content_type"
    }
}

struct StandardAttachmentConfirmPayload: Decodable, Equatable {
    let fileURL: URL

    enum CodingKeys: String, CodingKey {
        case fileURL = "file"
    }
}
