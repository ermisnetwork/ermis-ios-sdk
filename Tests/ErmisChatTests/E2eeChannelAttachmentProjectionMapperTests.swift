//
// Copyright 2026 Ermis Inc.
//

import Foundation
@testable import ErmisChat
import XCTest

final class E2eeChannelAttachmentProjectionMapperTests: XCTestCase {
    private let cid = ChannelId(type: .messaging, id: "channel-info")

    func testMatchingProjectionAndManifestBuildRenderableItem() throws {
        let manifest = makeManifest()
        let projection = makeProjection(manifest: manifest)
        let previewData = Data([1, 2, 3])

        let item = try E2eeChannelAttachmentProjectionMapper.makeItem(
            projection: projection,
            expectedCid: cid,
            payload: makePayload(manifest: manifest),
            cachedPreview: (previewData, "generation")
        )

        XCTAssertEqual(item.attachmentId, manifest.attachmentId)
        XCTAssertEqual(item.messageId, projection.messageId)
        XCTAssertEqual(item.cid, cid)
        XCTAssertEqual(item.attachment.type, .image)
        XCTAssertEqual(item.attachment.thumbnailData, previewData)
        XCTAssertEqual(item.displayName, "photo.jpg")
        XCTAssertEqual(item.mimeType, "image/jpeg")
        XCTAssertEqual(item.plaintextSize, 1_024)
    }

    func testMissingLocalManifestIsRejected() {
        let manifest = makeManifest()
        let projection = makeProjection(manifest: manifest)

        XCTAssertThrowsError(
            try E2eeChannelAttachmentProjectionMapper.makeItem(
                projection: projection,
                expectedCid: cid,
                payload: makePayload(manifest: makeManifest())
            )
        ) { error in
            XCTAssertEqual(error as? E2eeChannelAttachmentProjectionError, .missingManifest)
        }
    }

    func testAssetProjectionMismatchIsRejected() {
        let manifest = makeManifest()
        var projection = makeProjection(manifest: manifest)
        projection = QueryE2eeAttachmentProjection(
            attachmentId: projection.attachmentId,
            messageId: projection.messageId,
            cid: projection.cid,
            createdByUserId: projection.createdByUserId,
            createdAt: projection.createdAt,
            updatedAt: projection.updatedAt,
            assets: projection.assets.map {
                QueryE2eeAttachmentAssetProjection(
                    assetId: $0.assetId,
                    kind: $0.kind,
                    cipherSize: $0.cipherSize + 1
                )
            }
        )

        XCTAssertThrowsError(
            try E2eeChannelAttachmentProjectionMapper.makeItem(
                projection: projection,
                expectedCid: cid,
                payload: makePayload(manifest: manifest)
            )
        ) { error in
            XCTAssertEqual(error as? E2eeChannelAttachmentProjectionError, .projectionMismatch)
        }
    }

    func testProjectionForAnotherChannelIsRejected() {
        let manifest = makeManifest()
        let projection = QueryE2eeAttachmentProjection(
            attachmentId: manifest.attachmentId,
            messageId: "message-id",
            cid: "messaging:another-channel",
            createdByUserId: "sender",
            createdAt: "2026-08-10T08:00:00Z",
            updatedAt: "2026-08-10T08:00:01Z",
            assets: makeAssetProjections(manifest: manifest)
        )

        XCTAssertThrowsError(
            try E2eeChannelAttachmentProjectionMapper.makeItem(
                projection: projection,
                expectedCid: cid,
                payload: makePayload(manifest: manifest)
            )
        ) { error in
            XCTAssertEqual(error as? E2eeChannelAttachmentProjectionError, .invalidChannel)
        }
    }

    private func makePayload(manifest: E2eeAttachmentManifestV1) -> E2ePayload {
        E2ePayload(text: "", attachments: [], e2eeAttachments: [manifest], stickerUrl: nil)
    }

    private func makeProjection(manifest: E2eeAttachmentManifestV1) -> QueryE2eeAttachmentProjection {
        QueryE2eeAttachmentProjection(
            attachmentId: manifest.attachmentId,
            messageId: "message-id",
            cid: cid.rawValue,
            createdByUserId: "sender",
            createdAt: "2026-08-10T08:00:00Z",
            updatedAt: "2026-08-10T08:00:01Z",
            assets: makeAssetProjections(manifest: manifest)
        )
    }

    private func makeAssetProjections(
        manifest: E2eeAttachmentManifestV1
    ) -> [QueryE2eeAttachmentAssetProjection] {
        manifest.assets.map {
            QueryE2eeAttachmentAssetProjection(
                assetId: $0.assetId,
                kind: $0.kind.rawValue,
                cipherSize: $0.cipherSize
            )
        }
    }

    private func makeManifest() -> E2eeAttachmentManifestV1 {
        let key = Data(repeating: 1, count: E2eeAttachmentFrameCryptoV1.keySize).base64EncodedString()
        let nonce = Data(repeating: 2, count: E2eeAttachmentFrameCryptoV1.noncePrefixSize)
            .base64EncodedString()
        return E2eeAttachmentManifestV1(
            attachmentId: UUID().uuidString,
            assets: [
                E2eeAttachmentManifestAssetV1(
                    assetId: UUID().uuidString,
                    kind: .original,
                    cipherSize: 1_048,
                    cipherSha256: String(repeating: "a", count: 64),
                    frameSize: UInt32(E2eeAttachmentFrameCryptoV1.defaultFrameSize),
                    contentKey: key,
                    noncePrefix: nonce,
                    plaintextSize: 1_024,
                    plaintextSha256: String(repeating: "b", count: 64),
                    display: [
                        "name": .string("photo.jpg"),
                        "mime_type": .string("image/jpeg"),
                        "width": .number(480),
                        "height": .number(320)
                    ]
                ),
                E2eeAttachmentManifestAssetV1(
                    assetId: UUID().uuidString,
                    kind: .preview,
                    cipherSize: 536,
                    cipherSha256: String(repeating: "c", count: 64),
                    frameSize: UInt32(E2eeAttachmentFrameCryptoV1.defaultFrameSize),
                    contentKey: key,
                    noncePrefix: nonce,
                    plaintextSize: 512,
                    plaintextSha256: String(repeating: "d", count: 64),
                    display: ["mime_type": .string("image/jpeg")]
                )
            ]
        )
    }
}
