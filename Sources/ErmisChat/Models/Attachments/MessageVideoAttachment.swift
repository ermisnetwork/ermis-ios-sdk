//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// A type alias for attachment with `VideoAttachmentPayload` payload type.
///
/// The `MessageVideoAttachment` attachment will be added to the message automatically
/// if the message was sent with attached `AnyAttachmentPayload` created with
/// local URL and `.video` attachment type.
public typealias MessageVideoAttachment = MessageAttachment<VideoAttachmentPayload>

/// Represents a payload for attachments with `.media` type.
public struct VideoAttachmentPayload: AttachmentPayload {
    /// An attachment type all `MediaAttachmentPayload` instances conform to. Is set to `.video`.
    public static let type: AttachmentType = .video

    /// A title, usually the name of the video.
    public var title: String?
    /// A link to the video.
    public var videoURL: URL
    /// A link to the video thumbnail.
    public var thumbnailURL: URL?
    /// The video itself.
    public var file: AttachmentFile

    /// Creates `VideoAttachmentPayload` instance.
    ///
    /// Use this initializer if the attachment is already uploaded and you have the remote URLs.
    public init(title: String?,
                videoRemoteURL: URL,
                thumbnailURL: URL? = nil,
                file: AttachmentFile) {
        self.title = title
        videoURL = videoRemoteURL
        self.thumbnailURL = thumbnailURL
        self.file = file
    }
}

extension VideoAttachmentPayload: Hashable {}

// MARK: - Encodable

extension VideoAttachmentPayload: Encodable {
    public func encode(to encoder: Encoder) throws {
        var values: [String: RawJSON] = [:]
        values[AttachmentCodingKeys.title.rawValue] = title.map { .string($0) }
        values[AttachmentCodingKeys.assetURL.rawValue] = .string(videoURL.absoluteString)
        thumbnailURL.map {
            values[AttachmentCodingKeys.thumbURL.rawValue] = .string($0.absoluteString)
        }
        values[AttachmentFile.CodingKeys.size.rawValue] = .number(Double(file.size))
        values[AttachmentFile.CodingKeys.mimeType.rawValue] = file.mimeType.map { .string($0) }
        try values.encode(to: encoder)
    }
}

// MARK: - Decodable

extension VideoAttachmentPayload: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AttachmentCodingKeys.self)

        self.init(
            title: try container.decodeIfPresent(String.self, forKey: .title),
            videoRemoteURL: try container.decode(URL.self, forKey: .assetURL),
            thumbnailURL: try container.decodeIfPresent(URL.self, forKey: .thumbURL),
            file: try AttachmentFile(from: decoder)
        )
    }
}
