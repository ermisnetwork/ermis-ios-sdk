//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// A type alias for attachment with `ImageAttachmentPayload` payload type.
///
/// The `MessageImageAttachment` attachment will be added to the message automatically
/// if the message was sent with attached `AnyAttachmentPayload` created with
/// local URL and `.image` attachment type.
public typealias MessageImageAttachment = MessageAttachment<ImageAttachmentPayload>

/// Represents a payload for attachments with `.image` type.
public struct ImageAttachmentPayload: AttachmentPayload {
    /// An attachment type all `ImageAttachmentPayload` instances conform to. Is set to `.image`.
    public static let type: AttachmentType = .image

    /// A title, usually the name of the image.
    public var title: String?
    /// A link to the image.
    public var imageURL: URL
    /// The original width of the image in pixels.
    public var originalWidth: Double?
    /// The original height of the image in pixels.
    public var originalHeight: Double?
    /// The image itself.
    public var file: AttachmentFile
    /// The data of thumbnail image.
    public var thumbnailData: Data?

    /// Creates `ImageAttachmentPayload` instance.
    ///
    /// Use this initializer if the attachment is already uploaded and you have the remote URLs.
    public init(
        title: String?,
        imageRemoteURL: URL,
        file: AttachmentFile,
        thumbnailData: Data?,
        originalWidth: Double? = nil,
        originalHeight: Double? = nil
    ) {
        self.title = title
        imageURL = imageRemoteURL
        self.file = file
        self.thumbnailData = thumbnailData
        self.originalWidth = originalWidth
        self.originalHeight = originalHeight
    }

    public var isGif: Bool {
        return title?.hasSuffix(".gif") ?? false
    }
}

extension ImageAttachmentPayload: Hashable {}

// MARK: - Encodable

extension ImageAttachmentPayload: Encodable {
    public func encode(to encoder: Encoder) throws {
        var values: [String: RawJSON] = [:]
        values[AttachmentCodingKeys.title.rawValue] = title.map { .string($0) }
        values[AttachmentCodingKeys.imageURL.rawValue] = .string(imageURL.absoluteString)

        if let originalWidth = self.originalWidth, let originalHeight = self.originalHeight {
            values[AttachmentCodingKeys.originalWidth.rawValue] = .double(originalWidth)
            values[AttachmentCodingKeys.originalHeight.rawValue] = .double(originalHeight)
        }

        values[AttachmentFile.CodingKeys.size.rawValue] = .number(Double(file.size))
        values[AttachmentFile.CodingKeys.mimeType.rawValue] = file.mimeType.map { .string($0) }

        try values.encode(to: encoder)
    }
}

// MARK: - Decodable

extension ImageAttachmentPayload: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AttachmentCodingKeys.self)

        let imageURL = try
            container.decodeIfPresent(URL.self, forKey: .image) ??
            container.decodeIfPresent(URL.self, forKey: .imageURL) ??
            container.decode(URL.self, forKey: .assetURL)

        let title = (
            try container.decodeIfPresent(String.self, forKey: .title) ??
                container.decodeIfPresent(String.self, forKey: .fallback) ??
                container.decodeIfPresent(String.self, forKey: .name)
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        let thumbnailData = try container.decodeIfPresent(Data.self, forKey: .thumbnailData)
        let originalWidth = try container.decodeIfPresent(Double.self, forKey: .originalWidth)
        let originalHeight = try container.decodeIfPresent(Double.self, forKey: .originalHeight)
        let file = try AttachmentFile(from: decoder)
        self.init(
            title: title,
            imageRemoteURL: imageURL,
            file: file,
            thumbnailData: thumbnailData,
            originalWidth: originalWidth,
            originalHeight: originalHeight
        )
    }
}
