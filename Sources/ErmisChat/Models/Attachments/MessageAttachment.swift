//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// A type representing a chat message attachment.
/// `MessageAttachment<Payload>` is an immutable snapshot of message attachment at the given time.
@dynamicMemberLookup
public struct MessageAttachment<Payload> {
    /// The attachment identifier.
    public let id: AttachmentId

    /// The attachment type.
    public let type: AttachmentType

    /// The attachment payload.
    public var payload: Payload

    /// The uploading state of the attachment.
    ///
    /// Reflects uploading progress for local attachments that require file uploading.
    /// Is `nil` for local attachments that don't need to be uploaded.
    ///
    /// Becomes `nil` when the message with the current attachment is sent.
    public let uploadingState: AttachmentUploadingState?

    public init(
        id: AttachmentId,
        type: AttachmentType,
        payload: Payload,
        uploadingState: AttachmentUploadingState?
    ) {
        self.id = id
        self.type = type
        self.payload = payload
        self.uploadingState = uploadingState
    }
}

public extension MessageAttachment {
    subscript<T>(dynamicMember keyPath: KeyPath<Payload, T>) -> T {
        payload[keyPath: keyPath]
    }
}

extension MessageAttachment: Equatable where Payload: Equatable {}
extension MessageAttachment: Hashable where Payload: Hashable {}

/// A type representing the uploading state for attachments that require prior uploading.
public struct AttachmentUploadingState: Hashable {
    /// The local file URL that is being uploaded.
    public let localFileURL: URL

    /// The uploading state.
    public let state: LocalAttachmentState

    /// The information about file size/mimeType.
    public let file: AttachmentFile
}

// MARK: - Type erasure/recovery

public typealias AnyMessageAttachment = MessageAttachment<Data>

public extension AnyMessageAttachment {
    /// Converts type-erased attachment to the attachment with the concrete payload.
    ///
    /// Attachment with the requested payload type will be returned if the type-erased payload
    /// has a `Payload` instance under the hood OR if it’s a `Data` that can be decoded as a `Payload`.
    ///
    /// - Parameter payloadType: The payload type the current type-erased attachment payload should be treated as.
    /// - Returns: The attachment with the requested payload type or `nil`.
    func attachment<PayloadData: AttachmentPayload>(
        payloadType: PayloadData.Type
    ) -> MessageAttachment<PayloadData>? {
        guard
            PayloadData.type == type || type == .unknown,
            let concretePayload = try? JSONDecoder.ermis.decode(PayloadData.self, from: payload)
        else { return nil }

        return .init(
            id: id,
            type: type,
            payload: concretePayload,
            uploadingState: uploadingState
        )
    }
}

// swiftlint:disable force_try
public extension MessageAttachment where Payload: AttachmentPayload {
    /// Returns an attachment matching `self` but payload casted to `Any`.
    var asAnyAttachment: AnyMessageAttachment {
        AnyMessageAttachment(
            id: id,
            type: type,
            payload: try! JSONEncoder.ermis.encode(payload),
            uploadingState: uploadingState
        )
    }
}

// swiftlint:enable force_try

public extension MessageAttachment where Payload: AttachmentPayload {
    func asAttachment<NewPayload: AttachmentPayload>(
        payloadType: NewPayload.Type
    ) -> MessageAttachment<NewPayload>? {
        guard
            let payloadData = try? JSONEncoder.ermis.encode(payload),
            let concretePayload = try? JSONDecoder.ermis.decode(NewPayload.self, from: payloadData)
        else {
            return nil
        }

        return .init(
            id: id,
            type: .file,
            payload: concretePayload,
            uploadingState: uploadingState
        )
    }
}

public extension AnyMessageAttachment {
    var title: String? {
        switch type {
        case .image:
            let imageAttachment = attachment(payloadType: ImageAttachmentPayload.self)
            return imageAttachment?.title
        case .video:
            let videoAttachment = attachment(payloadType: VideoAttachmentPayload.self)
            return videoAttachment?.title
        case .file:
            let fileAttachment = attachment(payloadType: FileAttachmentPayload.self)
            return fileAttachment?.title
        case .audio:
            let audioAttachment = attachment(payloadType: AudioAttachmentPayload.self)
            return audioAttachment?.title
        case .voiceRecording:
            let voiceAttachment = attachment(payloadType: VoiceRecordingAttachmentPayload.self)
            return voiceAttachment?.title
        case .linkPreview:
            let linkAttachment = attachment(payloadType: LinkAttachmentPayload.self)
            return linkAttachment?.title
        default:
            return nil
        }
    }

    var remoteURL: URL? {
        switch type {
        case .image:
            let imageAttachment = attachment(payloadType: ImageAttachmentPayload.self)
            return imageAttachment?.imageURL
        case .video:
            let videoAttachment = attachment(payloadType: VideoAttachmentPayload.self)
            return videoAttachment?.videoURL
        case .file:
            let fileAttachment = attachment(payloadType: FileAttachmentPayload.self)
            return fileAttachment?.assetURL
        case .audio:
            let audioAttachment = attachment(payloadType: AudioAttachmentPayload.self)
            return audioAttachment?.audioURL
        case .voiceRecording:
            let voiceAttachment = attachment(payloadType: VoiceRecordingAttachmentPayload.self)
            return voiceAttachment?.voiceRecordingURL
        case .linkPreview:
            let linkAttachment = attachment(payloadType: LinkAttachmentPayload.self)
            return linkAttachment?.url
        default:
            return nil
        }
    }

    var mimetype: String? {
        switch type {
        case .image:
            let imageAttachment = attachment(payloadType: ImageAttachmentPayload.self)
            return imageAttachment?.payload.file.mimeType
        case .video:
            let videoAttachment = attachment(payloadType: VideoAttachmentPayload.self)
            return videoAttachment?.payload.file.mimeType
        case .file:
            let fileAttachment = attachment(payloadType: FileAttachmentPayload.self)
            return fileAttachment?.payload.file.mimeType
        case .audio:
            let audioAttachment = attachment(payloadType: AudioAttachmentPayload.self)
            return audioAttachment?.payload.file.mimeType
        case .voiceRecording:
            let voiceAttachment = attachment(payloadType: VoiceRecordingAttachmentPayload.self)
            return voiceAttachment?.payload.file.mimeType
        default:
            return nil
        }
    }
}
