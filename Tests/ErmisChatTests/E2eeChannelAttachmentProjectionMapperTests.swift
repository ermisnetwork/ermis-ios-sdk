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

    func testKnownAssetOrderDoesNotAffectProjectionJoin() throws {
        let manifest = makeManifest()
        var projection = makeProjection(manifest: manifest)
        projection = replacingAssets(in: projection, with: projection.assets.reversed())

        let item = try E2eeChannelAttachmentProjectionMapper.makeItem(
            projection: projection,
            expectedCid: cid,
            payload: makePayload(manifest: manifest)
        )

        XCTAssertEqual(item.attachmentId, manifest.attachmentId)
    }

    func testUnknownFutureProjectionAssetKindIsIgnored() throws {
        let manifest = makeManifest()
        let projection = makeProjection(manifest: manifest)
        let futureAsset = QueryE2eeAttachmentAssetProjection(
            assetId: UUID().uuidString,
            kind: "transcript",
            cipherSize: 128
        )

        let item = try E2eeChannelAttachmentProjectionMapper.makeItem(
            projection: replacingAssets(in: projection, with: projection.assets + [futureAsset]),
            expectedCid: cid,
            payload: makePayload(manifest: manifest)
        )

        XCTAssertEqual(item.attachment.type, .image)
    }

    func testDuplicateProjectedAssetIdIsRejected() {
        let manifest = makeManifest()
        let projection = makeProjection(manifest: manifest)
        let duplicate = projection.assets[0]

        assertProjectionMismatch(
            replacingAssets(in: projection, with: projection.assets + [duplicate]),
            manifest: manifest
        )
    }

    func testMissingProjectedOriginalIsRejected() {
        let manifest = makeManifest()
        let projection = makeProjection(manifest: manifest)

        assertProjectionMismatch(
            replacingAssets(in: projection, with: projection.assets.filter { $0.kind != "original" }),
            manifest: manifest
        )
    }

    func testProjectedAssetKindMismatchIsRejected() {
        let manifest = makeManifest()
        let projection = makeProjection(manifest: manifest)
        let assets = projection.assets.map { asset in
            QueryE2eeAttachmentAssetProjection(
                assetId: asset.assetId,
                kind: asset.kind == "preview" ? "original" : asset.kind,
                cipherSize: asset.cipherSize
            )
        }

        assertProjectionMismatch(replacingAssets(in: projection, with: assets), manifest: manifest)
    }

    func testInvalidProjectionDatesAreRejected() {
        let manifest = makeManifest()
        let projection = makeProjection(manifest: manifest)
        let invalidCreatedAt = replacingDates(in: projection, createdAt: "not-a-date")
        let invalidUpdatedAt = replacingDates(in: projection, updatedAt: "not-a-date")

        for invalidProjection in [invalidCreatedAt, invalidUpdatedAt] {
            XCTAssertThrowsError(
                try E2eeChannelAttachmentProjectionMapper.makeItem(
                    projection: invalidProjection,
                    expectedCid: cid,
                    payload: makePayload(manifest: manifest)
                )
            ) { error in
                XCTAssertEqual(error as? E2eeChannelAttachmentProjectionError, .invalidDate)
            }
        }
    }

    func testClassificationAndDisplayMetadataComeFromEncryptedManifestForEverySupportedTab() throws {
        let cases: [(display: [String: RawJSON], type: AttachmentType, name: String, mime: String)] = [
            (
                [
                    "name": .string("photo.bin"),
                    "mime_type": .string("image/jpeg"),
                    "width": .number(480),
                    "height": .number(320)
                ],
                .image,
                "photo.bin",
                "image/jpeg"
            ),
            (
                [
                    "name": .string("clip.bin"),
                    "mime_type": .string("video/mp4"),
                    "duration": .number(12)
                ],
                .video,
                "clip.bin",
                "video/mp4"
            ),
            (
                [
                    "name": .string("document.jpg"),
                    "mime_type": .string("application/pdf")
                ],
                .file,
                "document.jpg",
                "application/pdf"
            ),
            (
                [
                    "name": .string("recording.bin"),
                    "mime_type": .string("audio/aac"),
                    "attachment_type": .string("voiceRecording"),
                    "duration": .number(2)
                ],
                .voiceRecording,
                "recording.bin",
                "audio/aac"
            )
        ]

        for testCase in cases {
            let manifest = makeManifest(display: testCase.display)
            let projection = makeProjection(manifest: manifest)
            let item = try E2eeChannelAttachmentProjectionMapper.makeItem(
                projection: projection,
                expectedCid: cid,
                payload: makePayload(manifest: manifest)
            )

            XCTAssertEqual(item.attachment.type, testCase.type)
            XCTAssertEqual(item.displayName, testCase.name)
            XCTAssertEqual(item.mimeType, testCase.mime)
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

    private func replacingAssets(
        in projection: QueryE2eeAttachmentProjection,
        with assets: some Sequence<QueryE2eeAttachmentAssetProjection>
    ) -> QueryE2eeAttachmentProjection {
        QueryE2eeAttachmentProjection(
            attachmentId: projection.attachmentId,
            messageId: projection.messageId,
            cid: projection.cid,
            createdByUserId: projection.createdByUserId,
            createdAt: projection.createdAt,
            updatedAt: projection.updatedAt,
            assets: Array(assets)
        )
    }

    private func replacingDates(
        in projection: QueryE2eeAttachmentProjection,
        createdAt: String? = nil,
        updatedAt: String? = nil
    ) -> QueryE2eeAttachmentProjection {
        QueryE2eeAttachmentProjection(
            attachmentId: projection.attachmentId,
            messageId: projection.messageId,
            cid: projection.cid,
            createdByUserId: projection.createdByUserId,
            createdAt: createdAt ?? projection.createdAt,
            updatedAt: updatedAt ?? projection.updatedAt,
            assets: projection.assets
        )
    }

    private func assertProjectionMismatch(
        _ projection: QueryE2eeAttachmentProjection,
        manifest: E2eeAttachmentManifestV1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try E2eeChannelAttachmentProjectionMapper.makeItem(
                projection: projection,
                expectedCid: cid,
                payload: makePayload(manifest: manifest)
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? E2eeChannelAttachmentProjectionError,
                .projectionMismatch,
                file: file,
                line: line
            )
        }
    }

    private func makeManifest(display: [String: RawJSON]? = nil) -> E2eeAttachmentManifestV1 {
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
                    display: display ?? [
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
