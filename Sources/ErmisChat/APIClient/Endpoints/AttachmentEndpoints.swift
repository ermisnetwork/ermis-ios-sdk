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
    static func uploadAttachment(with cid: ChannelId, type: AttachmentType) -> Endpoint<FileUploadPayload> {
        .init(
            path: .uploadAttachment(channelId: cid, type: "file"),
            method: .post,
            query: nil
        )
    }
}
