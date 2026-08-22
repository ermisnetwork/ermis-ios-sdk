import CoreData
import UIKit
import XCTest
@testable import ErmisChat

final class AttachmentSourcePersistenceTests: XCTestCase {
    private let cid = "team:project:attachment-source"

    func testPhotoKitCallbackCanPersistPreparedURLWithoutCrossingCoreDataQueues() throws {
        let database = try makeDatabase()
        defer { try? close(database) }

        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        let preparedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        try Data([1, 2, 3]).write(to: sourceURL)
        try Data([4, 5, 6, 7]).write(to: preparedURL)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: preparedURL)
        }

        let channelId = try ChannelId(cid: cid)
        let attachmentId = AttachmentId(
            cid: channelId,
            messageId: "message-1",
            index: 0
        )
        try database.writeAndWait { session in
            _ = try session.saveChannel(payload: channelPayload())
            let payload = try AnyAttachmentPayload(
                localFileURL: sourceURL,
                attachmentType: .video
            )
            _ = try session.createNewAttachment(
                attachment: payload,
                id: attachmentId
            )
        }

        let persisted = expectation(description: "prepared source persisted")
        var result: Result<AnyMessageAttachment, Error>?
        DispatchQueue.global(qos: .utility).async {
            result = Result {
                try PreparedAttachmentSourcePersistence.persist(
                    database: database,
                    id: attachmentId,
                    localURL: preparedURL
                )
            }
            persisted.fulfill()
        }
        wait(for: [persisted], timeout: 5)

        let model = try XCTUnwrap(result).get()
        XCTAssertEqual(model.uploadingState?.localFileURL, preparedURL)
        XCTAssertEqual(model.uploadingState?.file.size, 4)
        XCTAssertEqual(
            model.attachment(payloadType: VideoAttachmentPayload.self)?.videoURL,
            preparedURL
        )

        database.backgroundReadOnlyContext.performAndWait {
            XCTAssertEqual(
                database.backgroundReadOnlyContext.attachment(id: attachmentId)?.localURL,
                preparedURL
            )
        }
    }

    func testLocalAttachmentCanBeRecoveredAfterAuthoritativeRelationshipWasNullified() throws {
        let database = try makeDatabase()
        defer { try? close(database) }

        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")
        try Data([1, 2, 3, 4]).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        let channelId = try ChannelId(cid: cid)
        let attachmentId = AttachmentId(
            cid: channelId,
            messageId: "message-1",
            index: 0
        )
        try database.writeAndWait { session in
            let context = try XCTUnwrap(session as? NSManagedObjectContext)
            _ = try session.saveChannel(payload: channelPayload())
            let payload = try AnyAttachmentPayload(
                localFileURL: localURL,
                attachmentType: .image
            )
            _ = try session.createNewAttachment(attachment: payload, id: attachmentId)
            session.message(id: attachmentId.messageId)?.attachments = []

            let recovered = AttachmentDTO.loadLocalAttachments(
                cid: channelId,
                messageId: attachmentId.messageId,
                context: context
            )
            XCTAssertEqual(recovered.count, 1)
            XCTAssertEqual(recovered.first?.attachmentID, attachmentId)
            XCTAssertEqual(recovered.first?.localURL, localURL)
            XCTAssertEqual(
                recovered.first?.asAnyModel()?
                    .attachment(payloadType: ImageAttachmentPayload.self)?.imageURL,
                localURL
            )
        }
    }

    func testE2eeDisplayUsesExactStagedJPEGMetadataInsteadOfPhotoKitHint() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("heic")
        defer { try? FileManager.default.removeItem(at: url) }

        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let jpeg = try XCTUnwrap(image.jpegData(compressionQuality: 0.92))
        try jpeg.write(to: url)

        let display = E2eeAttachmentPreparationCoordinator.normalizedDisplay(
            [
                "name": .string("IMG_2860.HEIC"),
                "mime_type": .string("image/heic"),
                "size": .number(1)
            ],
            for: url
        )

        XCTAssertEqual(display["name"]?.stringValue, "IMG_2860.jpg")
        XCTAssertEqual(display["mime_type"]?.stringValue, "image/jpeg")
        XCTAssertEqual(display["size"]?.numberValue, Double(jpeg.count))
    }

    func testE2eeVoiceDisplayIncludesCrossPlatformClassificationAndPlaybackMetadata() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("aac")
        try Data([1, 2, 3, 4]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try AttachmentFile(url: url, fileSize: 4)
        let payload = VoiceRecordingAttachmentPayload(
            title: url.lastPathComponent,
            voiceRecordingRemoteURL: url,
            file: file,
            duration: 2.5,
            waveformData: [0.1, 0.7]
        )
        let attachment = MessageVoiceRecordingAttachment(
            id: AttachmentId(
                cid: try ChannelId(cid: cid),
                messageId: "voice-message",
                index: 0
            ),
            type: .voiceRecording,
            payload: payload,
            thumbnailData: nil,
            uploadingState: AttachmentUploadingState(
                localFileURL: url,
                state: .uploading(progress: 0),
                file: file
            )
        ).asAnyAttachment

        let display = AttachmentQueueUploader.e2eeDisplayMetadata(for: attachment)

        XCTAssertEqual(display["attachment_type"]?.stringValue, "voiceRecording")
        XCTAssertEqual(display["mime_type"]?.stringValue, "audio/aac")
        XCTAssertEqual(display["duration"]?.numberValue, 2.5)
        let waveform = display["waveform_data"]?.numberArrayValue ?? []
        XCTAssertEqual(waveform.count, 2)
        XCTAssertEqual(waveform[0], 0.1, accuracy: 0.0001)
        XCTAssertEqual(waveform[1], 0.7, accuracy: 0.0001)
    }

    func testE2eeDisplayAuthenticatesFileAndVideoIntentIndependentlyOfMime() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        try Data([1, 2, 3, 4]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AttachmentFile(url: url, fileSize: 4)
        let attachmentId = AttachmentId(
            cid: try ChannelId(cid: cid),
            messageId: "intent-message",
            index: 0
        )
        let uploading = AttachmentUploadingState(
            localFileURL: url,
            state: .uploading(progress: 0),
            file: file
        )
        let fileAttachment = MessageFileAttachment(
            id: attachmentId,
            type: .file,
            payload: FileAttachmentPayload(title: "clip.mp4", assetRemoteURL: url, file: file),
            thumbnailData: nil,
            uploadingState: uploading
        ).asAnyAttachment
        let videoAttachment = MessageVideoAttachment(
            id: attachmentId,
            type: .video,
            payload: VideoAttachmentPayload(title: "clip.mp4", videoRemoteURL: url, file: file),
            thumbnailData: nil,
            uploadingState: uploading
        ).asAnyAttachment

        XCTAssertEqual(
            AttachmentQueueUploader.e2eeDisplayMetadata(for: fileAttachment)["attachment_type"]?.stringValue,
            "file"
        )
        XCTAssertEqual(
            AttachmentQueueUploader.e2eeDisplayMetadata(for: videoAttachment)["attachment_type"]?.stringValue,
            "video"
        )
    }

    func testForwardStagerCopiesLeaseOwnedPlaintextIntoDestinationOwnedStorage() throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bytes = Data([9, 8, 7, 6, 5])
        try bytes.write(to: sourceURL)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: storageURL)
        }

        var metadata = AnyAttachmentLocalMetadata()
        metadata.title = "source-name.pdf"
        metadata.fileSize = bytes.count
        let payload = try AnyAttachmentPayload(
            localFileURL: sourceURL,
            attachmentType: .file,
            localMetadata: metadata
        )
        let channelId = try ChannelId(cid: "team:project:forward-destination")
        let storage = AttachmentStorage(baseURL: storageURL)

        let result = try ForwardAttachmentSourceStager.stage(
            [payload],
            for: channelId,
            messageId: "destination-message",
            storage: storage
        )

        let stagedURL = try XCTUnwrap(result.payloads.first?.localFileURL)
        XCTAssertNotEqual(stagedURL, sourceURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
        XCTAssertEqual(try Data(contentsOf: stagedURL), bytes)
        XCTAssertEqual(
            (result.payloads.first?.payload as? FileAttachmentPayload)?.title,
            "source-name.pdf"
        )

        // Releasing/removing the viewer-owned source cannot invalidate the queued forward.
        try FileManager.default.removeItem(at: sourceURL)
        XCTAssertEqual(try Data(contentsOf: stagedURL), bytes)
    }

    func testForwardStagerRepointsVideoPayloadAtDestinationOwnedFile() throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bytes = Data([0, 0, 0, 20, 102, 116, 121, 112])
        try bytes.write(to: sourceURL)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: storageURL)
        }

        var metadata = AnyAttachmentLocalMetadata()
        metadata.title = "forwarded-video.mp4"
        metadata.mimeType = "video/mp4"
        metadata.duration = 20
        metadata.fileSize = bytes.count
        let payload = try AnyAttachmentPayload(
            localFileURL: sourceURL,
            attachmentType: .video,
            localMetadata: metadata
        )
        let channelId = try ChannelId(cid: "team:project:forward-video")

        let result = try ForwardAttachmentSourceStager.stage(
            [payload],
            for: channelId,
            messageId: "destination-video-message",
            storage: AttachmentStorage(baseURL: storageURL)
        )

        let staged = try XCTUnwrap(result.payloads.first)
        let stagedURL = try XCTUnwrap(staged.localFileURL)
        let video = try XCTUnwrap(staged.payload as? VideoAttachmentPayload)
        XCTAssertNotEqual(stagedURL, sourceURL)
        XCTAssertEqual(video.videoURL, stagedURL)
        XCTAssertEqual(video.title, "forwarded-video.mp4")
        XCTAssertEqual(video.file.mimeType, "video/mp4")
        XCTAssertEqual(video.duration, 20)

        // The persisted video payload must remain usable after the viewer lease is released.
        try FileManager.default.removeItem(at: sourceURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.videoURL.path))
        XCTAssertEqual(try Data(contentsOf: video.videoURL), bytes)
    }

    func testForwardStagerCleansEarlierCopiesWhenLaterSourceDisappears() throws {
        let firstURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        let secondURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
            try? FileManager.default.removeItem(at: storageURL)
        }

        let first = try AnyAttachmentPayload(localFileURL: firstURL, attachmentType: .file)
        let second = try AnyAttachmentPayload(localFileURL: secondURL, attachmentType: .file)
        try FileManager.default.removeItem(at: secondURL)
        let channelId = try ChannelId(cid: "team:project:forward-cleanup")
        let storage = AttachmentStorage(baseURL: storageURL)

        XCTAssertThrowsError(try ForwardAttachmentSourceStager.stage(
            [first, second],
            for: channelId,
            messageId: "destination-message",
            storage: storage
        ))

        let firstDestination = storage.sandboxedURL(
            for: AttachmentId(cid: channelId, messageId: "destination-message", index: 0),
            temporaryURL: firstURL
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstDestination.path))
    }

    func testForwardPayloadPreservesVideoAndVoiceDisplayMetadata() throws {
        let videoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        let voiceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("aac")
        try Data([1, 2, 3]).write(to: videoURL)
        try Data([4, 5, 6, 7]).write(to: voiceURL)
        defer {
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: voiceURL)
        }

        var videoMetadata = AnyAttachmentLocalMetadata()
        videoMetadata.title = "holiday.mp4"
        videoMetadata.mimeType = "video/custom"
        videoMetadata.duration = 12.5
        let video = try AnyAttachmentPayload(
            localFileURL: videoURL,
            attachmentType: .video,
            localMetadata: videoMetadata
        )

        var voiceMetadata = AnyAttachmentLocalMetadata()
        voiceMetadata.title = "voice-note.aac"
        voiceMetadata.duration = 4.25
        voiceMetadata.waveformData = [0.1, 0.8, 0.3]
        let voice = try AnyAttachmentPayload(
            localFileURL: voiceURL,
            attachmentType: .voiceRecording,
            localMetadata: voiceMetadata
        )

        let videoPayload = try XCTUnwrap(video.payload as? VideoAttachmentPayload)
        XCTAssertEqual(videoPayload.title, "holiday.mp4")
        XCTAssertEqual(videoPayload.file.mimeType, "video/custom")
        XCTAssertEqual(videoPayload.duration, 12.5)
        let voicePayload = try XCTUnwrap(voice.payload as? VoiceRecordingAttachmentPayload)
        XCTAssertEqual(voicePayload.title, "voice-note.aac")
        XCTAssertEqual(voicePayload.duration, 4.25)
        XCTAssertEqual(voicePayload.waveformData ?? [], [0.1, 0.8, 0.3])
    }

    func testOpaqueAttachmentRemainsAnE2eeForwardSignalWithoutMessageCiphertextFields() throws {
        let payload = ImageAttachmentPayload(
            title: "photo.jpg",
            imageRemoteURL: try XCTUnwrap(URL(string: "ermis-e2ee-attachment://asset/original")),
            file: AttachmentFile(type: .generic, size: 3, mimeType: "image/jpeg"),
            thumbnailData: nil
        )
        let attachment = MessageImageAttachment(
            id: AttachmentId(
                cid: try ChannelId(cid: "team:project:source"),
                messageId: "source-message",
                index: 0
            ),
            type: .image,
            payload: payload,
            thumbnailData: nil,
            uploadingState: nil
        ).asAnyAttachment

        XCTAssertTrue(attachment.isE2eeOpaqueAsset)
    }

    private func makeDatabase() throws -> DatabaseContainer {
        let database = DatabaseContainer(
            kind: .inMemory,
            shouldResetEphemeralValuesOnStart: false
        )
        let storeLoaded = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                !database.persistentStoreCoordinator.persistentStores.isEmpty
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [storeLoaded], timeout: 5), .completed)
        return database
    }

    private func close(_ database: DatabaseContainer) throws {
        for context in database.allContext {
            context.performAndWait { context.reset() }
        }
        for store in database.persistentStoreCoordinator.persistentStores {
            try database.persistentStoreCoordinator.remove(store)
        }
    }

    private func channelPayload() throws -> ChannelPayload {
        let json = """
        {
          "channel": {
            "cid": "\(cid)",
            "type": "team",
            "save_message": true,
            "last_message_at": "2026-08-09T12:00:00.000Z",
            "created_at": "2026-08-09T12:00:00.000Z",
            "updated_at": "2026-08-09T12:00:00.000Z",
            "member_count": 2,
            "mls_enabled": false
          },
          "messages": [{
            "id": "message-1",
            "type": "regular",
            "user": {"id": "sender", "project_id": "project"},
            "text": "",
            "created_at": "2026-08-09T12:00:00.000Z",
            "updated_at": "2026-08-09T12:00:00.000Z"
          }],
          "read": []
        }
        """
        return try JSONDecoder.default.decode(ChannelPayload.self, from: Data(json.utf8))
    }
}
