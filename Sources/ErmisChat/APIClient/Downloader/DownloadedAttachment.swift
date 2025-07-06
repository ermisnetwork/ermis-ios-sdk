//
// Copyright 2025 Ermis Inc.
//

import Foundation
import UIKit
import UniformTypeIdentifiers

public enum DownloadAttachmentPayload {
    case messageAttachment(AnyMessageAttachment)
    case channelAttachment(ChannelAttachmentPayload)

    var id: String {
        switch self {
        case .messageAttachment(let messageAttachment):
            return messageAttachment.id.rawValue
        case .channelAttachment(let channelAttachment):
            return channelAttachment.id
        }
    }

    var url: URL? {
        switch self {
        case .messageAttachment(let messageAttachment):
            return messageAttachment.remoteURL
        case .channelAttachment(let channelAttachment):
            guard let urlString = channelAttachment.url,
                  let url = URL(string: urlString) else {
                return nil
            }
            return url
        }
    }

    var name: String {
        switch self {
        case .messageAttachment(let messageAttachment):
            return messageAttachment.title ?? UUID().uuidString
        case .channelAttachment(let channelAttachment):
            return channelAttachment.fileName
        }
    }

    var pathExtension: String? {
        switch self {
        case .messageAttachment(let messageAttachment):
            guard let mimeType = messageAttachment.mimetype,
                  let utType = UTType(mimeType: mimeType) else {
                return nil
            }
            return utType.preferredFilenameExtension
        case .channelAttachment(let channelAttachment):
            return channelAttachment.fileType.rawValue
        }
    }

    var isImage: Bool {
        switch self {
        case .messageAttachment(let messageAttachment):
            return messageAttachment.type == .image
        case .channelAttachment(let channelAttachment):
            return channelAttachment.isImage
        }
    }

    var isVideo: Bool {
        switch self {
        case .messageAttachment(let messageAttachment):
            return messageAttachment.type == .video
        case .channelAttachment(let channelAttachment):
            return channelAttachment.isVideo
        }
    }
}

public struct DownloadedAttachment {
    public var attachment: DownloadAttachmentPayload
    public var data: Data

    public var temporaryURL: URL? {
        guard let pathExtension = attachment.pathExtension else {
            return nil
        }
        let fileName = attachment.name + "." + pathExtension
        let documentDirectory = NSTemporaryDirectory()
        let localPath = documentDirectory.appending(fileName)
        let temporaryURL = URL(fileURLWithPath: localPath)
        do {
            try data.write(to: temporaryURL)
        } catch {
            return nil
        }
        return temporaryURL
    }

    func pathExtension(of mimeType: String) -> String? {
        guard let utType = UTType(mimeType: mimeType) else {
            return nil
        }
        return utType.preferredFilenameExtension
    }
}

struct AttachmentsDownloadResult {
    let id: String
    var attachments: [AnyMessageAttachment] = []
    var results: [Result<DownloadedAttachment, Error>]

    var isFinished: Bool {
        return results.count == attachments.count
    }

    init(with attachments: [AnyMessageAttachment]) {
        id = UUID().uuidString
        self.attachments = attachments
        results = []
    }
}
