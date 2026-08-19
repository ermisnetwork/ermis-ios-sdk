//
// Copyright 2026 Ermis Inc.
//

import Foundation
@testable import ErmisChat
import UIKit
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
        XCTAssertEqual(E2eeAttachmentPreviewCache.maximumEntryCost, 4 * 1_024 * 1_024)
    }

    func testPreviewCacheChargesDecodedBitmapCostInsteadOfCompressedByteCount() throws {
        let size = CGSize(width: 64, height: 32)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let compressed = try XCTUnwrap(image.jpegData(compressionQuality: 0.2))
        let decodedCost = try XCTUnwrap(E2eeAttachmentPreviewCache.decodedCost(for: compressed))

        XCTAssertGreaterThanOrEqual(decodedCost, 64 * 32 * 4)
        XCTAssertGreaterThan(decodedCost, compressed.count)
    }

    func testPreviewCacheRejectsInvalidImageBytes() {
        XCTAssertThrowsError(
            try E2eeAttachmentPreviewCache.shared.insert(Data("not-an-image".utf8), for: UUID().uuidString)
        ) { error in
            guard case E2eeAttachmentPreviewCache.CacheError.invalidImage = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testPreviewCacheRejectsDecodedBitmapLargerThanPerEntryBudget() throws {
        let size = CGSize(width: 1_100, height: 1_100)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let compressed = try XCTUnwrap(image.jpegData(compressionQuality: 0.1))

        XCTAssertThrowsError(
            try E2eeAttachmentPreviewCache.shared.insert(compressed, for: UUID().uuidString)
        ) { error in
            guard case E2eeAttachmentPreviewCache.CacheError.decodedImageTooLarge = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testPreviewCacheClearsPlaintextOnMemoryWarningAndBackground() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        let compressed = try XCTUnwrap(image.jpegData(compressionQuality: 0.5))
        let memoryWarningAssetId = UUID().uuidString
        let backgroundAssetId = UUID().uuidString

        try E2eeAttachmentPreviewCache.shared.insert(compressed, for: memoryWarningAssetId)
        XCTAssertNotNil(E2eeAttachmentPreviewCache.shared.data(for: memoryWarningAssetId))
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        XCTAssertNil(E2eeAttachmentPreviewCache.shared.data(for: memoryWarningAssetId))

        try E2eeAttachmentPreviewCache.shared.insert(compressed, for: backgroundAssetId)
        XCTAssertNotNil(E2eeAttachmentPreviewCache.shared.data(for: backgroundAssetId))
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertNil(E2eeAttachmentPreviewCache.shared.data(for: backgroundAssetId))
    }

    func testPreviewWorkHasMaximumThreeConcurrentOperations() {
        XCTAssertEqual(E2eeAttachmentReceiveCoordinator.maximumConcurrentPreviewOperations, 3)
    }

    func testConcurrentPreviewHydrationCoalescesAllMessageTargets() throws {
        let registry = E2eeAttachmentPreviewFlightRegistry()
        let manifest = makeManifest(
            mimeType: "video/mp4",
            name: "clip.mp4",
            width: 1080,
            height: 1920,
            duration: 20
        )
        let previewAssetId = try XCTUnwrap(
            manifest.assets.first(where: { $0.kind == .preview })?.assetId
        )
        let cid = try ChannelId(cid: "messaging:preview-project:preview-flight")
        let first = E2eeAttachmentPreviewPersistenceTarget(
            manifest: manifest,
            previewAssetId: previewAssetId,
            attachmentId: AttachmentId(cid: cid, messageId: "message-1", index: 0)
        )
        let second = E2eeAttachmentPreviewPersistenceTarget(
            manifest: manifest,
            previewAssetId: previewAssetId,
            attachmentId: AttachmentId(cid: cid, messageId: "message-2", index: 0)
        )

        let firstRegistration = registry.register(assetId: previewAssetId, target: first)
        let secondRegistration = registry.register(assetId: previewAssetId, target: second)
        XCTAssertTrue(firstRegistration.shouldStartFlight)
        XCTAssertFalse(secondRegistration.shouldStartFlight)
        XCTAssertEqual(firstRegistration.flightId, secondRegistration.flightId)

        let targets = registry.finish(assetId: previewAssetId, flightId: firstRegistration.flightId)
        XCTAssertEqual(Set(targets.map(\.attachmentId)), Set([first.attachmentId, second.attachmentId]))
        XCTAssertTrue(
            registry.finish(assetId: previewAssetId, flightId: firstRegistration.flightId).isEmpty
        )
    }

    func testChannelInfoWaiterJoinsExistingPreviewFlight() throws {
        let registry = E2eeAttachmentPreviewFlightRegistry()
        let manifest = makeManifest(
            mimeType: "image/jpeg",
            name: "photo.jpg",
            width: 480,
            height: 320,
            duration: nil
        )
        let assetId = try XCTUnwrap(manifest.assets.first(where: { $0.kind == .preview })?.assetId)
        let cid = try ChannelId(cid: "messaging:preview-project:preview-waiter")
        let target = E2eeAttachmentPreviewPersistenceTarget(
            manifest: manifest,
            previewAssetId: assetId,
            attachmentId: AttachmentId(cid: cid, messageId: "message-1", index: 0)
        )
        var receivedData: Data?

        let targetRegistration = registry.register(assetId: assetId, target: target)
        XCTAssertTrue(targetRegistration.shouldStartFlight)
        let waiter = registry.registerWaiter(assetId: assetId) { result in
            receivedData = try? result.get()
        }
        XCTAssertFalse(waiter.shouldStartFlight)
        XCTAssertEqual(targetRegistration.flightId, waiter.flightId)

        let finished = registry.finishFlight(assetId: assetId, flightId: waiter.flightId)
        XCTAssertEqual(finished.targets.map(\.attachmentId), [target.attachmentId])
        XCTAssertEqual(finished.waiters.count, 1)
        let expected = Data([1, 2, 3])
        finished.waiters.forEach { $0.completion(.success(expected)) }
        XCTAssertEqual(receivedData, expected)
    }

    func testCancellingLastChannelInfoWaiterCancelsPreviewFlight() {
        let registry = E2eeAttachmentPreviewFlightRegistry()
        var receivedCancellation = false
        let registration = registry.registerWaiter(assetId: "preview-1") { result in
            if case .failure(_) = result { receivedCancellation = true }
        }

        let cancelled = registry.cancelWaiter(
            assetId: "preview-1",
            flightId: registration.flightId,
            id: registration.id
        )
        XCTAssertNotNil(cancelled.waiter)
        XCTAssertTrue(cancelled.shouldCancelFlight)
        cancelled.waiter?.completion(.failure(CancellationError()))
        XCTAssertTrue(receivedCancellation)
        XCTAssertTrue(
            registry.finishFlight(assetId: "preview-1", flightId: registration.flightId).waiters.isEmpty
        )
    }

    func testCancellingOneOfMultipleChannelInfoWaitersKeepsPreviewFlight() {
        let registry = E2eeAttachmentPreviewFlightRegistry()
        let first = registry.registerWaiter(assetId: "preview-1") { _ in }
        let second = registry.registerWaiter(assetId: "preview-1") { _ in }

        let cancelled = registry.cancelWaiter(
            assetId: "preview-1",
            flightId: first.flightId,
            id: first.id
        )
        XCTAssertNotNil(cancelled.waiter)
        XCTAssertFalse(cancelled.shouldCancelFlight)

        let finished = registry.finishFlight(assetId: "preview-1", flightId: second.flightId)
        XCTAssertEqual(finished.waiters.map(\.id), [second.id])
    }

    func testCancelledFlightCompletionCannotConsumeReplacementFlight() {
        let registry = E2eeAttachmentPreviewFlightRegistry()
        let cancelledRegistration = registry.registerWaiter(assetId: "preview-1") { _ in }
        _ = registry.cancelWaiter(
            assetId: "preview-1",
            flightId: cancelledRegistration.flightId,
            id: cancelledRegistration.id
        )

        var replacementReceivedData: Data?
        let replacement = registry.registerWaiter(assetId: "preview-1") { result in
            replacementReceivedData = try? result.get()
        }
        XCTAssertTrue(replacement.shouldStartFlight)
        XCTAssertNotEqual(cancelledRegistration.flightId, replacement.flightId)

        let staleFinished = registry.finishFlight(
            assetId: "preview-1",
            flightId: cancelledRegistration.flightId
        )
        XCTAssertTrue(staleFinished.waiters.isEmpty)

        let replacementFinished = registry.finishFlight(
            assetId: "preview-1",
            flightId: replacement.flightId
        )
        let expected = Data([4, 5, 6])
        replacementFinished.waiters.forEach { $0.completion(.success(expected)) }
        XCTAssertEqual(replacementReceivedData, expected)
    }

    func testPreviewModelPersistenceRetriesOnlyWhileMessageIsNotMaterialized() {
        let missingMessage = ClientError.MessageDoesNotExist(messageId: "message-1")

        XCTAssertTrue(
            E2eeAttachmentReceiveCoordinator.shouldRetryModelPersistence(
                error: missingMessage,
                attempt: 0
            )
        )
        XCTAssertFalse(
            E2eeAttachmentReceiveCoordinator.shouldRetryModelPersistence(
                error: missingMessage,
                attempt: 7
            )
        )
        XCTAssertFalse(
            E2eeAttachmentReceiveCoordinator.shouldRetryModelPersistence(
                error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut),
                attempt: 0
            )
        )
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
