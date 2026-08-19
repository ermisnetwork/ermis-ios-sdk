//
// Copyright 2026 Ermis Inc.
//

import Foundation

extension Endpoint {
    static func initE2eeAttachment(
        cid: ChannelId,
        body: InitE2eeAttachmentRequest
    ) -> Endpoint<InitE2eeAttachmentResponse> {
        .init(
            path: .initE2eeAttachment(cid),
            method: .post,
            body: body,
            needDeviceId: true,
            headers: ["X-Ermis-E2EE-Attachment-Upload": "multipart-v1"]
        )
    }

    static func queryE2eeAttachments(
        cid: ChannelId,
        body: QueryE2eeAttachmentsRequest
    ) -> Endpoint<QueryE2eeAttachmentsResponse> {
        .init(
            path: .queryE2eeAttachments(cid),
            method: .post,
            body: body,
            needDeviceId: true
        )
    }

    static func completeE2eeAttachment(
        cid: ChannelId,
        attachmentId: String,
        body: CompleteE2eeAttachmentRequest
    ) -> Endpoint<CompleteE2eeAttachmentResponse> {
        .init(
            path: .completeE2eeAttachment(cid, attachmentId),
            method: .post,
            body: body,
            needDeviceId: true
        )
    }

    static func e2eeAttachmentDownloadGrant(
        cid: ChannelId,
        attachmentId: String,
        assetId: String
    ) -> Endpoint<E2eeAttachmentDownloadGrantResponse> {
        .init(
            path: .downloadE2eeAttachmentGrant(cid, attachmentId, assetId),
            method: .post,
            body: EmptyBody(),
            needDeviceId: true
        )
    }

    static func deleteE2eeAttachment(
        cid: ChannelId,
        attachmentId: String
    ) -> Endpoint<DeleteE2eeAttachmentResponse> {
        .init(
            path: .deleteE2eeAttachment(cid, attachmentId),
            method: .delete,
            needDeviceId: true
        )
    }
}
