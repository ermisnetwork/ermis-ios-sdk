//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// A type alias for attachment with `VoiceRecordingAttachmentPayload` payload type.
///
/// The `MessageVoiceRecordingAttachment` attachment will be added to the message
/// automatically if the message was sent with attached `AnyAttachmentPayload` created with
/// local URL and `.voiceRecording` attachment type.
public typealias MessageVoiceRecordingAttachment = MessageAttachment<VoiceRecordingAttachmentPayload>

/// Represents a payload for attachments with `.voiceRecording` type.
public struct VoiceRecordingAttachmentPayload: AttachmentPayload {
    /// An attachment type all `VoiceRecordingAttachmentPayload` instances conform to.
    /// Is set to `.voiceRecording`.
    public static let type: AttachmentType = .voiceRecording

    /// A title, usually the name of the voiceRecording.
    public var title: String?
    /// A link to the voiceRecording.
    public var voiceRecordingURL: URL
    /// The voiceRecording itself.
    public var file: AttachmentFile
    /// The duration of the attached Audio file
    public var duration: TimeInterval?
    /// The waveformData that can be used to create waveform visualisation of the attached Audio file
    public var waveformData: [Float]?

    /// Creates `VoiceRecordingAttachmentPayload` instance.
    ///
    /// Use this initializer if the attachment is already uploaded and you have the remote URLs.
    public init(
        title: String?,
        voiceRecordingRemoteURL: URL,
        file: AttachmentFile,
        duration: TimeInterval?,
        waveformData: [Float]?
    ) {
        self.title = title
        voiceRecordingURL = voiceRecordingRemoteURL
        self.file = file
        self.duration = duration
        self.waveformData = waveformData
    }
}

extension VoiceRecordingAttachmentPayload: Hashable {}

extension VoiceRecordingAttachmentPayload {
    public enum CodingKeys: String, CodingKey {
        case duration
        case waveformData = "waveform_data"
    }
}

// MARK: - Encodable

extension VoiceRecordingAttachmentPayload: Encodable {
    public func encode(to encoder: Encoder) throws {
        var values: [String: RawJSON] = [:]
        values[AttachmentCodingKeys.title.rawValue] = title.map { .string($0) }
        values[AttachmentCodingKeys.assetURL.rawValue] = .string(voiceRecordingURL.absoluteString)
        values[AttachmentFile.CodingKeys.size.rawValue] = .number(Double(file.size))
        values[AttachmentFile.CodingKeys.mimeType.rawValue] = file.mimeType.map { .string($0) }
        values[VoiceRecordingAttachmentPayload.CodingKeys.duration.rawValue] = duration.map { .number(Double($0)) }
        values[VoiceRecordingAttachmentPayload.CodingKeys.waveformData.rawValue] = waveformData.map { waveformData in .array(waveformData.map { .number(Double($0)) }) }
        try values.encode(to: encoder)
    }
}

// MARK: - Decodable

extension VoiceRecordingAttachmentPayload: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AttachmentCodingKeys.self)
        let voiceRecordingContainer = try decoder.container(keyedBy: CodingKeys.self)

        self.init(
            title: try container.decodeIfPresent(String.self, forKey: .title),
            voiceRecordingRemoteURL: try container.decode(URL.self, forKey: .assetURL),
            file: try AttachmentFile(from: decoder),
            duration: try voiceRecordingContainer.decodeIfPresent(TimeInterval.self, forKey: .duration),
            waveformData: try voiceRecordingContainer.decodeIfPresent([Float].self, forKey: .waveformData)
        )
    }
}
