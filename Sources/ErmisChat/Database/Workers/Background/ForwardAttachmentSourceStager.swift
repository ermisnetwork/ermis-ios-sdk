//
// Copyright 2026 Ermis Inc.
//

import Foundation

enum ForwardAttachmentSourceStagingError: Error, Equatable {
    case missingLocalSource(index: Int)
    case nonFileSource(index: Int)
}

struct ForwardAttachmentStagingResult {
    let payloads: [AnyAttachmentPayload]
    fileprivate let newlyCreatedURLs: [URL]
}

/// Moves attachment plaintext from a viewer-owned lease into storage owned by the destination
/// pending message. The copy completes before Core Data publishes that message to the uploader,
/// so releasing the source lease cannot invalidate a queued forward.
final class ForwardAttachmentSourceStager {
    private static let queue = DispatchQueue(
        label: "network.ermis.chat.forward-attachment-staging",
        qos: .utility
    )

    private let storage: AttachmentStorage

    init(storage: AttachmentStorage = AttachmentStorage()) {
        self.storage = storage
    }

    func stage(
        _ payloads: [AnyAttachmentPayload],
        for cid: ChannelId,
        messageId: MessageId,
        completion: @escaping (Result<ForwardAttachmentStagingResult, Error>) -> Void
    ) {
        Self.queue.async { [storage] in
            do {
                completion(.success(try Self.stage(
                    payloads,
                    for: cid,
                    messageId: messageId,
                    storage: storage
                )))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func removeNewlyCreatedFiles(in result: ForwardAttachmentStagingResult) {
        result.newlyCreatedURLs.forEach(storage.removeAttachment)
    }

    static func stage(
        _ payloads: [AnyAttachmentPayload],
        for cid: ChannelId,
        messageId: MessageId,
        storage: AttachmentStorage
    ) throws -> ForwardAttachmentStagingResult {
        var stagedPayloads: [AnyAttachmentPayload] = []
        var newlyCreatedURLs: [URL] = []
        stagedPayloads.reserveCapacity(payloads.count)
        newlyCreatedURLs.reserveCapacity(payloads.count)

        do {
            for (index, payload) in payloads.enumerated() {
                guard let sourceURL = payload.localFileURL else {
                    throw ForwardAttachmentSourceStagingError.missingLocalSource(index: index)
                }
                guard sourceURL.isFileURL else {
                    throw ForwardAttachmentSourceStagingError.nonFileSource(index: index)
                }

                let attachmentId = AttachmentId(cid: cid, messageId: messageId, index: index)
                let destinationURL = storage.sandboxedURL(
                    for: attachmentId,
                    temporaryURL: sourceURL
                )
                let destinationExisted = storage.fileExists(at: destinationURL)
                let durableURL = try storage.storeAttachmentPreservingOriginal(
                    id: attachmentId,
                    temporaryURL: sourceURL
                )
                if !destinationExisted {
                    newlyCreatedURLs.append(durableURL)
                }
                stagedPayloads.append(payload.replacingLocalFileURL(with: durableURL))
            }
        } catch {
            newlyCreatedURLs.forEach(storage.removeAttachment)
            throw error
        }

        return ForwardAttachmentStagingResult(
            payloads: stagedPayloads,
            newlyCreatedURLs: newlyCreatedURLs
        )
    }
}

private extension AnyAttachmentPayload {
    func replacingLocalFileURL(with url: URL) -> AnyAttachmentPayload {
        AnyAttachmentPayload(
            type: type,
            assetId: assetId,
            payload: payload.replacingAttachmentURL(with: url),
            localFileURL: url,
            thumbnailData: thumbnailData,
            fileSize: fileSize
        )
    }
}

private extension Encodable {
    /// Keep the type-erased upload source and its concrete payload in lockstep. The concrete URL
    /// is persisted in `AttachmentDTO.data` and drives video rendering while an upload is pending;
    /// leaving it pointed at the viewer lease makes the video disappear as soon as that lease is
    /// released, even though `AttachmentDTO.localURL` already owns a durable staged copy.
    func replacingAttachmentURL(with url: URL) -> Encodable {
        if var payload = self as? ImageAttachmentPayload {
            payload.imageURL = url
            return payload
        }
        if var payload = self as? VideoAttachmentPayload {
            payload.videoURL = url
            return payload
        }
        if var payload = self as? AudioAttachmentPayload {
            payload.audioURL = url
            return payload
        }
        if var payload = self as? FileAttachmentPayload {
            payload.assetURL = url
            return payload
        }
        if var payload = self as? VoiceRecordingAttachmentPayload {
            payload.voiceRecordingURL = url
            return payload
        }
        return self
    }
}
