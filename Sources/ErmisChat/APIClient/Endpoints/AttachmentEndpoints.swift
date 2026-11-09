//
// Copyright 2025 Ermis Inc.
//

import Foundation

extension Endpoint {
    /// Create the endpoint to upload an attachment.
    ///
    /// - Parameters:
    ///   - cid: The channelId that attachment will be uploaded to.
    ///   - type: The type of the attachment.
    /// - Returns: The endpoint for upload an attachment.
    static func uploadAttachment(
        with cid: ChannelId,
        type: AttachmentType,
        purpose: AttachmentUploadPurpose? = nil
    ) -> Endpoint<FileUploadPayload> {
        .init(
            path: .uploadAttachment(channelId: cid, type: "file"),
            method: .post,
            query: purpose.map { ["purpose": $0.rawValue] }
        )
    }

    static func presignStandardAttachment(
        with cid: ChannelId,
        body: StandardAttachmentPresignRequest
    ) -> Endpoint<StandardAttachmentPresignPayload> {
        .init(
            path: .presignStandardAttachment(channelId: cid),
            method: .post,
            body: body
        )
    }

    static func confirmStandardAttachment(
        with cid: ChannelId,
        body: StandardAttachmentConfirmRequest
    ) -> Endpoint<StandardAttachmentConfirmPayload> {
        .init(
            path: .confirmStandardAttachment(channelId: cid),
            method: .post,
            body: body
        )
    }
}
