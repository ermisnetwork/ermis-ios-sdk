//
// Copyright 2025 Ermis Inc.
//

import Foundation

/// A protocol an attachment payload type has to conform in order it can be
/// attached to/exposed on the message.
public protocol AttachmentPayload: Codable {
    /// A type of resulting attachment.
    static var type: AttachmentType { get }
}

/// A type-erased type that wraps either a local file URL that has to be uploaded
/// and attached to the message OR a custom payload which the message attachment
/// should contain.
public struct AnyAttachmentPayload {
    /// A type of attachment that will be created when the message is sent.
    public let type: AttachmentType
    
    /// The asset identifier
    public let assetId: String?

    /// A payload that will exposed on attachment when the message is sent.
    public let payload: Encodable

    /// A URL referencing to the local file that should be uploaded.
    public let localFileURL: URL?

    /// The data of thumbnail Image
    public let thumbnailData: Data?
    /// The size of attachment
    public let fileSize: Int?

    init(
        type: AttachmentType,
        assetId: String? = nil,
        payload: Encodable,
        localFileURL: URL? = nil,
        thumbnailData: Data? = nil,
        fileSize: Int? = nil
    ) {
        self.type = type
        self.assetId = assetId
        self.payload = payload
        self.localFileURL = localFileURL
        self.thumbnailData = thumbnailData
        self.fileSize = fileSize
    }
}

/// Local Metadata related to an attachment.
/// It is used to describe additional information of a local attachment.
public struct AnyAttachmentLocalMetadata {
    /// The asset identifier of PHAsset item.
    public var assetId: String?

    /// The title of attachment.
    public var title: String?

    /// The authenticated/detected MIME type of the local attachment.
    public var mimeType: String?

    /// The original width and height of an image or video attachment in Pixels.
    public var originalResolution: (width: Double, height: Double)?

    /// The duration of a media file
    public var duration: TimeInterval?

    /// The data that can be used to render a waveform visualisation of an audio file.
    public var waveformData: [Float]?

    /// The file size
    public var fileSize: Int?

    /// The data of thumbnail Image.
    public var thumbnailData: Data?

    public init() {}
}

public extension AnyAttachmentPayload {
    /// Creates an instance of `AnyAttachmentPayload` with the given payload.
    ///
    /// - Important: This initializer should only be used for attachments already uploaded or not requiring uploading.
    /// Please use `init(localFileURL:customPayload:)` initializer for custom attachments requiring uploading.
    ///
    /// If attached to the new message the attachment with the given payload will be immediately
    /// available on `ChatMessage` with the `uploadingState == nil` since it doesn't require prior
    /// uploading.
    ///
    /// - Parameter payload: The payload to have the message attachment with.
    init<Payload: AttachmentPayload>(payload: Payload) {
        self.init(
            type: Payload.type,
            assetId: nil,
            payload: payload,
            localFileURL: nil,
            thumbnailData: nil,
            fileSize: nil
        )
    }

    /// Creates an instance of `AnyAttachmentPayload` with the given custom payload and local file url.
    /// Use this initialiser if you want to create a custom attachment which will be lazily uploaded after creating a message.
    /// You can track the progress of the attachment upload in your custom `CustomCellViewInjector`.
    ///
    /// - Important: You will need to inject a `ErmisClientConfig.uploadedAttachmentPostProcessor` and update the url of your
    ///   custom attachment with the given remote url.
    ///
    /// - Parameters:
    ///   - localFileURL: The local file url in the user's device.
    ///   - assetId: The local assetId of the attachment file
    ///   - thumbnailData: The data of preview image.
    ///   - customPayload: The custom attachment payload.
    init<Payload: AttachmentPayload>(
        localFileURL: URL,
        assetId: String?,
        thumbnailData: Data?,
        customPayload: Payload
    ) {
        self.init(
            type: Payload.type,
            assetId: assetId,
            payload: customPayload,
            localFileURL: localFileURL,
            thumbnailData: thumbnailData,
            fileSize: nil
        )
    }

    /// Creates an instance of `AnyAttachmentPayload` with the URL referencing to a local file.
    ///
    /// The resulting attachment will have `ImageAttachmentPayload` if `attachmentType == .image`.
    /// The resulting attachment will have `VideoAttachmentPayload` if `attachmentType == .video`.
    /// The resulting attachment will have `FileAttachmentPayload` if `attachmentType == .file`.
    /// If the type is different than `.image`/`.video`/`.file` the `ClientError.UnsupportedUploadableAttachmentType` error will be thrown.
    ///
    /// If attached to the new message the attachment with the given payload will be immediately
    /// available on `ChatMessage` with the `uploadingState` reflecting the file uploading progress.
    ///
    /// - Important: Until the message is sent all URLs on exposed attachment will be equal to the given `localFileURL`.
    /// - Important: A given extra data must have dictionary representation.
    ///
    /// - Parameters:
    ///   - localFileURL: The local URL referencing to the file.
    ///   - attachmentType: The type of resulting attachment exposed on the message.
    ///   - localMetadata: The metadata related to the local attachment.
    /// - Throws: The error if `localFileURL` is not the file URL.
    public init(
        localFileURL: URL,
        attachmentType: AttachmentType,
        localMetadata: AnyAttachmentLocalMetadata? = nil
    ) throws {
        let detectedFile = try AttachmentFile(url: localFileURL, fileSize: localMetadata?.fileSize)
        let file = AttachmentFile(
            type: detectedFile.type,
            size: detectedFile.size,
            mimeType: localMetadata?.mimeType ?? detectedFile.mimeType
        )

        let payload: AttachmentPayload
        switch attachmentType {
        case .image:
            payload = ImageAttachmentPayload(
                title: localMetadata?.title ?? localFileURL.lastPathComponent,
                imageRemoteURL: localFileURL,
                file: file,
                thumbnailData: localMetadata?.thumbnailData,
                originalWidth: localMetadata?.originalResolution?.width,
                originalHeight: localMetadata?.originalResolution?.height,
            )
        case .video:
            var videoPayload = VideoAttachmentPayload(
                title: localMetadata?.title ?? localFileURL.lastPathComponent,
                videoRemoteURL: localFileURL,
                thumbnailURL: nil,
                thumbnailData: localMetadata?.thumbnailData,
                file: file
            )
            videoPayload.duration = localMetadata?.duration
            payload = videoPayload
        case .audio:
            payload = AudioAttachmentPayload(
                title: localMetadata?.title ?? localFileURL.lastPathComponent,
                audioRemoteURL: localFileURL,
                file: file
            )
        case .file:
            payload = FileAttachmentPayload(
                title: localMetadata?.title ?? localFileURL.lastPathComponent,
                assetRemoteURL: localFileURL,
                file: file
            )
        case .voiceRecording:
            payload = VoiceRecordingAttachmentPayload(
                title: localMetadata?.title ?? localFileURL.lastPathComponent,
                voiceRecordingRemoteURL: localFileURL,
                file: file,
                duration: localMetadata?.duration,
                waveformData: localMetadata?.waveformData
            )
        default:
            throw ClientError.UnsupportedUploadableAttachmentType(attachmentType)
        }

        self.init(
            type: attachmentType,
            assetId: localMetadata?.assetId,
            payload: payload,
            localFileURL: localFileURL,
            thumbnailData: localMetadata?.thumbnailData,
            fileSize: localMetadata?.fileSize
        )
    }
}

extension ClientError {
    public class UnsupportedUploadableAttachmentType: ClientError {
        init(_ type: AttachmentType) {
            super.init(
                "For uploadable attachments only image/video/audio/file/voiceRecording types are supported."
            )
        }
    }

    public class AttachmentURLNotFound: ClientError {
        public
        init() {
            super.init("Attachment URL not found for attachment")
        }
    }
}

extension MessageAttachment<Data> {
    func toAnyAttachmentPayload() -> AnyAttachmentPayload? {
        let types = ErmisClient.attachmentTypesRegistry
        guard let payloadType = types[type] else { return nil }
        guard let payload = try? JSONDecoder.default.decode(
            payloadType,
            from: self.payload
        ) else {
            return nil
        }

        // If the attachment is local, we should create the payload as a local file
        if let uploadingState = self.uploadingState, uploadingState.state != .uploaded {
            return AnyAttachmentPayload(type: type,
                                        assetId: nil,
                                        payload: payload,
                                        localFileURL: uploadingState.localFileURL,
                                        thumbnailData: thumbnailData,
                                        fileSize: self.payload.count)
        }

        return AnyAttachmentPayload(payload: payload)
    }
}

public extension Array where Element == MessageAttachment<Data> {
    func toAnyAttachmentPayload() -> [AnyAttachmentPayload] {
        compactMap { $0.toAnyAttachmentPayload() }
    }
}
