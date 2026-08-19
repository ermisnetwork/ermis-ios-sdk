//
// Copyright 2026 Ermis Inc.
//

import Foundation
@testable import ErmisChat
import XCTest

final class E2eeAttachmentAPITests: XCTestCase {
    private let attachmentId = "550e8400-e29b-41d4-a716-446655440000"
    private let originalAssetId = "11111111-1111-1111-1111-111111111111"
    private let previewAssetId = "22222222-2222-2222-2222-222222222222"

    func testInitRequestUsesCanonicalWireKeysAndCapabilityHeader() throws {
        let request = makeInitRequest(originalSize: 8_421_376, previewSize: 48_512)
        let endpoint = Endpoint<InitE2eeAttachmentResponse>.initE2eeAttachment(
            cid: try ChannelId(cid: "team:project:channel"),
            body: request
        )
        let json = try jsonObject(JSONEncoder.ermis.encode(request))
        let assets = try XCTUnwrap(json["assets"] as? [[String: Any]])

        XCTAssertEqual(json["idempotency_key"] as? String, request.idempotencyKey)
        XCTAssertNil(json["idempotencyKey"])
        XCTAssertEqual(
            (assets.first?["cipher_size_estimate"] as? NSNumber)?.uint64Value,
            8_421_376
        )
        XCTAssertEqual(endpoint.headers["X-Ermis-E2EE-Attachment-Upload"], "multipart-v1")
        XCTAssertTrue(endpoint.needDeviceId)
        XCTAssertEqual(endpoint.path.value, "v1/e2ee/channels/team/project:channel/attachments/init")
    }

    func testSinglePutResponseMatchesAssetsByKindNotArrayPosition() throws {
        let request = makeInitRequest(originalSize: 8_421_376, previewSize: 48_512)
        let response = try decodeInitResponse(
            assets: [
                singlePutAsset(id: previewAssetId, kind: "preview", size: 48_512),
                singlePutAsset(id: originalAssetId, kind: "original", size: 8_421_376),
            ]
        )

        XCTAssertNoThrow(try response.validate(against: request))
        XCTAssertEqual(response.assets.first?.kind, .preview)
    }

    func testMultipartResponseValidatesPartCountAndSecureURLs() throws {
        let request = makeInitRequest(originalSize: 16)
        let response = try decodeInitResponse(
            assets: [
                multipartAsset(
                    id: originalAssetId,
                    size: 16,
                    partSize: 8,
                    parts: [1, 2]
                ),
            ]
        )

        XCTAssertThrowsError(try response.validate(against: request)) { error in
            XCTAssertEqual(error as? E2eeAttachmentAPIContractError, .invalidAssetSet)
        }

        let validRequest = makeInitRequest(originalSize: 24)
        let validResponse = try decodeInitResponse(
            assets: [
                multipartAsset(
                    id: originalAssetId,
                    size: 24,
                    partSize: 12,
                    parts: [1, 2]
                ),
            ]
        )
        XCTAssertNoThrow(try validResponse.validate(against: validRequest))
    }

    func testInitValidationRejectsMismatchedSizeDuplicateKindsAndPreviewMultipart() throws {
        let request = makeInitRequest(originalSize: 100, previewSize: 50)
        let mismatch = try decodeInitResponse(
            assets: [
                singlePutAsset(id: originalAssetId, kind: "original", size: 101),
                singlePutAsset(id: previewAssetId, kind: "preview", size: 50),
            ]
        )
        XCTAssertThrowsError(try mismatch.validate(against: request)) { error in
            XCTAssertEqual(error as? E2eeAttachmentAPIContractError, .mismatchedAssetSet)
        }

        let duplicateRequest = InitE2eeAttachmentRequest(
            idempotencyKey: UUID().uuidString,
            assets: [
                .init(kind: .original, cipherSizeEstimate: 100),
                .init(kind: .original, cipherSizeEstimate: 100),
            ]
        )
        XCTAssertThrowsError(try duplicateRequest.validate()) { error in
            XCTAssertEqual(error as? E2eeAttachmentAPIContractError, .invalidAssetSet)
        }

        let previewMultipart = try decodeInitResponse(
            assets: [
                singlePutAsset(id: originalAssetId, kind: "original", size: 100),
                multipartAsset(
                    id: previewAssetId,
                    kind: "preview",
                    size: 50,
                    partSize: 50,
                    parts: [1]
                ),
            ]
        )
        XCTAssertThrowsError(try previewMultipart.validate(against: request)) { error in
            XCTAssertEqual(error as? E2eeAttachmentAPIContractError, .invalidUploadMode)
        }
    }

    func testRequestLimitsAreEnforcedBeforeInit() throws {
        XCTAssertThrowsError(
            try makeInitRequest(
                originalSize: InitE2eeAttachmentRequest.maximumOriginalCipherSize + 1
            ).validate()
        )
        XCTAssertThrowsError(
            try makeInitRequest(
                originalSize: 24,
                previewSize: InitE2eeAttachmentRequest.maximumPreviewCipherSize + 1
            ).validate()
        )
        XCTAssertNoThrow(
            try makeInitRequest(
                originalSize: InitE2eeAttachmentRequest.maximumOriginalCipherSize,
                previewSize: InitE2eeAttachmentRequest.maximumPreviewCipherSize
            ).validate()
        )
    }

    func testEveryAttachmentEndpointRequiresDeviceIdentity() throws {
        let cid = try ChannelId(cid: "team:project:channel")
        let query = Endpoint<QueryE2eeAttachmentsResponse>.queryE2eeAttachments(
            cid: cid,
            body: .init(limit: 50, cursor: nil)
        )
        let complete = Endpoint<CompleteE2eeAttachmentResponse>.completeE2eeAttachment(
            cid: cid,
            attachmentId: attachmentId,
            body: .init(completionLeaseId: UUID().uuidString, assets: nil)
        )
        let grant = Endpoint<E2eeAttachmentDownloadGrantResponse>.e2eeAttachmentDownloadGrant(
            cid: cid,
            attachmentId: attachmentId,
            assetId: originalAssetId
        )
        let delete = Endpoint<DeleteE2eeAttachmentResponse>.deleteE2eeAttachment(
            cid: cid,
            attachmentId: attachmentId
        )

        XCTAssertTrue(query.needDeviceId)
        XCTAssertTrue(complete.needDeviceId)
        XCTAssertTrue(grant.needDeviceId)
        XCTAssertTrue(delete.needDeviceId)
    }

    func testChannelInfoKeepsStandardAndE2eeRoutesDistinct() throws {
        let cid = try ChannelId(cid: "team:project:channel")
        let standard = Endpoint<ChannelAttachmentListPayload>.channelAttachment(
            cid: cid,
            body: .init(attachmentTypes: [.image, .video])
        )
        let e2ee = Endpoint<QueryE2eeAttachmentsResponse>.queryE2eeAttachments(
            cid: cid,
            body: .init(limit: 50, cursor: nil)
        )

        XCTAssertEqual(standard.method, .post)
        XCTAssertEqual(standard.path.value, "channels/team/project:channel/attachment")
        XCTAssertFalse(standard.needDeviceId)

        XCTAssertEqual(e2ee.method, .post)
        XCTAssertEqual(e2ee.path.value, "v1/e2ee/channels/team/project:channel/attachments/query")
        XCTAssertTrue(e2ee.needDeviceId)
    }

    func testQueryRetainsUnknownFutureAssetKindAndValidatesCursor() throws {
        let data = Data(
            """
            {
              "attachments": [{
                "attachment_id": "\(attachmentId)",
                "message_id": "33333333-3333-3333-3333-333333333333",
                "cid": "team:project:channel",
                "created_by_user_id": "user-a",
                "created_at": "2026-08-08T10:00:00Z",
                "updated_at": "2026-08-08T10:00:01Z",
                "assets": [{
                  "asset_id": "\(originalAssetId)",
                  "kind": "future-poster",
                  "cipher_size": 24
                }]
              }],
              "next_cursor": {
                "created_at": "2026-08-08T10:00:00Z",
                "attachment_id": "\(attachmentId)"
              },
              "has_more": true
            }
            """.utf8
        )
        let response = try JSONDecoder.ermis.decode(QueryE2eeAttachmentsResponse.self, from: data)

        XCTAssertEqual(response.attachments.first?.assets.first?.kind, "future-poster")
        XCTAssertNoThrow(try response.validate())
        XCTAssertThrowsError(try QueryE2eeAttachmentsRequest(limit: 101, cursor: nil).validate())
    }

    func testQueryFirstPageAndOpaqueCursorEncodeExactly() throws {
        let firstPage = try JSONEncoder.ermis.encode(
            QueryE2eeAttachmentsRequest(limit: 50, cursor: nil)
        )
        let firstPageJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: firstPage) as? [String: Any]
        )

        XCTAssertEqual(firstPageJSON["limit"] as? Int, 50)
        XCTAssertTrue(firstPageJSON.keys.contains("cursor"))
        XCTAssertTrue(firstPageJSON["cursor"] is NSNull)

        let cursor = QueryE2eeAttachmentsCursor(
            createdAt: "2026-08-17T10:00:00.123Z",
            attachmentId: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        )
        let nextPage = try JSONEncoder.ermis.encode(
            QueryE2eeAttachmentsRequest(limit: 100, cursor: cursor)
        )
        let nextPageJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: nextPage) as? [String: Any]
        )
        let encodedCursor = try XCTUnwrap(nextPageJSON["cursor"] as? [String: Any])

        XCTAssertEqual(nextPageJSON["limit"] as? Int, 100)
        XCTAssertEqual(encodedCursor["created_at"] as? String, cursor.createdAt)
        XCTAssertEqual(encodedCursor["attachment_id"] as? String, cursor.attachmentId)
    }

    func testDownloadGrantMustMatchRequestedIdsAndUseHTTPS() throws {
        let response = E2eeAttachmentDownloadGrantResponse(
            attachmentId: attachmentId,
            assetId: originalAssetId,
            downloadURL: try XCTUnwrap(URL(string: "https://r2.example.test/object")),
            expiresAt: "2026-08-08T10:00:00Z"
        )
        XCTAssertNoThrow(
            try response.validate(
                expectedAttachmentId: attachmentId,
                expectedAssetId: originalAssetId
            )
        )
        XCTAssertThrowsError(
            try response.validate(
                expectedAttachmentId: attachmentId,
                expectedAssetId: previewAssetId
            )
        )
    }

    func testCompleteRequestRejectsMissingOrDuplicateETags() throws {
        let lease = UUID().uuidString
        let valid = CompleteE2eeAttachmentRequest(
            completionLeaseId: lease,
            assets: [
                .init(
                    assetId: originalAssetId,
                    multipart: .init(parts: [
                        .init(partNumber: 1, eTag: "etag-1"),
                        .init(partNumber: 2, eTag: "etag-2"),
                    ])
                ),
            ]
        )
        XCTAssertNoThrow(try valid.validate())

        let duplicate = CompleteE2eeAttachmentRequest(
            completionLeaseId: lease,
            assets: [
                .init(
                    assetId: originalAssetId,
                    multipart: .init(parts: [
                        .init(partNumber: 1, eTag: "etag-1"),
                        .init(partNumber: 1, eTag: "etag-1-retry"),
                    ])
                ),
            ]
        )
        XCTAssertThrowsError(try duplicate.validate())
    }

    func testBellboyAttachmentErrorsMapToStableRetryPolicy() {
        let busy = ErmisApiError(
            type: .inputNotCorrect,
            statusCode: 409,
            message: "e2ee_attachment_busy"
        )
        let tooLarge = ErmisApiError(
            type: .inputNotCorrect,
            statusCode: 400,
            message: "e2ee_attachment_too_large"
        )
        let unavailable = ErmisApiError(
            type: .serviceUnavailable,
            statusCode: 503,
            message: "temporary outage"
        )

        XCTAssertEqual(
            E2eeAttachmentRemoteError.classify(busy),
            .init(category: .attachmentBusy, isRetryable: true)
        )
        XCTAssertEqual(
            E2eeAttachmentRemoteError.classify(tooLarge),
            .init(category: .attachmentTooLarge, isRetryable: false)
        )
        XCTAssertEqual(
            E2eeAttachmentRemoteError.classify(unavailable),
            .init(category: .serviceTemporarilyUnavailable, isRetryable: true)
        )
    }

    func testTransportErrorsDoNotExposeRawURLOrServerMessage() {
        let raw = URLError(
            .notConnectedToInternet,
            userInfo: [NSURLErrorFailingURLStringErrorKey: "https://secret.example/grant"]
        )
        let classified = E2eeAttachmentRemoteError.classify(raw)

        XCTAssertEqual(classified.category, .networkUnavailable)
        XCTAssertTrue(classified.isRetryable)
        XCTAssertEqual(classified.publicFailureReason, .networkUnavailable)
        XCTAssertFalse(String(describing: classified).contains("secret.example"))
    }

    private func makeInitRequest(
        originalSize: UInt64,
        previewSize: UInt64? = nil
    ) -> InitE2eeAttachmentRequest {
        var assets = [InitE2eeAttachmentAssetRequest(kind: .original, cipherSizeEstimate: originalSize)]
        if let previewSize {
            assets.append(.init(kind: .preview, cipherSizeEstimate: previewSize))
        }
        return .init(idempotencyKey: UUID().uuidString, assets: assets)
    }

    private func decodeInitResponse(assets: [String]) throws -> InitE2eeAttachmentResponse {
        let data = Data(
            """
            {
              "attachment_id": "\(attachmentId)",
              "status": "initiated",
              "upload_expires_at": "2026-08-08T10:00:00Z",
              "assets": [\(assets.joined(separator: ","))]
            }
            """.utf8
        )
        return try JSONDecoder.ermis.decode(InitE2eeAttachmentResponse.self, from: data)
    }

    private func singlePutAsset(id: String, kind: String, size: UInt64) -> String {
        """
        {
          "asset_id": "\(id)",
          "kind": "\(kind)",
          "upload_mode": "single_put",
          "put_url": "https://r2.example.test/\(id)",
          "object_key": "opaque/\(id)",
          "cipher_size_estimate": \(size)
        }
        """
    }

    private func multipartAsset(
        id: String,
        kind: String = "original",
        size: UInt64,
        partSize: UInt64,
        parts: [Int]
    ) -> String {
        let partJSON = parts.map {
            "{\"part_number\":\($0),\"put_url\":\"https://r2.example.test/part-\($0)\"}"
        }.joined(separator: ",")
        return """
        {
          "asset_id": "\(id)",
          "kind": "\(kind)",
          "upload_mode": "multipart",
          "multipart": {
            "multipart_upload_id": "opaque-upload-id",
            "part_size": \(partSize),
            "part_count": \(parts.count),
            "max_part_retries": 5,
            "retry_max_elapsed_secs": 900,
            "parts": [\(partJSON)]
          },
          "object_key": "opaque/\(id)",
          "cipher_size_estimate": \(size)
        }
        """
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
