//
// Copyright 2026 Ermis Inc.
//

import Foundation

extension APIClient {
    func initE2eeAttachment(
        cid: ChannelId,
        request: InitE2eeAttachmentRequest
    ) async throws -> InitE2eeAttachmentResponse {
        try request.validate()
        let startedAt = Date()
        log.info(
            "[E2EE_ATTACHMENT_API] operation=init state=requesting asset_count=\(request.assets.count)",
            subsystems: .mls
        )
        do {
            let response: InitE2eeAttachmentResponse = try await performE2eeAttachmentRequest {
                try await self.request(endpoint: .initE2eeAttachment(cid: cid, body: request))
            }
            try response.validate(against: request)
            let singleCount = response.assets.filter { $0.effectiveUploadMode == .singlePut }.count
            let multipartCount = response.assets.count - singleCount
            log.info(
                "[E2EE_ATTACHMENT_API] operation=init state=succeeded asset_count=\(response.assets.count) single_count=\(singleCount) multipart_count=\(multipartCount) elapsed_ms=\(Self.elapsedMilliseconds(since: startedAt))",
                subsystems: .mls
            )
            return response
        } catch {
            logE2eeAttachmentAPIFailure(operation: "init", error: error, startedAt: startedAt)
            throw error
        }
    }

    func queryE2eeAttachments(
        cid: ChannelId,
        request: QueryE2eeAttachmentsRequest
    ) async throws -> QueryE2eeAttachmentsResponse {
        try request.validate()
        let response: QueryE2eeAttachmentsResponse = try await performE2eeAttachmentRequest {
            try await self.request(endpoint: .queryE2eeAttachments(cid: cid, body: request))
        }
        try response.validate()
        return response
    }

    func completeE2eeAttachment(
        cid: ChannelId,
        attachmentId: String,
        request: CompleteE2eeAttachmentRequest
    ) async throws -> CompleteE2eeAttachmentResponse {
        guard UUID(uuidString: attachmentId) != nil else {
            throw E2eeAttachmentAPIContractError.invalidIdentifier
        }
        try request.validate()
        let startedAt = Date()
        log.info(
            "[E2EE_ATTACHMENT_API] operation=complete state=requesting asset_count=\(request.assets?.count ?? 0)",
            subsystems: .mls
        )
        do {
            let response: CompleteE2eeAttachmentResponse = try await performE2eeAttachmentRequest {
                try await self.request(
                    endpoint: .completeE2eeAttachment(
                        cid: cid,
                        attachmentId: attachmentId,
                        body: request
                    )
                )
            }
            try response.validate(expectedAttachmentId: attachmentId)
            log.info(
                "[E2EE_ATTACHMENT_API] operation=complete state=succeeded asset_count=\(response.assets.count) elapsed_ms=\(Self.elapsedMilliseconds(since: startedAt))",
                subsystems: .mls
            )
            return response
        } catch {
            logE2eeAttachmentAPIFailure(operation: "complete", error: error, startedAt: startedAt)
            throw error
        }
    }

    func e2eeAttachmentDownloadGrant(
        cid: ChannelId,
        attachmentId: String,
        assetId: String
    ) async throws -> E2eeAttachmentDownloadGrantResponse {
        guard UUID(uuidString: attachmentId) != nil, UUID(uuidString: assetId) != nil else {
            throw E2eeAttachmentAPIContractError.invalidIdentifier
        }
        let startedAt = Date()
        log.info("[E2EE_ATTACHMENT_API] operation=download_grant state=requesting", subsystems: .mls)
        do {
            let response: E2eeAttachmentDownloadGrantResponse = try await performE2eeAttachmentRequest {
                try await self.request(
                    endpoint: .e2eeAttachmentDownloadGrant(
                        cid: cid,
                        attachmentId: attachmentId,
                        assetId: assetId
                    )
                )
            }
            try response.validate(
                expectedAttachmentId: attachmentId,
                expectedAssetId: assetId
            )
            log.info(
                "[E2EE_ATTACHMENT_API] operation=download_grant state=succeeded elapsed_ms=\(Self.elapsedMilliseconds(since: startedAt))",
                subsystems: .mls
            )
            return response
        } catch {
            logE2eeAttachmentAPIFailure(operation: "download_grant", error: error, startedAt: startedAt)
            throw error
        }
    }

    func deleteE2eeAttachment(
        cid: ChannelId,
        attachmentId: String
    ) async throws -> DeleteE2eeAttachmentResponse {
        guard UUID(uuidString: attachmentId) != nil else {
            throw E2eeAttachmentAPIContractError.invalidIdentifier
        }
        let response: DeleteE2eeAttachmentResponse = try await performE2eeAttachmentRequest {
            try await self.request(
                endpoint: .deleteE2eeAttachment(cid: cid, attachmentId: attachmentId)
            )
        }
        try response.validate(expectedAttachmentId: attachmentId)
        return response
    }

    private func performE2eeAttachmentRequest<Response>(
        _ operation: () async throws -> Response
    ) async throws -> Response {
        do {
            return try await operation()
        } catch let error as E2eeAttachmentAPIContractError {
            throw error
        } catch let error as E2eeAttachmentRemoteError {
            throw error
        } catch {
            throw E2eeAttachmentRemoteError.classify(error)
        }
    }

    private func logE2eeAttachmentAPIFailure(
        operation: String,
        error: Error,
        startedAt: Date
    ) {
        let category: String
        let retryable: Bool
        if let remote = error as? E2eeAttachmentRemoteError {
            category = remote.category.rawValue
            retryable = remote.isRetryable
        } else if error is E2eeAttachmentAPIContractError {
            category = "contract"
            retryable = false
        } else {
            category = "unknown"
            retryable = false
        }
        log.error(
            "[E2EE_ATTACHMENT_API] operation=\(operation) state=failed category=\(category) retryable=\(retryable) elapsed_ms=\(Self.elapsedMilliseconds(since: startedAt))",
            subsystems: .mls
        )
    }

    private static func elapsedMilliseconds(since date: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(date) * 1_000))
    }
}
