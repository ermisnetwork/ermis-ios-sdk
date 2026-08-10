//
// Copyright 2026 Ermis Inc.
//

import Foundation
@testable import ErmisChat
import XCTest

final class E2eeAttachmentReceiveCoordinatorTests: XCTestCase {
    func testVideoManifestBuildsRenderableVideoAttachment() throws {
        let manifest = makeManifest(
            mimeType: "video/mp4",
            name: "clip.mp4",
            width: 1080,
            height: 1920,
            duration: 20.5
        )

        let renderable = try E2eeAttachmentReceiveCoordinator.renderablePayload(for: manifest)
        let payload = try JSONDecoder.ermis.decode(VideoAttachmentPayload.self, from: renderable.data)

        XCTAssertEqual(renderable.type, .video)
        XCTAssertEqual(payload.title, "clip.mp4")
        XCTAssertEqual(payload.file.mimeType, "video/mp4")
        XCTAssertEqual(payload.file.size, 1_024)
        XCTAssertEqual(payload.duration, 20.5)
        XCTAssertEqual(payload.videoURL.scheme, "ermis-e2ee-attachment")
        XCTAssertEqual(payload.videoURL.host, "asset")
        XCTAssertTrue(payload.videoURL.path.contains(manifest.attachmentId))
    }

    func testImageManifestBuildsRenderableImageAttachment() throws {
        let manifest = makeManifest(
            mimeType: "image/jpeg",
            name: "photo.jpg",
            width: 480,
            height: 320,
            duration: nil
        )

        let renderable = try E2eeAttachmentReceiveCoordinator.renderablePayload(for: manifest)
        let payload = try JSONDecoder.ermis.decode(ImageAttachmentPayload.self, from: renderable.data)

        XCTAssertEqual(renderable.type, .image)
        XCTAssertEqual(payload.title, "photo.jpg")
        XCTAssertEqual(payload.file.mimeType, "image/jpeg")
        XCTAssertEqual(payload.originalWidth, 480)
        XCTAssertEqual(payload.originalHeight, 320)
        XCTAssertEqual(payload.imageURL.scheme, "ermis-e2ee-attachment")
        XCTAssertEqual(payload.imageURL.host, "asset")
    }

    func testUnsupportedOriginalMimeTypeIsRejected() {
        let manifest = makeManifest(
            mimeType: "application/pdf",
            name: "document.pdf",
            width: nil,
            height: nil,
            duration: nil
        )

        XCTAssertThrowsError(try E2eeAttachmentReceiveCoordinator.renderablePayload(for: manifest))
    }

    func testDecodedPreviewCacheHasBoundedMemoryBudget() {
        XCTAssertEqual(E2eeAttachmentPreviewCache.totalCostLimit, 24 * 1_024 * 1_024)
        XCTAssertEqual(E2eeAttachmentPreviewCache.countLimit, 32)
    }

    private func makeManifest(
        mimeType: String,
        name: String,
        width: Double?,
        height: Double?,
        duration: Double?
    ) -> E2eeAttachmentManifestV1 {
        var display: [String: RawJSON] = [
            "mime_type": .string(mimeType),
            "name": .string(name)
        ]
        display["width"] = width.map(RawJSON.number)
        display["height"] = height.map(RawJSON.number)
        display["duration"] = duration.map(RawJSON.number)

        let key = Data(repeating: 7, count: E2eeAttachmentFrameCryptoV1.keySize)
        let nonce = Data(repeating: 9, count: E2eeAttachmentFrameCryptoV1.noncePrefixSize)
        let originalId = UUID().uuidString
        let previewId = UUID().uuidString
        return E2eeAttachmentManifestV1(
            attachmentId: UUID().uuidString,
            assets: [
                E2eeAttachmentManifestAssetV1(
                    assetId: originalId,
                    kind: .original,
                    cipherSize: 1_048,
                    cipherSha256: String(repeating: "a", count: 64),
                    frameSize: UInt32(E2eeAttachmentFrameCryptoV1.defaultFrameSize),
                    contentKey: key.base64EncodedString(),
                    noncePrefix: nonce.base64EncodedString(),
                    plaintextSize: 1_024,
                    plaintextSha256: String(repeating: "b", count: 64),
                    display: display
                ),
                E2eeAttachmentManifestAssetV1(
                    assetId: previewId,
                    kind: .preview,
                    cipherSize: 536,
                    cipherSha256: String(repeating: "c", count: 64),
                    frameSize: UInt32(E2eeAttachmentFrameCryptoV1.defaultFrameSize),
                    contentKey: key.base64EncodedString(),
                    noncePrefix: nonce.base64EncodedString(),
                    plaintextSize: 512,
                    plaintextSha256: String(repeating: "d", count: 64),
                    display: [
                        "mime_type": .string("image/jpeg"),
                        "preview_of": .string("original")
                    ]
                )
            ]
        )
    }
}
