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

    func testGenericMimeTypeBuildsRenderableFileAttachment() throws {
        let manifest = makeManifest(
            mimeType: "application/pdf",
            name: "document.pdf",
            width: nil,
            height: nil,
            duration: nil
        )

        let renderable = try E2eeAttachmentReceiveCoordinator.renderablePayload(for: manifest)
        let payload = try JSONDecoder.ermis.decode(FileAttachmentPayload.self, from: renderable.data)

        XCTAssertEqual(renderable.type, .file)
        XCTAssertEqual(payload.title, "document.pdf")
        XCTAssertEqual(payload.file.mimeType, "application/pdf")
        XCTAssertEqual(payload.assetURL.scheme, "ermis-e2ee-attachment")
    }

    func testExplicitVoiceRecordingBuildsRenderableVoiceAttachment() throws {
        var manifest = makeManifest(
            mimeType: "audio/mp4",
            name: "voice.m4a",
            width: nil,
            height: nil,
            duration: 12.5
        )
        let original = manifest.assets[0]
        var display = original.display ?? [:]
        display["attachment_type"] = .string("voiceRecording")
        display["waveform_data"] = .array([.number(0.1), .number(0.8)])
        manifest = E2eeAttachmentManifestV1(
            attachmentId: manifest.attachmentId,
            assets: [
                E2eeAttachmentManifestAssetV1(
                    assetId: original.assetId,
                    kind: original.kind,
                    cipherSize: original.cipherSize,
                    cipherSha256: original.cipherSha256,
                    frameSize: original.frameSize,
                    contentKey: original.contentKey,
                    noncePrefix: original.noncePrefix,
                    plaintextSize: original.plaintextSize,
                    plaintextSha256: original.plaintextSha256,
                    display: display
                ),
                manifest.assets[1]
            ]
        )

        let renderable = try E2eeAttachmentReceiveCoordinator.renderablePayload(for: manifest)
        let payload = try JSONDecoder.ermis.decode(VoiceRecordingAttachmentPayload.self, from: renderable.data)

        XCTAssertEqual(renderable.type, .voiceRecording)
        XCTAssertEqual(payload.title, "voice.m4a")
        XCTAssertEqual(payload.duration, 12.5)
        XCTAssertEqual(payload.waveformData?.count, 2)
        XCTAssertEqual(payload.waveformData?[0] ?? 0, 0.1, accuracy: 0.0001)
        XCTAssertEqual(payload.waveformData?[1] ?? 0, 0.8, accuracy: 0.0001)
    }

    func testLegacyIOSVoiceManifestUsesAudioDurationCompatibilityLane() throws {
        let manifest = makeManifest(
            mimeType: "audio/aac",
            name: "legacy-ios-voice.aac",
            width: nil,
            height: nil,
            duration: 3.25
        )

        let renderable = try E2eeAttachmentReceiveCoordinator.renderablePayload(for: manifest)
        let payload = try JSONDecoder.ermis.decode(VoiceRecordingAttachmentPayload.self, from: renderable.data)

        XCTAssertEqual(renderable.type, .voiceRecording)
        XCTAssertEqual(payload.file.mimeType, "audio/aac")
        XCTAssertEqual(payload.duration, 3.25)
    }

    func testGenericAudioWithoutVoiceMarkerOrDurationRemainsFile() throws {
        let manifest = makeManifest(
            mimeType: "audio/mpeg",
            name: "song.mp3",
            width: nil,
            height: nil,
            duration: nil
        )

        let renderable = try E2eeAttachmentReceiveCoordinator.renderablePayload(for: manifest)

        XCTAssertEqual(renderable.type, .file)
        XCTAssertNoThrow(try JSONDecoder.ermis.decode(FileAttachmentPayload.self, from: renderable.data))
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
