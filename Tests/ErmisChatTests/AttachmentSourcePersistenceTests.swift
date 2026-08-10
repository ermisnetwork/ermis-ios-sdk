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
