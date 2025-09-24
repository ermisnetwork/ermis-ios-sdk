//
// Copyright 2025 Ermis Inc.
//

import Foundation

public struct ChannelAttachmentListPayload: Decodable {
    public let attachments: [ChannelAttachmentPayload]
}

public struct ChannelAttachmentPayload: Decodable {
    public let id: String
    public let attachmentType: ChannelAttachmentType
    public let userId: String
    public let cid: ChannelId
    public let url: String?
    public let thumbUrl: String?
    public let fileName: String
    public let contentType: String
    public let contentLength: Int
    public let contentDiposition: String
    public let messageId: String
    public let createAt: Date?
    public let updatedAt: Date?
    public let fileType: AttachmentFileType
    public var user: ChatUser?

    public var isMedia: Bool {
        switch fileType {
        case .mov, .avi, .wmv, .webm:
            return true
        case .jpeg, .png, .gif, .bmp, .webp:
            return true
        default:
            return false
        }
    }

    public var isImage: Bool {
        switch fileType {
        case .jpeg, .png, .gif, .bmp, .webp:
            return true
        default:
            return false
        }
    }

    public var isVideo: Bool {
        switch fileType {
            // We can not open .avi, show view it as a file
        case .mov, .wmv, .webm:
            return true
        default:
            return false
        }
    }

    public var isGif: Bool {
        switch fileType {
        case .gif:
            return true
        default:
            return false
        }
    }

    public var isFile: Bool {
        // Can not play .avi, show view it as a file.
        switch fileType {
        case .generic, .doc, .docx, .pdf, .ppt, .pptx, .tar, .xls, .zip, .x7z, .xz, .ods, .odt, .xlsx, .avi:
            return true
        default:
            return false
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case attachmentType = "attachment_type"
        case userId = "user_id"
        case cid
        case url
        case thumbUrl = "thumb_url"
        case fileName = "file_name"
        case contentType = "content_type"
        case contentLength = "content_length"
        case contentDiposition = "content_disposition"
        case messageId = "message_id"
        case createAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.attachmentType = try container.decodeIfPresent(ChannelAttachmentType.self, forKey: .attachmentType) ?? .file
        self.userId = try container.decode(String.self, forKey: .userId)
        self.cid = try container.decode(ChannelId.self, forKey: .cid)
        self.url = try container.decodeIfPresent(String.self, forKey: .url)
        self.thumbUrl = try container.decodeIfPresent(String.self, forKey: .thumbUrl)
        self.fileName = try container.decode(String.self, forKey: .fileName)
        self.contentType = try container.decode(String.self, forKey: .contentType)
        self.contentLength = try container.decode(Int.self, forKey: .contentLength)
        self.contentDiposition = try container.decode(String.self, forKey: .contentDiposition)
        self.messageId = try container.decode(String.self, forKey: .messageId)
        self.createAt = try container.decodeIfPresent(Date.self, forKey: .createAt)
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        self.fileType = AttachmentFileType(mimeType: contentType)
    }
}
