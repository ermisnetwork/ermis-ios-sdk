//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// A type alias for attachment with `AudioAttachmentPayload` payload type.
///
/// The `MessageAudioAttachment` attachment will be added to the message automatically
/// if the message was sent with attached `AnyAttachmentPayload` created with
/// local URL and `.audio` attachment type.
public typealias MessageAudioAttachment = MessageAttachment<AudioAttachmentPayload>

/// Represents a payload for attachments with `.media` type.
public struct AudioAttachmentPayload: AttachmentPayload {
    /// An attachment type all `MediaAttachmentPayload` instances conform to. Is set to `.audio`.
    public static let type: AttachmentType = .audio

    /// A title, usually the name of the audio.
    public var title: String?
    /// A link to the audio.
    public var audioURL: URL
    /// The audio itself.
    public var file: AttachmentFile

    /// Creates `AudioAttachmentPayload` instance.
    ///
    /// Use this initializer if the attachment is already uploaded and you have the remote URLs.
    public init(title: String?,
                audioRemoteURL: URL,
                file: AttachmentFile) {
        self.title = title
        audioURL = audioRemoteURL
        self.file = file
    }
}

extension AudioAttachmentPayload: Hashable {}

// MARK: - Encodable

extension AudioAttachmentPayload: Encodable {
    public func encode(to encoder: Encoder) throws {
        var values: [String: RawJSON] = [:]
        values[AttachmentCodingKeys.title.rawValue] = title.map { .string($0) }
        values[AttachmentCodingKeys.assetURL.rawValue] = .string(audioURL.absoluteString)
        values[AttachmentFile.CodingKeys.size.rawValue] = .number(Double(file.size))
        values[AttachmentFile.CodingKeys.mimeType.rawValue] = file.mimeType.map { .string($0) }
        try values.encode(to: encoder)
    }
}

// MARK: - Decodable

extension AudioAttachmentPayload: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AttachmentCodingKeys.self)

        self.init(
            title: try container.decodeIfPresent(String.self, forKey: .title),
            audioRemoteURL: try container.decode(URL.self, forKey: .assetURL),
            file: try AttachmentFile(from: decoder)
        )
    }
}
