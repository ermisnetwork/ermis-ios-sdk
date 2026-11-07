import CoreData
import CryptoKit
import XCTest
@testable import ErmisChat

final class E2eeOutgoingEditPersistenceTests: XCTestCase {
    private let cid = "team:project:durable-edit"

    func testEncryptedCaptionHistorySurvivesDecodeCacheAndReencode() throws {
        let bytes = Data(#"{"text":"QAATT-caption-after","attachments":[],"old_texts":[{"text":"QAATT-caption-before","created_at":"2026-11-07T03:30:21.905Z"}]}"#.utf8)
        let payload = try JSONDecoder.default.decode(E2ePayload.self, from: bytes)
        let database = try makeDatabase()
        defer { try? close(database) }
        try database.writeAndWait { session in
            let channel = try session.saveChannel(payload: channelPayload(messageIds: ["message-1"]))
            let row = try XCTUnwrap(channel.messages.first)
            let cache = try session.saveMessageDecrypt(payload: payload, messageId: row.id,
                ciphertextHash: Data(SHA256.hash(data: try XCTUnwrap(row.encryptedData))))
            let saved = try JSONEncoder.default.encode(cache.asPayload())
            let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
            let history = try XCTUnwrap(wire["old_texts"] as? [[String: Any]])
            XCTAssertEqual(history.count, 1)
            XCTAssertEqual(history.first?["text"] as? String, "QAATT-caption-before")
            let date = try XCTUnwrap(history.first?["created_at"] as? String)
            XCTAssertTrue(date.contains("21.905"))
        }
    }

    func testSameAccountPeerEditInvalidatesOldCaptionCacheAndCannotBeSkippedAsOwnEcho() throws {
        let database = try makeDatabase()
        defer { try? close(database) }
        let id = UUID().uuidString.lowercased()
        try database.writeAndWait { session in
            try session.saveChannel(payload: channelPayload(messageIds: [id]))
            let row = try XCTUnwrap(session.message(id: id))
            let baseCipher = try XCTUnwrap(row.encryptedData)
            try session.saveMessageDecrypt(payload: E2ePayload(text: "QAATT-old", attachments: [], stickerUrl: nil),
                messageId: id, ciphertextHash: Data(SHA256.hash(data: baseCipher)))
            XCTAssertNotNil(try row.asModel().decryptedMessage)
            row.encryptedData = Data([4, 5, 6]) // canonical peer version, same message and author
            let updated = try row.asModel()
            XCTAssertNil(updated.decryptedMessage, "Old caption must not authenticate the new edit ciphertext")
            XCTAssertFalse(E2eRepository.shouldSkipRealtimeDecrypt(isSentByCurrentUser: true,
                hasCachedPlaintext: updated.decryptedMessage != nil), "Same-account peer edit must enter ordered sync")
            try session.saveMessageDecrypt(payload: E2ePayload(text: "QAATT-new", attachments: [], stickerUrl: nil,
                oldTexts: [.init(text: "QAATT-old", createdAt: Date(timeIntervalSince1970: 1794022221.905))]),
                messageId: id, ciphertextHash: Data(SHA256.hash(data: Data([4, 5, 6]))))
            let accepted = try row.asModel()
            XCTAssertEqual(accepted.decryptedMessage?.text, "QAATT-new")
            XCTAssertTrue(E2eRepository.shouldSkipRealtimeDecrypt(isSentByCurrentUser: true,
                hasCachedPlaintext: accepted.decryptedMessage != nil), "Exact own echo remains cache-only")
        }
    }

    private func captionUpdateEnvelope(messageId: String) throws -> E2eSyncEventEnvelope {
        let raw = """
        {"event_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","cid":"\(cid)",
         "type":"message_updated","created_at":"2026-11-07T08:00:00.905Z",
         "data":{"sender":{"id":"sender","project_id":"project"},"created_at":"2026-11-07T08:00:00.905Z",
          "message":{"id":"\(messageId)","type":"regular","user":{"id":"sender","project_id":"project"},
           "text":"","mls_ciphertext":"BAUG","mls_epoch":4,"created_at":"2026-08-07T02:00:00.000Z",
           "updated_at":"2026-11-07T08:00:00.905Z"}}}
        """
        return try JSONDecoder.default.decode(E2eSyncEventEnvelope.self, from: Data(raw.utf8))
    }

    func testCanonicalCaptionUpdateUsesOuterCidAndSenderWithoutLegacyDataCid() throws {
        let event = try captionUpdateEnvelope(messageId: UUID().uuidString.lowercased())
        guard case .messageUpdated(let update) = event.event else {
            return XCTFail("Canonical Bellboy caption update must not become unknown and block scope replay")
        }
        XCTAssertEqual(update.user.id, "sender")
        XCTAssertEqual(update.message.encryptedData, [4, 5, 6])
    }

    func testEncryptedCaptionUpdateCannotAcknowledgeCursorBeforeMatchingDecodeIsDurable() throws {
        let database = try makeDatabase()
        defer { try? close(database) }
        let store = E2eeDurableInboxStore(database: database)
        let id = UUID().uuidString.lowercased(), event = try captionUpdateEnvelope(messageId: id)
        _ = try store.persistPage(accountId: "sender", scopeCid: cid, events: [event], hasMore: false,
            nextCursor: .init(createdAt: event.createdAtRaw, eventId: event.eventId))
        XCTAssertThrowsError(try store.markApplied(accountId: "sender", scopeCid: cid, envelope: event))
        XCTAssertNil(try store.applyCursor(accountId: "sender", scopeCid: cid))
        guard case .messageUpdated(let update) = event.event else { return XCTFail("Typed edit required") }
        try database.writeAndWait { session in
            try session.saveChannel(payload: channelPayload(messageIds: [id]))
            try session.saveMessage(payload: update.message, for: ChannelId(cid: cid), syncOwnReactions: false, cache: nil)
        }
        XCTAssertThrowsError(try store.markApplied(accountId: "sender", scopeCid: cid, envelope: event))
        try database.writeAndWait { session in
            try session.saveMessageDecrypt(payload: E2ePayload(text: "QAATT-received-edit", attachments: [], stickerUrl: nil),
                messageId: id, ciphertextHash: Data(SHA256.hash(data: Data([4, 5, 6]))))
        }
        try store.markApplied(accountId: "sender", scopeCid: cid, envelope: event)
        XCTAssertEqual(try store.applyCursor(accountId: "sender", scopeCid: cid)?.eventId, event.eventId)
    }

    func testSkippedLegacyCaptionRepairRequiresExactCurrentCipherAndKeepsCursors() throws {
        let database = try makeDatabase()
        defer { try? close(database) }
        let store = E2eeDurableInboxStore(database: database)
        let id = UUID().uuidString.lowercased(), event = try captionUpdateEnvelope(messageId: id)
        _ = try store.persistPage(accountId: "sender", scopeCid: cid, events: [event], hasMore: false,
            nextCursor: .init(createdAt: event.createdAtRaw, eventId: event.eventId))
        guard case .messageUpdated(let update) = event.event else { return XCTFail("Typed update required") }
        let later = ScopeSyncCursorPayload(createdAt: "2026-11-07T09:00:00.123Z",
            eventId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        try database.writeAndWait { session in
            try session.saveChannel(payload: channelPayload(messageIds: [id]))
            try session.saveMessage(payload: update.message, for: ChannelId(cid: cid), syncOwnReactions: false, cache: nil)
            let context = try XCTUnwrap(session as? NSManagedObjectContext)
            let row = try XCTUnwrap(E2eeInboxEventDTO.load(accountId: "sender", scopeCid: cid,
                eventId: event.eventId, context: context))
            // Exact on-disk state left by the old unsupported-event acknowledgement.
            row.appliedAt = Date().bridgeDate
            row.failureCategory = "metadata_unsupported_event"
            try E2eeSyncCheckpointDTO.loadOrCreate(accountId: "sender", scopeCid: cid,
                context: context).setApplyCursor(later)
        }
        let fetched = try store.fetchCursor(accountId: "sender", scopeCid: cid)
        XCTAssertEqual(try store.skippedCaptionUpdates(accountId: "sender", scopeCid: cid).map(\.eventId), [event.eventId])
        XCTAssertTrue(try store.skippedCaptionUpdates(accountId: "other-owner", scopeCid: cid).isEmpty)
        XCTAssertNil(try store.skippedCaptionUpdate(accountId: "other-owner", scopeCid: cid,
            messageId: id, ciphertext: Data([4, 5, 6])))
        XCTAssertNil(try store.skippedCaptionUpdate(accountId: "sender", scopeCid: cid,
            messageId: id, ciphertext: Data([9])))
        XCTAssertEqual(try store.skippedCaptionUpdate(accountId: "sender", scopeCid: cid,
            messageId: id, ciphertext: Data([4, 5, 6]))?.eventId, event.eventId)
        XCTAssertThrowsError(try store.markSkippedCaptionUpdateRepaired(accountId: "sender", scopeCid: cid, envelope: event))
        try database.writeAndWait { session in
            try session.saveMessageDecrypt(payload: E2ePayload(text: "QAATT-repaired", attachments: [], stickerUrl: nil),
                messageId: id, ciphertextHash: Data(SHA256.hash(data: Data([4, 5, 6]))))
        }
        try store.markSkippedCaptionUpdateRepaired(accountId: "sender", scopeCid: cid, envelope: event)
        XCTAssertTrue(try store.skippedCaptionUpdates(accountId: "sender", scopeCid: cid).isEmpty)
        XCTAssertNil(try store.skippedCaptionUpdate(accountId: "sender", scopeCid: cid,
            messageId: id, ciphertext: Data([4, 5, 6])))
        XCTAssertEqual(try store.applyCursor(accountId: "sender", scopeCid: cid)?.eventId, later.eventId)
        XCTAssertEqual(try store.fetchCursor(accountId: "sender", scopeCid: cid)?.eventId, fetched?.eventId)
        XCTAssertEqual(try store.fetchCursor(accountId: "sender", scopeCid: cid)?.createdAt, fetched?.createdAt)
    }

    private func makeDatabase(kind: DatabaseContainer.Kind = .inMemory) throws -> DatabaseContainer {
        let database = DatabaseContainer(
            kind: kind,
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

    private func channelPayload(messageIds: [String]) throws -> ChannelPayload {
        let messages = messageIds.enumerated().map { index, id in
            """
            {
              "id": "\(id)",
              "type": "regular",
              "user": {"id": "sender", "project_id": "project"},
              "text": "",
              "mls_ciphertext": "AQID",
              "mls_epoch": \(index + 4),
              "created_at": "2026-08-07T02:0\(index):00.000Z",
              "updated_at": "2026-08-07T02:0\(index):00.000Z"
            }
            """
        }
        let json = """
        {
          "channel": {
            "cid": "\(cid)",
            "type": "team",
            "save_message": true,
            "last_message_at": "2026-08-07T02:10:00.000Z",
            "created_at": "2026-08-07T01:00:00.000Z",
            "updated_at": "2026-08-07T02:10:00.000Z",
            "member_count": 2,
            "mls_enabled": true
          },
          "messages": [\(messages.joined(separator: ","))],
          "read": []
        }
        """
        return try JSONDecoder.default.decode(ChannelPayload.self, from: Data(json.utf8))
    }

    func testCaptionSnapshotKeepsCanonicalCipherAndExactHistoryAcrossDiskReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("caption.sqlite"), id = UUID().uuidString.lowercased()
        let first = try makeDatabase(kind: .onDisk(databaseFileURL: url))
        var staged: Data?
        try first.writeAndWait { session in
            try session.saveChannel(payload: channelPayload(messageIds: [id]))
            let message = try XCTUnwrap(session.message(id: id)), cipher = try XCTUnwrap(message.encryptedData)
            let decoded = E2ePayload(text: "QAATT-original", attachments: [], stickerUrl: nil,
                oldTexts: [.init(text: "QAATT-before", createdAt: Date(timeIntervalSince1970: 1794022221.905))])
            try session.saveMessageDecrypt(payload: decoded, messageId: id, ciphertextHash: Data(SHA256.hash(data: cipher)))
            let snapshot = try E2eeCaptionEditSnapshot.make(message: message, cached: decoded,
                cid: ChannelId(cid: cid), text: "QAATT-after", mentionedUserIds: [], mentionedAll: false)
            staged = try JSONEncoder().encode(snapshot)
            message.e2eeCaptionEditData = staged; message.localMessageState = .syncing
            XCTAssertEqual(message.encryptedData, cipher)
            XCTAssertEqual(try message.decryptedMessage?.asPayload(), decoded)
        }
        try close(first)
        let reopened = try makeDatabase(kind: .onDisk(databaseFileURL: url))
        defer { try? close(reopened) }
        try reopened.writeAndWait { session in
            session.rescueMessagesStuckInSending()
            let message = try XCTUnwrap(session.message(id: id))
            XCTAssertEqual(message.e2eeCaptionEditData, staged)
            XCTAssertEqual(message.localMessageState, .pendingSync)
            XCTAssertEqual(message.encryptedData, Data([1, 2, 3]))
            let snapshot = try E2eeCaptionEditSnapshot.decode(XCTUnwrap(message.e2eeCaptionEditData))
            XCTAssertEqual(snapshot.payload.text, "QAATT-after")
            XCTAssertEqual(snapshot.payload.oldTexts?.map(\.text), ["QAATT-before", "QAATT-original"])
            XCTAssertEqual(try XCTUnwrap(snapshot.payload.oldTexts?.first?.createdAt).timeIntervalSince1970, 1794022221.905, accuracy: 0.000001)
            XCTAssertEqual(try message.asModel().text, "QAATT-after")
        }
    }

    func testActualVersionSixStoreMigratesWithoutDroppingCipherOrCachedAttachments() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("migration.sqlite")
        let modelDir = try XCTUnwrap(Bundle.ermisChat.url(forResource: "ErmisChatModel", withExtension: "momd"))
        let oldModel = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelDir.appendingPathComponent("ErmisChatModel 6.mom")))
        XCTAssertNil(oldModel.entitiesByName["MessageDTO"]?.attributesByName["e2eeCaptionEditData"])
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: oldModel)
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url, options: nil)
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let cipher = Data([7, 8, 9]), cache = Data(#"{"version":2,"legacy":[],"e2ee":[]}"#.utf8)
        var failure: Error?
        context.performAndWait {
            do {
                let row = NSEntityDescription.insertNewObject(forEntityName: "MessageDTO", into: context)
                row.setValue("QAATT-migration", forKey: "id"); row.setValue("QAATT-caption", forKey: "text")
                row.setValue("regular", forKey: "type"); row.setValue(cipher, forKey: "encryptedData")
                row.setValue(false, forKey: "isSilent"); row.setValue(false, forKey: "mentionedAll")
                row.setValue(Date(timeIntervalSince1970: 1794022221.905), forKey: "createdAt")
                row.setValue(Date(timeIntervalSince1970: 1794022221.905), forKey: "updatedAt")
                for name in ["latestReactions", "ownReactions", "mentionedUserIds"] { row.setValue([String](), forKey: name) }
                for name in ["reactionCounts", "reactionScores"] { row.setValue([String: Int](), forKey: name) }
                let decoded = NSEntityDescription.insertNewObject(forEntityName: "MessageDecryptDTO", into: context)
                decoded.setValue("QAATT-migration", forKey: "messageId"); decoded.setValue("QAATT-caption", forKey: "text")
                decoded.setValue(Data(SHA256.hash(data: cipher)), forKey: "ciphertextHash")
                decoded.setValue(cache, forKey: "attachmentsData"); decoded.setValue(row, forKey: "message")
                try context.save()
            } catch { failure = error }
        }
        if let failure { throw failure }
        context.performAndWait { context.reset() }; try coordinator.remove(store)
        let migrated = try makeDatabase(kind: .onDisk(databaseFileURL: url))
        try migrated.writeAndWait { session in
            let row = try XCTUnwrap(session.message(id: "QAATT-migration"))
            XCTAssertEqual(row.encryptedData, cipher); XCTAssertNil(row.e2eeCaptionEditData)
            XCTAssertEqual(row.decryptedMessage?.attachmentsData, cache)
            XCTAssertEqual(row.decryptedMessage?.ciphertextHash, Data(SHA256.hash(data: cipher)))
        }
        try close(migrated)
        let reopened = try makeDatabase(kind: .onDisk(databaseFileURL: url))
        defer { try? close(reopened) }
        try reopened.writeAndWait { session in XCTAssertEqual(session.message(id: "QAATT-migration")?.encryptedData, cipher) }
    }

    func testNewE2eeEditInvalidatesPreviousCiphertextEpochAndProof() throws {
        let database = try makeDatabase()
        defer { try? close(database) }

        try database.writeAndWait { session in
            let channel = try session.saveChannel(payload: channelPayload(messageIds: ["message-1"]))
            let message = try XCTUnwrap(channel.messages.first { $0.id == "message-1" })
            let decrypted = try session.saveMessageDecrypt(
                payload: E2ePayload(text: "old", attachments: [], stickerUrl: nil),
                messageId: message.id,
                ciphertextHash: Data(SHA256.hash(data: try XCTUnwrap(message.encryptedData)))
            )
            message.decryptedMessage = decrypted

            message.invalidateE2eeNetworkIntentForNewEdit()

            XCTAssertNil(message.encryptedData)
            XCTAssertEqual(message.mlsEpoch, 0)
            XCTAssertNil(message.decryptedMessage?.ciphertextHash)
        }
    }

    func testRelaunchRescuesE2eeSyncingEditWithExactIntent() throws {
        let database = try makeDatabase()
        defer { try? close(database) }

        try database.writeAndWait { session in
            let channel = try session.saveChannel(payload: channelPayload(messageIds: ["message-1"]))
            let message = try XCTUnwrap(channel.messages.first { $0.id == "message-1" })
            message.encryptedData = Data([7, 8, 9])
            message.mlsEpoch = 11
            message.localMessageState = .syncing

            session.rescueMessagesStuckInSending()

            XCTAssertEqual(message.localMessageState, .pendingSync)
            XCTAssertEqual(message.encryptedData, Data([7, 8, 9]))
            XCTAssertEqual(message.mlsEpoch, 11)
        }
    }

    func testRelaunchDoesNotReplaySyncingEditWithoutDurableIntent() throws {
        let database = try makeDatabase()
        defer { try? close(database) }

        try database.writeAndWait { session in
            let channel = try session.saveChannel(payload: channelPayload(messageIds: ["message-1"]))
            let message = try XCTUnwrap(channel.messages.first { $0.id == "message-1" })
            message.encryptedData = nil
            message.mlsEpoch = 0
            message.localMessageState = .syncing

            session.rescueMessagesStuckInSending()

            XCTAssertEqual(message.localMessageState, .syncingFailed)
            XCTAssertNil(message.encryptedData)
        }
    }
}
