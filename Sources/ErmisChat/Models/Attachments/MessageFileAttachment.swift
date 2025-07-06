//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// A type alias for attachment with `FileAttachmentPayload` payload type.
///
/// The `MessageFileAttachment` attachment will be added to the message automatically
/// if the message was sent with attached `AnyAttachmentPayload` created with
/// local URL and `.file` attachment type.
public typealias MessageFileAttachment = MessageAttachment<FileAttachmentPayload>

/// Represents a payload for attachments with `.file` type.
public struct FileAttachmentPayload: AttachmentPayload {
    /// An attachment type all `FileAttachmentPayload` instances conform to. Is set to `.file`.
    public static let type: AttachmentType = .file

    /// A title, usually the name of the file.
    public var title: String?
    /// A link to the file.
    public var assetURL: URL
    /// The file itself.
    public var file: AttachmentFile

    /// Creates `FileAttachmentPayload` instance.
    ///
    /// Use this initializer if the attachment is already uploaded and you have the remote URLs.
    public init(title: String?,
                assetRemoteURL: URL,
                file: AttachmentFile) {
        self.title = title
        assetURL = assetRemoteURL
        self.file = file
    }
}

extension FileAttachmentPayload: Hashable {}

// MARK: - Encodable

extension FileAttachmentPayload: Encodable {
    public func encode(to encoder: Encoder) throws {
        var values: [String: RawJSON] = [:]
        values[AttachmentCodingKeys.title.rawValue] = title.map { .string($0) }
        values[AttachmentCodingKeys.assetURL.rawValue] = .string(assetURL.absoluteString)
        values[AttachmentFile.CodingKeys.size.rawValue] = .number(Double(file.size))
        values[AttachmentFile.CodingKeys.mimeType.rawValue] = file.mimeType.map { .string($0) }
        try values.encode(to: encoder)
    }
}

// MARK: - Decodable

extension FileAttachmentPayload: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AttachmentCodingKeys.self)

        self.init(
            title: try container.decodeIfPresent(String.self, forKey: .title),
            assetRemoteURL: try container.decode(URL.self, forKey: .assetURL),
            file: try AttachmentFile(from: decoder)
        )
    }
}
