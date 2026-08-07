import CoreData
import XCTest
@testable import ErmisChat

final class E2eeOutgoingEditPersistenceTests: XCTestCase {
    private let cid = "team:project:durable-edit"

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

    func testNewE2eeEditInvalidatesPreviousCiphertextEpochAndProof() throws {
        let database = try makeDatabase()
        defer { try? close(database) }

        try database.writeAndWait { session in
            let channel = try session.saveChannel(payload: channelPayload(messageIds: ["message-1"]))
            let message = try XCTUnwrap(channel.messages.first { $0.id == "message-1" })
            let decrypted = try session.saveMessageDecrypt(
                payload: E2ePayload(text: "old", attachments: [], stickerUrl: nil),
                messageId: message.id,
                ciphertextHash: Data([9, 9, 9])
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
